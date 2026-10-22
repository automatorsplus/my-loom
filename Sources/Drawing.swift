import AppKit

/// Drawing on the screen during a recording, like Loom's pen: a pen, a highlighter, arrows and
/// boxes, drawn on a clear window over each screen. Those windows are part of the screen, so the
/// recording captures the drawings; the toolbar for choosing a tool and colour is left out of it.
///
/// While drawing is on, the mouse draws instead of clicking, until you press Esc, click Done or use
/// the shortcut. The drawings stay up after that until they fade (if Fade is on), or are undone or cleared.
final class DrawingOverlay: NSObject {
    enum Tool: String, CaseIterable {
        case pen, highlighter, arrow, box

        var title: String {
            switch self {
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .arrow: return "Arrow"
            case .box: return "Box"
            }
        }

        var symbol: String {
            switch self {
            case .pen: return "scribble.variable"
            case .highlighter: return "highlighter"
            case .arrow: return "arrow.up.right"
            case .box: return "rectangle"
            }
        }
    }

    static let colors: [(name: String, color: NSColor)] = [
        ("Red", NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)),
        ("Yellow", NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)),
        ("White", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
    ]
    /// How long a finished drawing stays before fading away, when Fade is on.
    static let fadeDelay: TimeInterval = 5
    static let fadeDuration: TimeInterval = 0.6

    var tool: Tool = .pen {
        didSet { toolbar.showChoices(); onSettingsChanged?() }
    }
    var colorIndex = 0 {
        didSet { toolbar.showChoices(); onSettingsChanged?() }
    }
    var color: NSColor { Self.colors[min(max(colorIndex, 0), Self.colors.count - 1)].color }
    var fades = true {
        didSet {
            guard fades != oldValue else { return }
            if fades { strokes.forEach(scheduleFade) }
            toolbar.showChoices()
            onSettingsChanged?()
        }
    }

    /// Whether the mouse draws.
    private(set) var isDrawing = false
    var hasDrawings: Bool { !strokes.isEmpty }
    var drawingCount: Int { strokes.count }
    var toolbarWindowID: CGWindowID { CGWindowID(toolbar.windowNumber) }
    /// The windows the drawings are on, for screens where they're showing.
    var visibleCanvasIDs: [CGWindowID] { canvases.values.filter(\.isVisible).map { CGWindowID($0.windowNumber) } }

    /// Called when the tool, colour or Fade changes, to remember them.
    var onSettingsChanged: (() -> Void)?
    /// Called when drawing turns on or off, including from Esc and Done.
    var onDrawingChanged: (() -> Void)?
    /// Called with each drawing window put on screen, so a window recording can include it.
    var onCanvasShown: ((CGWindowID) -> Void)?

    private var canvases: [CGDirectDisplayID: CanvasPanel] = [:]
    private let toolbar = ToolbarPanel()
    /// Every drawing on every screen, oldest first, for Undo.
    private var strokes: [Stroke] = []

    override init() {
        super.init()
        toolbar.overlay = self
    }

    // MARK: - On and off

    func toggle() {
        isDrawing ? stop() : start()
    }

    /// The window in front that receives the drawing (for the self-test's safety check).
    var keyCanvasID: CGWindowID? {
        canvases.values.first { $0.isKeyWindow }.map { CGWindowID($0.windowNumber) }
    }

    /// Turns drawing on over every screen, with the toolbar on `screen`, or else the one the pointer is on.
    func start(toolbarOn screen: NSScreen? = nil) {
        guard !isDrawing else { return }
        isDrawing = true
        let mouse = NSEvent.mouseLocation
        let home = screen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        for screen in NSScreen.screens {
            let canvas = canvas(for: screen)
            canvas.ignoresMouseEvents = false
            canvas.allowsKey = true
            show(canvas)
            if screen == home {
                // Key, so Esc, ⌘Z and Delete reach it. The panel doesn't activate MyLoom, so the
                // app you're showing stays in front.
                canvas.makeKey()
                canvas.makeFirstResponder(canvas.contentView)
            }
        }
        toolbar.showChoices()
        toolbar.place(on: home)
        toolbar.orderFrontRegardless()
        onDrawingChanged?()
    }

    /// Gives the mouse back. Drawings already made stay until they fade or are cleared.
    func stop() {
        guard isDrawing else { return }
        isDrawing = false
        toolbar.orderOut(nil)
        for canvas in canvases.values {
            canvas.ignoresMouseEvents = true
            canvas.allowsKey = false
            // Ordering out and back in gives up key status, so typing goes back to your app.
            let keep = canvas.hasStrokes
            canvas.orderOut(nil)
            if keep { canvas.orderFrontRegardless() }
        }
        onDrawingChanged?()
    }

    /// Screens were added, removed or rearranged: start again with fresh drawing windows.
    func screensChanged() {
        let wasDrawing = isDrawing
        stop()
        clear()
        canvases.values.forEach { $0.close() }
        canvases = [:]
        if wasDrawing { start() }
    }

    // MARK: - Drawings

    func undo() {
        guard let last = strokes.last else { return }
        remove(last)
    }

    func clear() {
        strokes.forEach(remove)
    }

    fileprivate func begin(_ tool: Tool, on canvas: CanvasPanel) -> Stroke {
        let stroke = Stroke(tool: tool, color: color, canvas: canvas)
        canvas.contentView?.layer?.addSublayer(stroke.layer)
        return stroke
    }

    /// Keeps a finished drawing, or drops it if it's too small to mean anything (a click with the
    /// arrow or box tool).
    fileprivate func finish(_ stroke: Stroke) {
        guard stroke.isMeaningful else {
            stroke.layer.removeFromSuperlayer()
            return
        }
        strokes.append(stroke)
        stroke.canvas?.hasStrokes = true
        if fades { scheduleFade(stroke) }
    }

    private func scheduleFade(_ stroke: Stroke) {
        stroke.fadeGeneration += 1
        let generation = stroke.fadeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDelay) { [weak self, weak stroke] in
            guard let self, let stroke, self.fades, stroke.fadeGeneration == generation,
                  self.strokes.contains(where: { $0 === stroke }) else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak stroke] in
                guard let self, let stroke, stroke.fadeGeneration == generation else { return }
                self.remove(stroke)
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Self.fadeDuration
            stroke.layer.opacity = 0
            stroke.layer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    private func remove(_ stroke: Stroke) {
        stroke.fadeGeneration += 1
        stroke.layer.removeFromSuperlayer()
        strokes.removeAll { $0 === stroke }
        guard let canvas = stroke.canvas else { return }
        canvas.hasStrokes = strokes.contains { $0.canvas === canvas }
        if !canvas.hasStrokes, !isDrawing { canvas.orderOut(nil) }
    }

    // MARK: - Windows

    private func canvas(for screen: NSScreen) -> CanvasPanel {
        if let canvas = canvases[screen.displayID] {
            canvas.setFrame(screen.frame, display: false)
            return canvas
        }
        let canvas = CanvasPanel(frame: screen.frame, overlay: self)
        canvases[screen.displayID] = canvas
        return canvas
    }

    private func show(_ canvas: CanvasPanel) {
        let wasVisible = canvas.isVisible
        canvas.orderFrontRegardless()
        if !wasVisible { onCanvasShown?(CGWindowID(canvas.windowNumber)) }
    }

    // MARK: - Paths

    /// The shape of a drawing through `points` (in the canvas's coordinates).
    static func path(for tool: Tool, through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        switch tool {
        case .pen, .highlighter:
            // Smoothed through the midpoints between samples, so fast strokes don't look jagged.
            path.move(to: first)
            if points.count == 1 { path.addLine(to: first) }
            for index in points.indices.dropFirst() {
                let previous = points[index - 1], point = points[index]
                path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
            }
            path.addLine(to: last)
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = hypot(last.x - first.x, last.y - first.y)
            let head = min(length * 0.6, 32)
            let spread = CGFloat.pi / 7
            func back(_ distance: CGFloat, turned turn: CGFloat) -> CGPoint {
                CGPoint(x: last.x - distance * cos(angle + turn), y: last.y - distance * sin(angle + turn))
            }
            // The shaft stops inside the head, so its rounded end doesn't poke past the tip.
            path.move(to: first)
            path.addLine(to: back(head * 0.7, turned: 0))
            path.move(to: last)
            path.addLine(to: back(head, turned: spread))
            path.addLine(to: back(head, turned: -spread))
            path.closeSubpath()
        case .box:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            let radius = min(10, rect.width / 2, rect.height / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }
}

// MARK: - A drawing

private final class Stroke {
    let tool: DrawingOverlay.Tool
    let layer = CAShapeLayer()
    weak var canvas: CanvasPanel?
    var points: [CGPoint] = [] {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = DrawingOverlay.path(for: tool, through: points)
            CATransaction.commit()
        }
    }
    /// Bumped whenever a pending fade should be forgotten.
    var fadeGeneration = 0

    init(tool: DrawingOverlay.Tool, color: NSColor, canvas: CanvasPanel) {
        self.tool = tool
        self.canvas = canvas
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.fillColor = nil
        layer.contentsScale = canvas.backingScaleFactor
        switch tool {
        case .pen:
            layer.lineWidth = 5
            layer.strokeColor = color.cgColor
        case .highlighter:
            // See-through, like a marker pen, so what's underneath still reads.
            layer.lineWidth = 26
            layer.strokeColor = color.withAlphaComponent(0.4).cgColor
        case .arrow:
            layer.lineWidth = 6
            layer.strokeColor = color.cgColor
            layer.fillColor = color.cgColor
        case .box:
            layer.lineWidth = 5
            layer.strokeColor = color.cgColor
        }
        if tool != .highlighter {
            // A soft shadow keeps white and yellow visible on light backgrounds.
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    /// Arrows and boxes need some size; a click with the pen or highlighter makes a dot.
    var isMeaningful: Bool {
        guard let first = points.first, let last = points.last else { return false }
        switch tool {
        case .pen, .highlighter: return true
        case .arrow: return hypot(last.x - first.x, last.y - first.y) >= 12
        case .box: return abs(last.x - first.x) >= 8 && abs(last.y - first.y) >= 8
        }
    }
}

// MARK: - The clear window over a screen

private final class CanvasPanel: NSPanel {
    /// Only while drawing, so Esc and ⌘Z reach it then and your typing doesn't afterwards.
    var allowsKey = false
    var hasStrokes = false

    init(frame: NSRect, overlay: DrawingOverlay) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Over other apps' windows and the camera bubble, under the menu bar, so MyLoom's menu still works.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        let view = CanvasView(frame: NSRect(origin: .zero, size: frame.size))
        view.overlay = overlay
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { allowsKey }
}

private final class CanvasView: NSView {
    weak var overlay: DrawingOverlay?
    private var current: Stroke?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { setCursor() }
    override func mouseMoved(with event: NSEvent) { setCursor() }

    private func setCursor() {
        if overlay?.isDrawing == true { NSCursor.crosshair.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let overlay, overlay.isDrawing, let canvas = window as? CanvasPanel else { return }
        let stroke = overlay.begin(overlay.tool, on: canvas)
        stroke.points = [convert(event.locationInWindow, from: nil)]
        current = stroke
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch current.tool {
        case .pen, .highlighter:
            // Skip samples closer than a pixel or so; they add nothing but path length.
            if let last = current.points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
            current.points.append(point)
        case .arrow, .box:
            current.points = [current.points[0], point]
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let current else { return }
        mouseDragged(with: event)
        self.current = nil
        overlay?.finish(current)
    }

    override func keyDown(with event: NSEvent) {
        guard let overlay else { return }
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (53, _): overlay.stop()                     // Esc
        case (_, "z") where command: overlay.undo()
        case (51, _), (117, _): overlay.clear()          // Delete, Forward Delete
        case (_, let key?) where !command && Int(key).map({ (1...DrawingOverlay.Tool.allCases.count).contains($0) }) == true:
            overlay.tool = DrawingOverlay.Tool.allCases[Int(key)! - 1]
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Toolbar

/// Tools, colours, Fade, Undo, Clear and Done, floating near the top of the screen. Drag it by its
/// background to move it. It never becomes key, so clicking it doesn't take Esc away from drawing.
private final class ToolbarPanel: HUDPanel {
    weak var overlay: DrawingOverlay? {
        didSet { build() }
    }
    private var toolButtons: [HUDButton] = []
    private var colorButtons: [SwatchButton] = []
    private var fadeButton: HUDButton?

    private func build() {
        guard let overlay else { return }
        toolButtons = DrawingOverlay.Tool.allCases.enumerated().map { index, tool in
            let button = HUDButton(symbol: tool.symbol, tip: "\(tool.title) (\(index + 1))", target: self, action: #selector(chooseTool(_:)))
            button.tag = index
            return button
        }
        colorButtons = DrawingOverlay.colors.enumerated().map { index, entry in
            let button = SwatchButton(color: entry.color, tip: entry.name, target: self, action: #selector(chooseColor(_:)))
            button.tag = index
            return button
        }
        let fade = HUDButton(symbol: "timer", tip: "Fade drawings after \(Int(DrawingOverlay.fadeDelay)) seconds",
                             target: self, action: #selector(toggleFade))
        fadeButton = fade
        let undo = HUDButton(symbol: "arrow.uturn.backward", tip: "Undo (⌘Z)", target: overlay, action: #selector(DrawingOverlay.undoFromToolbar))
        let clear = HUDButton(symbol: "trash", tip: "Clear all (Delete)", target: overlay, action: #selector(DrawingOverlay.clearFromToolbar))
        let done = HUDButton(title: "Done", tip: "Stop drawing (Esc)", target: overlay, action: #selector(DrawingOverlay.stopFromToolbar))

        setRow(toolButtons + [Self.divider()] + colorButtons + [Self.divider(), fade, undo, clear, Self.divider(), done],
               widerGapsAfter: [toolButtons.last!, colorButtons.last!])
        showChoices()
    }

    /// Shows the current tool, colour and Fade.
    func showChoices() {
        guard let overlay else { return }
        for button in toolButtons { button.isOn = button.tag == DrawingOverlay.Tool.allCases.firstIndex(of: overlay.tool) }
        for button in colorButtons { button.isOn = button.tag == overlay.colorIndex }
        fadeButton?.isOn = overlay.fades
    }

    /// Top middle of `screen`, just under the menu bar.
    func place(on screen: NSScreen) {
        let area = screen.visibleFrame
        setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.maxY - frame.height - 12))
    }

    @objc private func chooseTool(_ sender: NSButton) { overlay?.tool = DrawingOverlay.Tool.allCases[sender.tag] }
    @objc private func chooseColor(_ sender: NSButton) { overlay?.colorIndex = sender.tag }
    @objc private func toggleFade() { overlay?.fades.toggle() }
}

extension DrawingOverlay {
    @objc fileprivate func undoFromToolbar() { undo() }
    @objc fileprivate func clearFromToolbar() { clear() }
    @objc fileprivate func stopFromToolbar() { stop() }
}

// MARK: - Floating bars

/// A small dark bar of buttons floating over everything, like the drawing toolbar and the recording
/// controls. Drag it by its background to move it. It never becomes key, so clicking it doesn't take
/// the keyboard from anything.
class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above the drawing windows, so it can be clicked while drawing.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }

    /// Lays out `views` in a row on the dark background and sizes the bar to fit.
    func setRow(_ views: [NSView], widerGapsAfter wider: [NSView] = []) {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for view in wider { stack.setCustomSpacing(8, after: view) }

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        setContentSize(stack.fittingSize)
    }

    static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 22).isActive = true
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

class HUDButton: NSButton {
    var widthConstraint: NSLayoutConstraint?
    var isOn = false {
        didSet { layer?.backgroundColor = isOn ? NSColor.white.withAlphaComponent(0.24).cgColor : nil }
    }

    convenience init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        setSymbol(symbol, tip: tip)
        imagePosition = .imageOnly
        setup(tip: tip, target: target, action: action, width: 32)
    }

    func setSymbol(_ symbol: String, tip: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        toolTip = tip
        setAccessibilityLabel(tip)
    }

    convenience init(title: String, tip: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        setup(tip: tip, target: target, action: action, width: 54)
    }

    private func setup(tip: String, target: AnyObject, action: Selector, width: CGFloat) {
        isBordered = false
        contentTintColor = .white
        toolTip = tip
        setAccessibilityLabel(tip)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    // The toolbar never becomes key, so the first click has to work.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A colour to pick: a filled circle, ringed when it's the current one.
private final class SwatchButton: HUDButton {
    private var swatch: NSColor = .white

    convenience init(color: NSColor, tip: String, target: AnyObject, action: Selector) {
        self.init(symbol: "circle", tip: tip, target: target, action: action)
        image = nil
        swatch = color
        widthConstraint?.constant = 26
    }

    override var isOn: Bool {
        didSet { layer?.backgroundColor = nil; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let size: CGFloat = 18
        let circle = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        swatch.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.white.withAlphaComponent(isOn ? 1 : 0.35).setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: isOn ? -3 : 0.5, dy: isOn ? -3 : 0.5))
        ring.lineWidth = isOn ? 2 : 1
        ring.stroke()
    }
}
