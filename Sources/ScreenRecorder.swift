import AVFoundation
import os
import ScreenCaptureKit

/// What the recorder did with the microphone, for diagnosing a recording with no sound:
/// `log show --last 10m --predicate 'subsystem == "local.myloom"'`
private let log = Logger(subsystem: "local.myloom", category: "recorder")

enum RecorderError: LocalizedError {
    case noDisplays
    case displayNotFound
    case windowNotFound
    case windowClosed
    case microphoneUnavailable
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No screen can be recorded right now. macOS offers none while the displays are asleep or the Mac is locked."
        case .displayNotFound: return "The selected screen isn't available. Pick another one from the Screen menu."
        case .windowNotFound: return "The chosen window isn't on screen any more. Choose it again with Record Window…."
        case .windowClosed: return "The window being recorded was closed."
        case .microphoneUnavailable: return "The selected microphone couldn't be opened."
        case .notRecording: return "Nothing is being recorded."
        }
    }
}

/// What a recording captures.
enum CaptureSource {
    /// A display, or `area` of it, in the display's points with the origin at its top-left (how
    /// ScreenCaptureKit measures it).
    case display(CGDirectDisplayID, area: CGRect?)
    /// One window, with other windows (the camera bubble) drawn over it where they overlap it.
    case window(CGWindowID, alsoShowing: [CGWindowID])
    /// The camera alone.
    case camera(CameraFeed)
}

/// What Camera Only recording needs from the camera: its frames, the recording's size, and the
/// frames' clock. Frames can be larger than the recording and another shape; the recording is
/// filled from their middle.
protocol CameraFeed: AnyObject {
    func startFeed(on queue: DispatchQueue, handler: @escaping (CVPixelBuffer, CMTime) -> Void) throws -> (width: Int, height: Int, clock: CMClock)
    func stopFeed()
}

/// Records the screen, a window or the camera, with a microphone, into an .mp4. Loom's recorder
/// splits capture the same way: `SckVideoSource` (ScreenCaptureKit) for the screen and windows, an
/// `AVCaptureSession` for audio, and the camera on its own in camera-only mode. Everything runs on
/// this Mac; nothing is uploaded.
///
/// `writer` and the clock offsets are only touched on `queue`, which is what makes sharing it safe.
/// Window tracking runs on the main queue.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    static let frameRate = 30

    /// Called on the main queue when capture stops by itself: the display is unplugged, sharing is
    /// stopped from the macOS menu bar, or the window being recorded is closed.
    var onInterrupted: ((Error) -> Void)?
    /// Called on the main queue when the microphone disconnects mid-recording, with the name of
    /// the one lost and of the one that took over (nil if there was none left).
    var onMicrophoneChanged: ((_ lost: String, _ replacement: String?) -> Void)?
    /// Called on the main queue when the window being recorded moves or resizes (Quartz coordinates).
    var onWindowMoved: ((_ from: CGRect, _ to: CGRect) -> Void)?

    /// Every sample is appended to the writer on this queue.
    private let queue = DispatchQueue(label: "MyLoom.recorder", qos: .userInitiated)
    /// The stream whose frames are recorded (none for Camera Only), and its settings, which change
    /// as a recorded window moves.
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    /// A tiny whole-display stream that only supplies the computer's sound, when the video stream
    /// can't: a window recording only hears that window's app, and Camera Only has no video stream.
    private var soundStream: SCStream?
    private var cameraFeed: CameraFeed?
    private var microphone: AVCaptureSession?
    private var microphoneDevice: AVCaptureDevice?
    /// Microphone buffers received and how loud the loudest sample was (on `queue`), so a microphone
    /// that sends nothing, or only silence, can be reported after recording.
    private var microphoneBuffers = 0
    private var microphonePeak: Float = 0
    private var microphoneStartedAt = CMTime.invalid
    private var microphoneName: String?

    /// After a recording with a microphone: its name, and whether it sent nothing at all, or only
    /// silence (every sample zero, as a muted mic does). Nil if it was heard.
    var microphoneProblem: (name: String, sentNothing: Bool)? {
        queue.sync {
            guard let microphoneName, microphonePeak == 0 else { return nil }
            return (microphoneName, microphoneBuffers == 0)
        }
    }
    private var disconnectObserver: NSObjectProtocol?
    private var writer: MovieWriter?
    /// Mic and camera timestamps are on their capture sessions' clocks. These move them onto the
    /// host clock that ScreenCaptureKit and the writer use. Each is measured once, so the sound and
    /// picture stay continuous.
    private var audioClockOffset: CMTime?
    private var cameraClock: CMClock?
    private var cameraClockOffset: CMTime?
    /// When the computer's sound is recorded, both it and the mic go through this into one stereo
    /// track; otherwise it's nil and the mic goes straight to the writer.
    private var mixer: AudioMixer?
    private var mixTimer: DispatchSourceTimer?
    /// Which stream's frames go into the movie. Only touched on `queue`.
    private var videoStreamID: ObjectIdentifier?

    private struct TrackedWindow {
        let id: CGWindowID
        let display: SCDisplay
        var frame: CGRect
        var included: [CGWindowID]
    }
    private var trackedWindow: TrackedWindow?
    private var windowTimer: DispatchSourceTimer?
    /// Host time the window being recorded was last seen, and when it was found closed: the movie
    /// ends there rather than on the black frames after it.
    private var windowLastSeen: CMTime?
    private var windowClosedAt: CMTime?

    /// Starts capturing `source`. Capture begins straight away, but the movie only starts at host time
    /// `start` when given, so capture is already running when a countdown reaches zero.
    /// `excludedWindowIDs` are left out of a display recording (the countdown itself).
    /// With `computerSound`, ScreenCaptureKit's `capturesAudio` records what the Mac is playing,
    /// mixed with the microphone, where Loom installs a virtual audio driver instead. With
    /// `cancelEcho` too, WebRTC's echo canceller removes the computer's sound from the microphone.
    func start(_ source: CaptureSource, microphone device: AVCaptureDevice?, computerSound: Bool = false, cancelEcho: Bool = true,
               excludingWindows excludedWindowIDs: [CGWindowID] = [], startingAt start: CMTime? = nil,
               to url: URL) async throws {
        var stream: SCStream?
        var tracked: TrackedWindow?
        let size: (width: Int, height: Int)
        var soundStream: SCStream?
        var bitsPerPixel = 0.1

        switch source {
        case .display(let displayID, let area):
            let content = try await Self.shareableContent()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayNotFound
            }
            // Everything else is kept, so the camera bubble and drawings are recorded wherever they are
            // on this screen. Windows to leave out may be off screen for now (the drawing toolbar, a
            // notice) and appear later, so they're looked for among all windows.
            let everything = excludedWindowIDs.isEmpty ? content
                : try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let excluded = everything.windows.filter { excludedWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            size = Self.outputSize(points: area?.size ?? filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
            stream = try makeStream(filter: filter, size: size, sourceRect: area, computerSound: computerSound)

        case .window(let windowID, let extras):
            // As Loom's recorder does (includedWindowIds plus a crop): capture the window's display
            // with only the chosen windows drawn, cropped to the window. Windows in front of it are
            // left out; the bubble is drawn where it overlaps.
            let content = try await Self.shareableContent()
            guard let window = content.windows.first(where: { $0.windowID == windowID }),
                  let display = Self.display(showing: window.frame, in: content.displays) else {
                throw RecorderError.windowNotFound
            }
            let included = [window] + content.windows.filter { extras.contains($0.windowID) && $0.windowID != windowID }
            let filter = SCContentFilter(display: display, including: included)
            let crop = Self.crop(window.frame, on: display)
            size = Self.outputSize(points: crop.size, scale: CGFloat(filter.pointPixelScale))
            stream = try makeStream(filter: filter, size: size, sourceRect: crop, computerSound: false)
            tracked = TrackedWindow(id: windowID, display: display, frame: window.frame, included: included.map(\.windowID))
            // A filter of chosen windows only hears those windows' apps, so hear the whole display separately.
            if computerSound { soundStream = try makeSoundStream(on: display) }

        case .camera(let feed):
            if computerSound {
                let content = try await Self.shareableContent()
                soundStream = try makeSoundStream(on: content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays[0])
            }
            let info = try await MainActor.run {
                try feed.startFeed(on: queue) { [weak self] frame, time in self?.cameraFrame(frame, at: time) }
            }
            size = (info.width, info.height)
            queue.sync { cameraClock = info.clock }
            cameraFeed = feed
            // A camera picture is busier than a screen and needs more bits to look clean.
            bitsPerPixel = 0.2
        }

        let writer: MovieWriter
        let microphone: AVCaptureSession?
        let mixer: AudioMixer?
        do {
            writer = try MovieWriter(url: url, width: size.width, height: size.height, frameRate: Self.frameRate,
                                     bitsPerPixel: bitsPerPixel, audioChannels: computerSound ? 2 : device == nil ? 0 : 1,
                                     fillingFrame: cameraFeed != nil, startingAt: start)
            microphone = try device.map(makeMicrophoneSession)
            mixer = computerSound ? try AudioMixer(origin: CMClockGetTime(CMClockGetHostTimeClock()),
                                                   cancelEcho: cancelEcho && device != nil) : nil
        } catch {
            await stopCameraFeed()
            throw error
        }

        queue.sync {
            self.writer = writer
            self.mixer = mixer
            videoStreamID = stream.map(ObjectIdentifier.init)
            audioClockOffset = nil
            cameraClockOffset = nil
        }
        self.stream = stream
        self.soundStream = soundStream
        self.microphone = microphone
        microphoneDevice = device
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let lost = notification.object as? AVCaptureDevice,
                  lost.uniqueID == self.microphoneDevice?.uniqueID else { return }
            self.replaceMicrophone(lost)
        }

        do {
            queue.sync { microphoneName = nil }
            if let microphone {
                queue.sync {
                    microphoneName = device?.localizedName
                    microphoneBuffers = 0
                    microphonePeak = 0
                    microphoneStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
                }
                log.notice("microphone starting: \(device?.localizedName ?? "?", privacy: .public)")
                await Self.run { microphone.startRunning() }
            }
            try await stream?.startCapture()
            try await soundStream?.startCapture()
        } catch {
            microphone?.stopRunning()
            stopWatchingMicrophone()
            await stopCameraFeed()
            try? await stream?.stopCapture()
            self.stream = nil
            self.soundStream = nil
            self.microphone = nil
            queue.sync { self.writer = nil }
            writer.cancel()
            throw error
        }

        if let tracked { await MainActor.run { trackWindow(tracked) } }
        if mixer != nil { startMixing() }
        if let start {
            // If nothing changes after the countdown, no new frame would start the movie.
            let delay = max(0, (start - CMClockGetTime(CMClockGetHostTimeClock())).seconds)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.writer?.beginAtRequestedStart() }
        }
    }

    /// Leaves paused time out of the movie from host time `time` until `resume(at:)`.
    func pause(at time: CMTime) {
        queue.async { self.writer?.pause(at: time) }
    }

    func resume(at time: CMTime) {
        queue.async { self.writer?.resume(at: time) }
    }

    /// In a window recording, also draws `windowID` (the camera bubble or a drawing window shown
    /// after recording began). The filter is rebuilt from every window it should draw that's on
    /// screen now, so one that left the screen and came back is drawn again.
    func alsoShow(_ windowID: CGWindowID) async {
        guard var tracked = await MainActor.run(body: { trackedWindow }),
              let stream, let content = try? await Self.shareableContent() else { return }
        if !tracked.included.contains(windowID) { tracked.included.append(windowID) }
        let windows = tracked.included.compactMap { id in content.windows.first { $0.windowID == id } }
        try? await stream.updateContentFilter(SCContentFilter(display: tracked.display, including: windows))
        let updated = tracked
        await MainActor.run { if trackedWindow != nil { trackedWindow = updated } }
    }

    /// Stops capturing and throws the recording away (a countdown that was cancelled).
    func cancel() async {
        await stopCapturing()
        await withCheckedContinuation { continuation in
            queue.async {
                self.mixer = nil
                self.writer?.cancel()
                self.writer = nil
                continuation.resume()
            }
        }
    }

    /// Stops capturing and finishes the file. Pass the host time to end the movie at, or nil for now.
    func stop(endingAt endTime: CMTime?) async throws -> URL {
        var end = endTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        if let closedAt = await MainActor.run(body: { windowClosedAt }) { end = CMTimeMinimum(end, closedAt) }
        await stopCapturing()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let writer = self.writer else {
                    continuation.resume(throwing: RecorderError.notRecording)
                    return
                }
                // Capture has stopped, so every buffer is in: hand on the rest of the mix.
                if let mixer = self.mixer {
                    mixer.drain(upTo: end, flush: true).forEach(writer.appendAudio)
                    self.mixer = nil
                }
                self.writer = nil
                writer.finish(at: end) { continuation.resume(with: $0) }
            }
        }
    }

    /// Hands the mix to the writer every 50 ms, `AudioMixer.delay` behind real time.
    private func startMixing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self, let mixer = self.mixer, let writer = self.writer else { return }
            mixer.drain(upTo: CMClockGetTime(CMClockGetHostTimeClock()) - AudioMixer.delay).forEach(writer.appendAudio)
        }
        timer.resume()
        mixTimer = timer
    }

    private func stopCapturing() async {
        let stream = self.stream
        let soundStream = self.soundStream
        let microphone = self.microphone
        self.stream = nil
        self.soundStream = nil
        self.microphone = nil
        configuration = nil
        await MainActor.run { stopTrackingWindow() }
        stopWatchingMicrophone()
        try? await stream?.stopCapture()   // already stopped if the stream ended with an error
        try? await soundStream?.stopCapture()
        await stopCameraFeed()
        if let microphone {
            await Self.run { microphone.stopRunning() }
            queue.sync {
                log.notice("microphone stopped: \(self.microphoneBuffers) buffers, peak \(self.microphonePeak)")
            }
        }
        mixTimer?.cancel()
        mixTimer = nil
    }

    // MARK: - Setup

    private static func shareableContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw RecorderError.noDisplays }
        return content
    }

    /// The computer's sound only comes with a screen stream, so this is a tiny one-frame-a-second
    /// stream of the whole display whose frames are ignored.
    private func makeSoundStream(on display: SCDisplay) throws -> SCStream {
        try makeStream(filter: SCContentFilter(display: display, excludingWindows: []), size: (128, 72), sourceRect: nil,
                       computerSound: true, frameInterval: CMTime(value: 1, timescale: 1), isVideo: false)
    }

    private func makeStream(filter: SCContentFilter, size: (width: Int, height: Int), sourceRect: CGRect?,
                            computerSound: Bool,
                            frameInterval: CMTime = CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                            isVideo: Bool = true) throws -> SCStream {
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = frameInterval
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 6
        config.showsCursor = true
        config.preservesAspectRatio = true
        config.ignoreShadowsDisplay = true   // a window recording shouldn't show the shadow around it
        if computerSound {
            config.capturesAudio = true
            config.sampleRate = Int(AudioMixer.sampleRate)
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true   // MyLoom's own sounds stay out
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if computerSound { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if isVideo { configuration = config }
        return stream
    }

    private func stopCameraFeed() async {
        guard let feed = cameraFeed else { return }
        cameraFeed = nil
        await MainActor.run { feed.stopFeed() }
    }

    private func makeMicrophoneSession(_ device: AVCaptureDevice) throws -> AVCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = MovieWriter.microphonePCMSettings
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecorderError.microphoneUnavailable
        }
        session.addInput(input)
        session.addOutput(output)
        return session
    }

    /// Keeps the recording's sound going when its microphone goes away (a USB mic unplugged, an iPhone
    /// carried off): switches to the system default input, or the first one left.
    private func replaceMicrophone(_ lost: AVCaptureDevice) {
        guard let session = microphone else { return }
        let others = Devices.microphones().filter { $0.uniqueID != lost.uniqueID }
        let replacement = AVCaptureDevice.default(for: .audio).flatMap { fallback in others.first { $0.uniqueID == fallback.uniqueID } }
            ?? others.first

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        microphoneDevice = nil
        if let replacement, let input = try? AVCaptureDeviceInput(device: replacement), session.canAddInput(input) {
            session.addInput(input)
            microphoneDevice = replacement
        }
        session.commitConfiguration()
        // A different device has a different clock, so measure the offset again.
        queue.async { self.audioClockOffset = nil }
        onMicrophoneChanged?(lost.localizedName, microphoneDevice?.localizedName)
    }

    private func stopWatchingMicrophone() {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        microphoneDevice = nil
    }

    // MARK: - Following a window

    /// Checks the window once per frame (looking one window up costs microseconds), so a crop chasing
    /// a dragged window lags at most a frame or so. When it moves or resizes, the crop follows (the
    /// video keeps its size, scaling a resized window to fit); when it closes, recording stops.
    private func trackWindow(_ window: TrackedWindow) {
        trackedWindow = window
        windowLastSeen = CMClockGetTime(CMClockGetHostTimeClock())
        windowClosedAt = nil
        let interval = 1.0 / Double(Self.frameRate)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.checkTrackedWindow() }
        timer.resume()
        windowTimer = timer
    }

    private func checkTrackedWindow() {
        guard var tracked = trackedWindow, let stream, let configuration else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let current = WindowInfo.find(tracked.id) else {
            windowClosedAt = windowLastSeen ?? now
            stopTrackingWindow()
            onInterrupted?(RecorderError.windowClosed)
            return
        }
        windowLastSeen = now
        guard current.frame != tracked.frame else { return }
        let crop = Self.crop(current.frame, on: tracked.display)
        onWindowMoved?(tracked.frame, current.frame)
        tracked.frame = current.frame
        trackedWindow = tracked
        guard crop.width >= 2, crop.height >= 2 else { return }   // moved off its display
        configuration.sourceRect = crop
        stream.updateConfiguration(configuration) { _ in }
    }

    private func stopTrackingWindow() {
        windowTimer?.cancel()
        windowTimer = nil
        trackedWindow = nil
    }

    /// The display showing most of `frame` (Quartz coordinates).
    private static func display(showing frame: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays.max { overlap($0.frame, frame) < overlap($1.frame, frame) }.flatMap { overlap($0.frame, frame) > 0 ? $0 : nil }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }

    /// `frame` (Quartz coordinates) as a crop of `display`, in the display's own points.
    private static func crop(_ frame: CGRect, on display: SCDisplay) -> CGRect {
        frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).integral
    }

    // MARK: - Sizes

    /// The pixel size for `points` at `scale`, scaled down only as far as H.264 level 5.2 needs
    /// (4096×2304 frame area).
    static func outputSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let width = points.width * scale
        let height = points.height * scale
        let fit = min(1, 4096 / width, 2304 / height, (4096 * 2304 / (width * height)).squareRoot())
        func even(_ value: CGFloat) -> Int { max(2, Int(value * fit) & ~1) }
        return (even(width), even(height))
    }

    /// Runs blocking capture-session calls off the caller's thread.
    private static func run(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                continuation.resume()
            }
        }
    }
}

// MARK: - Screen frames

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        // The computer's sound is stamped with host time already.
        if type == .audio {
            mixer?.add(sampleBuffer, from: .computer, at: sampleBuffer.presentationTimeStamp)
            return
        }
        // ScreenCaptureKit also sends idle and blank frames; only complete frames carry a new image.
        guard type == .screen, ObjectIdentifier(stream) == videoStreamID,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        writer?.appendFrame(pixelBuffer, at: sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onInterrupted?(error) }
    }
}

// MARK: - Camera frames (Camera Only)

private extension ScreenRecorder {
    /// Runs on `queue`. `time` is on the camera's clock.
    func cameraFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let writer else { return }
        if cameraClockOffset == nil {
            cameraClockOffset = CMSyncConvertTime(time, from: cameraClock ?? CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock()) - time
        }
        guard let offset = cameraClockOffset else { return }
        writer.appendFrame(pixelBuffer, at: time + offset)
    }
}

// MARK: - Microphone

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer else { return }
        let time = sampleBuffer.presentationTimeStamp
        microphoneBuffers += 1
        if let channels = AudioMixer.channels(of: sampleBuffer) {
            for channel in channels { for sample in channel { microphonePeak = max(microphonePeak, abs(sample)) } }
        }
        if audioClockOffset == nil {
            let clock = microphone?.synchronizationClock ?? CMClockGetHostTimeClock()
            audioClockOffset = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()) - time
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            log.notice("first microphone audio after \((now - self.microphoneStartedAt).seconds) s; stamped \((time + (self.audioClockOffset ?? .zero) - now).seconds) s from now")
        }
        guard let offset = audioClockOffset else { return }
        if let mixer {
            mixer.add(sampleBuffer, from: .microphone, at: time + offset)
        } else if let retimed = sampleBuffer.shifted(by: offset) {
            writer.appendAudio(retimed)
        }
    }
}
