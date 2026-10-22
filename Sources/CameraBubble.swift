import AppKit
import AVFoundation

/// The camera preview that floats above other windows. Drag the middle to move it, drag the rim to
/// resize it. Dropped near a corner of the recording area, it snaps into that corner.
///
/// Normally it's a round bubble. Loom records the camera as its own track and sends the bubble's
/// position to its recorder as events, then combines them later; MyLoom keeps it simpler: the bubble
/// is an ordinary on-screen window, so the screen recording captures it exactly where you put it.
///
/// It can be a circle, or a rounded square, landscape or portrait rectangle (Loom's two kinds of bubble
/// shape are a circle and a rounded rectangle). For Camera Only recordings it feeds the camera's
/// picture to the recorder (see `CameraFeed`), and the movie is the bubble's shape, cut from the
/// middle of the picture just as the bubble shows it.
///
/// With a background effect on, it shows each frame after `CameraEffects` has blurred or replaced
/// what's behind you, so the screen recording, and a Camera Only recording, get it too.
final class CameraBubble: NSObject, CameraFeed {
    static let presets: [(title: String, diameter: CGFloat)] = [
        ("Small", 160), ("Medium", 240), ("Large", 320), ("Extra Large", 480),
    ]
    static let diameterRange: ClosedRange<CGFloat> = 96...720

    enum Shape: String, CaseIterable {
        case circle, square
        /// The camera's own shape, `rectangleScale` times the diameter wide.
        case landscape
        /// 9:16, `rectangleScale` times the diameter tall.
        case portrait

        var title: String {
            switch self {
            case .circle: return "Circle"
            case .square: return "Square"
            case .landscape: return "Landscape"
            case .portrait: return "Portrait (9:16)"
            }
        }

        /// Width over height of a Camera Only movie in this shape, or nil for the camera's own.
        /// A movie can't be round, so a circle records as the square around it.
        var aspectRatio: CGFloat? {
            switch self {
            case .circle, .square: return 1
            case .landscape: return nil
            case .portrait: return 9.0 / 16
            }
        }
    }

    enum BubbleError: LocalizedError {
        case cameraUnavailable
        case noCamera

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable: return "The selected camera couldn't be opened. It may be in use by another app."
            case .noCamera: return "There's no camera to record. Turn on the camera bubble first."
            }
        }
    }

    /// Landscape and portrait are this much longer than the diameter, so Medium landscape is 360 pt wide.
    private static let rectangleScale: CGFloat = 1.5
    /// Gap between the bubble and the edge it is tucked against (Loom's default spot is bottom-left too).
    private static let margin: CGFloat = 24
    /// How close to a corner a drop has to be to snap into it.
    private static let snapDistance: CGFloat = 64

    /// Called with the new diameter when the user finishes resizing by dragging the rim.
    var onResize: ((CGFloat) -> Void)?
    /// The rectangle, in global screen coordinates, whose corners the bubble snaps to after a drag.
    var snapBounds: ((NSRect) -> NSRect?)?

    var diameter: CGFloat = 240 {
        didSet { applySize() }
    }

    var shape: Shape = .circle {
        didSet { applySize() }
    }

    /// Shows (and for Camera Only, records) the camera like a mirror, as people expect to see themselves.
    var mirrored = true {
        didSet { applyMirroring() }
    }

    /// What's shown behind you: blurred, replaced, or left alone.
    var background: CameraBackground = .none {
        didSet {
            guard background != oldValue else { return }
            effects.background = background
            view?.showsEffects = background != .none
            updateFrameOutput()
        }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "MyLoom.camera")
    private var input: AVCaptureDeviceInput?
    private var panel: NSPanel?
    private var view: BubbleView?

    /// How strongly Blur blurs, from 0 to 1. Changes show straight away.
    var blurStrength: Double {
        get { effects.blurStrength }
        set { effects.blurStrength = newValue }
    }

    private struct FrameSize: Equatable { var width: Int, height: Int }
    /// Camera frames are taken (on `frameQueue`) only while something needs them: a background
    /// effect, at preview size, or a Camera Only recording, at the recording's size.
    private let frameQueue = DispatchQueue(label: "MyLoom.camera.frames", qos: .userInteractive)
    private var frameOutput: AVCaptureVideoDataOutput?
    private var frameSize: FrameSize?
    private let effects = CameraEffects()
    /// Shows frames with the effect, above the plain preview, which shows through until the first arrives.
    private let effectLayer = AVSampleBufferDisplayLayer()
    /// The recording's frame size, while Camera Only is recording.
    private var feedSize: FrameSize?
    /// Where frames go for the recorder. Read on `frameQueue`, so guarded by `feedLock`.
    private var feed: (queue: DispatchQueue, handler: (CVPixelBuffer, CMTime) -> Void)?
    private let feedLock = NSLock()

    var isVisible: Bool { panel?.isVisible ?? false }
    var cameraID: String? { input?.device.uniqueID }
    var frame: NSRect? { panel?.frame }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    /// Width over height of the current camera picture, 16:9 until a camera is chosen.
    var cameraAspect: CGFloat {
        guard let format = input?.device.activeFormat else { return 16.0 / 9 }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return dimensions.height > 0 ? CGFloat(dimensions.width) / CGFloat(dimensions.height) : 16.0 / 9
    }

    /// Shows the bubble. The first time, it appears in the bottom-left corner of `home`.
    func show(camera: AVCaptureDevice, home: NSRect) throws {
        try use(camera)
        if panel == nil { makePanel(at: Self.corner(.bottomLeft, of: home, size: size)) }
        applySize()
        panel?.orderFrontRegardless()
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Hides the bubble. During a Camera Only recording the camera keeps running for the recorder.
    func hide() {
        panel?.orderOut(nil)
        guard feedSize == nil else { return }
        sessionQueue.async { [session] in session.stopRunning() }
    }

    /// Switches to another camera without moving the bubble.
    func use(_ camera: AVCaptureDevice) throws {
        guard input?.device.uniqueID != camera.uniqueID else { return }
        let newInput = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            updateFrameOutput()   // the new camera's frames may be a different shape
            applyMirroring()
            applySize()   // a landscape bubble follows the new camera's shape
        }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            throw BubbleError.cameraUnavailable
        }
        session.addInput(newInput)
        input = newInput
        if feedSize == nil { useSessionPreset(forRecording: false) }
    }

    /// Moves the bubble into the bottom-left corner of `rect` (global coordinates) unless its
    /// centre is already inside.
    func keep(inside rect: NSRect) {
        guard let panel, !rect.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) else { return }
        panel.setFrameOrigin(Self.corner(.bottomLeft, of: rect, size: size))
    }

    /// Moves the bubble by the same amount as something it sits on (a window being recorded).
    func move(by offset: CGSize) {
        guard let panel else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + offset.width, y: panel.frame.minY + offset.height))
    }

    // MARK: - Camera feed for Camera Only recordings

    /// Hands every camera frame to `handler` on `queue`, with the background effect and mirrored like
    /// the preview, at up to 1080p in the camera's own shape. Returns the size of the recording (the
    /// middle of the frames, in the bubble's shape) and the clock the frames' times are on.
    func startFeed(on queue: DispatchQueue, handler: @escaping (CVPixelBuffer, CMTime) -> Void) throws -> (width: Int, height: Int, clock: CMClock) {
        guard let device = input?.device else { throw BubbleError.noCamera }
        // The camera's best picture for recording, chosen directly: a session preset can switch the
        // camera's format a moment later, after the recording's size has already been decided.
        if let format = Self.recordingFormat(of: device), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            device.unlockForConfiguration()
        } else {
            session.beginConfiguration()
            useSessionPreset(forRecording: true)
            session.commitConfiguration()
        }
        let size = Self.frameSize(of: device, within: CGSize(width: 1920, height: 1080))
        let recording = Self.middle(of: size, aspectRatio: shape.aspectRatio)
        feedSize = size
        guard updateFrameOutput() else {
            feedSize = nil
            session.beginConfiguration()
            useSessionPreset(forRecording: false)
            session.commitConfiguration()
            throw BubbleError.cameraUnavailable
        }
        feedLock.lock()
        feed = (queue, handler)
        feedLock.unlock()
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        return (recording.width, recording.height, session.synchronizationClock ?? CMClockGetHostTimeClock())
    }

    func stopFeed() {
        guard feedSize != nil else { return }
        feedLock.lock()
        feed = nil
        feedLock.unlock()
        feedSize = nil
        session.beginConfiguration()
        useSessionPreset(forRecording: false)
        session.commitConfiguration()
        updateFrameOutput()
        if !isVisible { sessionQueue.async { [session] in session.stopRunning() } }
    }

    /// Adds, resizes or removes the frame output to suit what needs frames now. False if frames
    /// are needed but the camera won't give them.
    @discardableResult
    private func updateFrameOutput() -> Bool {
        var wanted = feedSize
        if wanted == nil, background != .none, let device = input?.device {
            wanted = Self.frameSize(of: device, within: CGSize(width: 1280, height: 720))
        }
        guard let wanted else {
            if let frameOutput {
                session.beginConfiguration()
                session.removeOutput(frameOutput)
                session.commitConfiguration()
            }
            frameOutput = nil
            frameSize = nil
            return true
        }
        guard wanted != frameSize || frameOutput == nil else { return true }
        let output = frameOutput ?? AVCaptureVideoDataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: wanted.width,
            kCVPixelBufferHeightKey as String: wanted.height,
        ]
        if frameOutput == nil {
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            frameOutput = output
        }
        frameSize = wanted
        applyMirroring()
        return true
    }

    /// The camera's largest picture that fits in 1920×1080 and runs at 30 frames a second or more
    /// (1080p on most cameras, including an iPhone's).
    private static func recordingFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func pixels(_ format: AVCaptureDevice.Format) -> Int32 {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width <= 1920 && size.height <= 1080 ? size.width * size.height : 0
        }
        return device.formats
            .filter { pixels($0) > 0 && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 } }
            .max { pixels($0) < pixels($1) }
    }

    /// The camera's picture size, scaled down (keeping its shape) to fit `limit`, in even numbers.
    private static func frameSize(of device: AVCaptureDevice, within limit: CGSize) -> FrameSize {
        let format = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fit = min(1, limit.width / CGFloat(format.width), limit.height / CGFloat(format.height))
        return FrameSize(width: max(2, Int(CGFloat(format.width) * fit) & ~1),
                         height: max(2, Int(CGFloat(format.height) * fit) & ~1))
    }

    /// The largest part of the middle of a picture `size` big with this shape, in even numbers.
    private static func middle(of size: FrameSize, aspectRatio: CGFloat?) -> FrameSize {
        guard let aspectRatio else { return size }
        let width = min(CGFloat(size.width), CGFloat(size.height) * aspectRatio)
        return FrameSize(width: max(2, Int(width) & ~1), height: max(2, Int(width / aspectRatio) & ~1))
    }

    /// Runs on `frameQueue` for each camera frame: applies the background effect, shows the result
    /// in the bubble, and passes it to the recorder during a Camera Only recording.
    private func handle(_ camera: CVPixelBuffer, at time: CMTime) {
        let withEffect = effects.background != .none
        let frame = withEffect ? effects.process(camera) ?? camera : camera
        if withEffect { display(frame) }
        feedLock.lock()
        let feed = self.feed
        feedLock.unlock()
        if let feed { feed.queue.async { feed.handler(frame, time) } }
    }

    private func display(_ frame: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame, formatDescription: format,
                                                                   sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let renderer = effectLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(sample)
    }

    /// Shows the bubble with a still picture in place of the camera, through the same effects and
    /// display as camera frames. For `--effects-test`, which can't use the camera.
    func showStill(_ picture: CVPixelBuffer, home: NSRect) {
        if panel == nil { makePanel(at: Self.corner(.bottomLeft, of: home, size: size)) }
        applySize()
        panel?.orderFrontRegardless()
        frameQueue.sync { handle(picture, at: .zero) }
    }

    /// 720p is plenty for a preview; recordings get the best the camera offers, up to 1080p.
    private func useSessionPreset(forRecording: Bool) {
        let preferred: [AVCaptureSession.Preset] = forRecording ? [.hd1920x1080, .high] : [.hd1280x720, .high]
        if let preset = preferred.first(where: session.canSetSessionPreset) { session.sessionPreset = preset }
    }

    private func applyMirroring() {
        view?.mirror(mirrored)
        if let connection = frameOutput?.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    // MARK: - Window

    private var size: NSSize { size(diameter: diameter) }

    private func size(diameter: CGFloat) -> NSSize {
        switch shape {
        case .circle, .square:
            return NSSize(width: diameter, height: diameter)
        case .landscape:
            let width = diameter * Self.rectangleScale
            return NSSize(width: width, height: (width / cameraAspect).rounded())
        case .portrait:
            let height = diameter * Self.rectangleScale
            return NSSize(width: (height * 9 / 16).rounded(), height: height)
        }
    }

    private func makePanel(at origin: NSPoint) {
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let view = BubbleView(session: session, effectLayer: effectLayer)
        view.showsEffects = background != .none
        view.onMoved = { [weak self] in self?.snapToCorner() }
        view.onResize = { [weak self] pointer, center, finished in
            guard let self else { return }
            let dx = abs(pointer.x - center.x), dy = abs(pointer.y - center.y)
            let proposed: CGFloat
            if self.shape == .circle {
                proposed = 2 * hypot(dx, dy)
            } else {
                // The size whose edge is under the pointer, across or up, whichever is further out.
                let reference = self.size(diameter: 1000)
                proposed = 1000 * max(2 * dx / reference.width, 2 * dy / reference.height)
            }
            self.diameter = min(max(proposed, Self.diameterRange.lowerBound), Self.diameterRange.upperBound)
            if finished { self.onResize?(self.diameter) }
        }
        panel.contentView = view
        self.panel = panel
        self.view = view
        applyMirroring()
    }

    /// Applies the size and shape, keeping the centre where it was but never letting the bubble
    /// leave its screen.
    private func applySize() {
        guard let panel else { return }
        view?.isRound = shape == .circle
        let size = self.size
        var frame = NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        if let screen = panel.screen ?? NSScreen.main {
            let bounds = screen.frame
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }

    private func snapToCorner() {
        guard let panel, let bounds = snapBounds?(panel.frame) else { return }
        let nearest = Corner.allCases
            .map { Self.corner($0, of: bounds, size: panel.frame.size) }
            .min { panel.frame.origin.distance(to: $0) < panel.frame.origin.distance(to: $1) }
        guard let nearest, panel.frame.origin.distance(to: nearest) < Self.snapDistance else { return }
        panel.setFrame(NSRect(origin: nearest, size: panel.frame.size), display: true, animate: true)
    }

    private enum Corner: CaseIterable { case bottomLeft, bottomRight, topLeft, topRight }

    private static func corner(_ corner: Corner, of rect: NSRect, size: NSSize) -> NSPoint {
        let left = rect.minX + margin, right = rect.maxX - margin - size.width
        let bottom = rect.minY + margin, top = rect.maxY - margin - size.height
        switch corner {
        case .bottomLeft: return NSPoint(x: left, y: bottom)
        case .bottomRight: return NSPoint(x: right, y: bottom)
        case .topLeft: return NSPoint(x: left, y: top)
        case .topRight: return NSPoint(x: right, y: top)
        }
    }
}

extension CameraBubble: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        handle(pixelBuffer, at: sampleBuffer.presentationTimeStamp)
    }
}

private extension NSPoint {
    func distance(to other: NSPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

/// The camera preview, a circle or a rounded rectangle, with no border. When the pointer is on
/// its edge, a ring in the accent colour shows it can be dragged to resize.
private final class BubbleView: NSView {
    var onMoved: (() -> Void)?
    /// Where the pointer is, the centre to resize around, and whether the drag has ended.
    var onResize: ((NSPoint, NSPoint, Bool) -> Void)?
    var isRound = true {
        didSet { needsLayout = true }
    }
    /// Whether the frames with the background effect cover the plain preview.
    var showsEffects = false {
        didSet {
            guard showsEffects != oldValue else { return }
            // Drop the last frame shown, so turning the effect on again doesn't flash an old one.
            effectLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectLayer.isHidden = !showsEffects
            CATransaction.commit()
        }
    }

    private enum Drag {
        case move(grab: NSPoint)
        case resize(center: NSPoint)
    }

    private static let rimWidth: CGFloat = 16
    private static let rectangleCornerRadius: CGFloat = 18
    private let preview: AVCaptureVideoPreviewLayer
    private let effectLayer: AVSampleBufferDisplayLayer
    private var drag: Drag?
    private var rimHighlighted = false {
        didSet { if rimHighlighted != oldValue { updateRim() } }
    }

    init(session: AVCaptureSession, effectLayer: AVSampleBufferDisplayLayer) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        self.effectLayer = effectLayer
        super.init(frame: .zero)
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.cgColor
        layer.masksToBounds = true
        layer.borderWidth = 0
        preview.videoGravity = .resizeAspectFill
        layer.addSublayer(preview)
        effectLayer.videoGravity = .resizeAspectFill
        effectLayer.isHidden = true
        layer.addSublayer(effectLayer)
        updateRim()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func mirror(_ mirrored: Bool) {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = isRound ? bounds.width / 2 : Self.rectangleCornerRadius
        preview.frame = bounds
        effectLayer.frame = bounds
        CATransaction.commit()
        // The window shadow follows the opaque pixels, so redo it once the shape is drawn.
        DispatchQueue.main.async { [weak self] in self?.window?.invalidateShadow() }
    }

    private func updateRim() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // No border normally: just the camera picture. The edge shows only while the pointer is on
        // it, to show where to drag to resize.
        layer?.borderWidth = rimHighlighted ? 4 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
    }

    private func isOnRim(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if isRound {
            let distance = hypot(point.x - bounds.midX, point.y - bounds.midY)
            return distance > bounds.width / 2 - Self.rimWidth && distance <= bounds.width / 2
        }
        return bounds.contains(point) && !bounds.insetBy(dx: Self.rimWidth, dy: Self.rimWidth).contains(point)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        rimHighlighted = isOnRim(event)
        (rimHighlighted ? NSCursor.crosshair : NSCursor.openHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        rimHighlighted = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if isOnRim(event) {
            drag = .resize(center: NSPoint(x: window.frame.midX, y: window.frame.midY))
        } else {
            drag = .move(grab: NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY))
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let drag else { return }
        let mouse = NSEvent.mouseLocation
        switch drag {
        case .move(let grab):
            window.setFrameOrigin(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
        case .resize(let center):
            onResize?(mouse, center, false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .move:
            onMoved?()
            NSCursor.openHand.set()
        case .resize(let center):
            onResize?(NSEvent.mouseLocation, center, true)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
