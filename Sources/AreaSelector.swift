import AppKit

/// Full-screen overlay for choosing the part of the screen to record (Loom calls this "Custom Size").
/// Drag to draw an area, drag inside it to move it, drag a handle to resize it, or type the video
/// size. Return or Done confirms; Esc or Cancel keeps the previous choice.
final class AreaSelector {
    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    /// `initial` and the result are in the screen's own points, origin at its bottom-left.
    /// The completion gets nil if the user cancels.
    func begin(on screen: NSScreen, initial: CGRect?, completion: @escaping (CGRect?) -> Void) {
        guard window == nil else { return }
        let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Without this, clicks inside the clear area would fall through to the windows beneath.
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)

        let view = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                     scale: screen.backingScaleFactor, initial: initial)
        view.onFinish = { [weak self] rect in
            self?.window?.orderOut(nil)
            self?.window = nil
            completion(rect)
        }
        window.contentView = view
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }
}

/// Borderless windows can't take keyboard focus unless they say so.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AreaSelectionView: NSView {
    /// Fixed video sizes in pixels, as offered by most screen recorders.
    static let presets: [(title: String, width: CGFloat, height: CGFloat)] = [
        ("1080p", 1920, 1080), ("720p", 1280, 720), ("Square", 1080, 1080), ("Vertical", 1080, 1920),
    ]

    var onFinish: ((CGRect?) -> Void)?
    private(set) var area: CGRect?

    private static let minimumSide: CGFloat = 32
    private static let handleSize: CGFloat = 10
    private let scale: CGFloat
    private var drag: Drag?
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private enum Drag {
        case draw(from: NSPoint)
        case move(grab: CGSize)
        case resize(Handle, original: CGRect)
    }

    init(frame: NSRect, scale: CGFloat, initial: CGRect?) {
        self.scale = scale
        super.init(frame: frame)
        if let initial, bounds.contains(initial) { area = aligned(initial) }
        addToolbar()
        updateToolbar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Sets the area to a video size in pixels, keeping its centre, shrunk if needed to fit the screen.
    func setSize(pixels: CGSize) {
        var size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let fit = min(1, bounds.width / size.width, bounds.height / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let center = area.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        area = aligned(rect.shifted(inside: bounds))
        changed()
    }

    // MARK: - Toolbar

    private func addToolbar() {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 2
        formatter.maximum = 16_384
        for field in [widthField, heightField] {
            field.formatter = formatter
            field.alignment = .right
            field.target = self
            field.action = #selector(applyTypedSize)
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        let presets = Self.presets.enumerated().map { index, preset -> NSButton in
            let button = NSButton(title: preset.title, target: self, action: #selector(applyPreset(_:)))
            button.tag = index
            return button
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        doneButton.target = self
        doneButton.action = #selector(confirm)
        doneButton.bezelColor = .controlAccentColor

        let sizeLabel = NSTextField(labelWithString: "Video size")
        let times = NSTextField(labelWithString: "×")
        let pixels = NSTextField(labelWithString: "px")
        let stack = NSStackView(views: [sizeLabel, widthField, times, heightField, pixels] + presets + [cancel, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.setCustomSpacing(18, after: pixels)
        stack.setCustomSpacing(18, after: presets.last!)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSVisualEffectView()
        toolbar.material = .hudWindow
        toolbar.blendingMode = .behindWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        toolbar.layer?.masksToBounds = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        addSubview(toolbar)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -96),
        ])
    }

    private func updateToolbar() {
        let pixels = area.map { ScreenRecorder.outputSize(points: $0.size, scale: scale) }
        // Don't overwrite a number while it is being typed.
        if widthField.currentEditor() == nil { widthField.stringValue = pixels.map { "\($0.width)" } ?? "" }
        if heightField.currentEditor() == nil { heightField.stringValue = pixels.map { "\($0.height)" } ?? "" }
        doneButton.isEnabled = area != nil
    }

    @objc private func applyPreset(_ sender: NSButton) {
        let preset = Self.presets[sender.tag]
        window?.makeFirstResponder(self)
        setSize(pixels: CGSize(width: preset.width, height: preset.height))
    }

    @objc private func applyTypedSize() {
        applyFields()
    }

    /// Applies the typed width and height if they differ from the area's current video size.
    private func applyFields() {
        window?.makeFirstResponder(self)
        let width = widthField.integerValue, height = heightField.integerValue
        guard width >= 2, height >= 2 else { return updateToolbar() }
        let current = area.map { ScreenRecorder.outputSize(points: $0.size, scale: scale) }
        if current?.width != width || current?.height != height {
            setSize(pixels: CGSize(width: width, height: height))
        }
    }

    @objc private func confirm() {
        applyFields()
        guard let area else { return NSSound.beep() }
        onFinish?(area)
    }

    @objc private func cancel() {
        onFinish?(nil)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()            // Esc
        case 36, 76: confirm()       // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let area, let handle = Handle.allCases.first(where: { handleRect($0, of: area).insetBy(dx: -4, dy: -4).contains(point) }) {
            drag = .resize(handle, original: area)
        } else if let area, area.contains(point) {
            drag = .move(grab: CGSize(width: point.x - area.minX, height: point.y - area.minY))
            NSCursor.closedHand.set()
        } else {
            drag = .draw(from: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil).clamped(to: bounds)
        switch drag {
        case .draw(let start):
            area = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        case .move(let grab):
            guard let current = area else { return }
            area = CGRect(origin: CGPoint(x: point.x - grab.width, y: point.y - grab.height), size: current.size).shifted(inside: bounds)
        case .resize(let handle, let original):
            area = handle.resize(original, to: point, minimumSide: Self.minimumSide)
        case nil:
            return
        }
        area = area.map(aligned)
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        // A drawn area too small to be deliberate is treated as a stray click.
        if case .draw = drag, let area, area.width < Self.minimumSide || area.height < Self.minimumSide {
            self.area = nil
        }
        drag = nil
        changed()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let area else { return }
        addCursorRect(area, cursor: .openHand)
        for handle in Handle.allCases {
            addCursorRect(handleRect(handle, of: area).insetBy(dx: -4, dy: -4), cursor: handle.cursor)
        }
    }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateToolbar()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let area {
            shade.append(NSBezierPath(rect: area))
            shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.5).setFill()
        shade.fill()

        guard let area else {
            drawText("Drag to choose the area to record", size: 22, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY + 14))
            drawText("Or pick a size below · Esc to cancel", size: 14, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY - 16))
            return
        }

        // Nearly clear rather than clear, so the window keeps receiving clicks inside the area.
        NSColor(white: 1, alpha: 0.01).setFill()
        area.fill()

        let border = NSBezierPath(rect: area.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        NSColor.white.setStroke()
        border.stroke()

        for handle in Handle.allCases {
            let knob = NSBezierPath(roundedRect: handleRect(handle, of: area), xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            knob.fill()
            NSColor.black.withAlphaComponent(0.4).setStroke()
            knob.lineWidth = 1
            knob.stroke()
        }

        let pixels = ScreenRecorder.outputSize(points: area.size, scale: scale)
        let labelY = area.maxY + 30 < bounds.maxY ? area.maxY + 18 : area.maxY - 22
        drawText("\(pixels.width) × \(pixels.height)", size: 13, centeredAt: NSPoint(x: area.midX, y: labelY), pill: true)
    }

    private func drawText(_ string: String, size: CGFloat, centeredAt center: NSPoint, pill: Bool = false) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let origin = NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2)
        if pill {
            NSColor.black.withAlphaComponent(0.75).setFill()
            let background = NSRect(origin: origin, size: textSize).insetBy(dx: -8, dy: -3)
            NSBezierPath(roundedRect: background, xRadius: background.height / 2, yRadius: background.height / 2).fill()
        }
        text.draw(at: origin)
    }

    private func handleRect(_ handle: Handle, of area: CGRect) -> CGRect {
        let center = handle.position(in: area)
        let side = Self.handleSize
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Lines the area up with whole pixels so the recorded size is exact.
    private func aligned(_ rect: CGRect) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(x: snap(rect.minX), y: snap(rect.minY), width: snap(rect.width), height: snap(rect.height))
    }
}

private enum Handle: CaseIterable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

    private var movesLeft: Bool { self == .bottomLeft || self == .left || self == .topLeft }
    private var movesRight: Bool { self == .bottomRight || self == .right || self == .topRight }
    private var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    private var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }

    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    func position(in rect: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                y: movesBottom ? rect.minY : movesTop ? rect.maxY : rect.midY)
    }

    /// Moves this handle's edges to `point`, never letting the area get smaller than `minimumSide`.
    func resize(_ rect: CGRect, to point: CGPoint, minimumSide: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if movesLeft { minX = min(point.x, maxX - minimumSide) }
        if movesRight { maxX = max(point.x, minX + minimumSide) }
        if movesBottom { minY = min(point.y, maxY - minimumSide) }
        if movesTop { maxY = max(point.y, minY + minimumSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A thin frame drawn just outside the custom area so you can see what will be recorded: dashed
/// white while idle, red while recording. It sits outside the captured rectangle, so it never
/// appears in the movie, and clicks pass straight through it.
final class AreaOutline {
    private var window: NSWindow?
    private let view = OutlineView()

    func show(around rect: NSRect, recording: Bool) {
        let window = self.window ?? makeWindow()
        window.setFrame(rect.insetBy(dx: -OutlineView.thickness, dy: -OutlineView.thickness), display: false)
        view.recording = recording
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        self.window = window
        return window
    }
}

private final class OutlineView: NSView {
    static let thickness: CGFloat = 4

    var recording = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: Self.thickness / 2, dy: Self.thickness / 2))
        if recording {
            path.lineWidth = 2
            NSColor.systemRed.setStroke()
            path.stroke()
        } else {
            path.lineWidth = 3
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.stroke()
            path.lineWidth = 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
        }
    }
}

private extension NSPoint {
    func clamped(to rect: CGRect) -> NSPoint {
        NSPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}

private extension CGRect {
    /// Slides the rectangle (without resizing it) until it lies inside `bounds`.
    func shifted(inside bounds: CGRect) -> CGRect {
        CGRect(x: min(max(minX, bounds.minX), bounds.maxX - width),
               y: min(max(minY, bounds.minY), bounds.maxY - height),
               width: width, height: height)
    }
}
