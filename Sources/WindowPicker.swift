import AppKit

/// An app window as macOS's window list reports it.
struct WindowInfo {
    let id: CGWindowID
    /// In Quartz coordinates: origin top-left of the main display, y down.
    let frame: CGRect
    let appName: String
    let title: String

    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }

    /// The window with this number, if it still exists.
    static func find(_ id: CGWindowID) -> WindowInfo? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first.flatMap(WindowInfo.init)
    }

    /// Ordinary app windows on screen, front to back, leaving out MyLoom's own.
    static func onScreen() -> [WindowInfo] {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return all.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return WindowInfo(entry).flatMap { $0.frame.width >= 80 && $0.frame.height >= 60 ? $0 : nil }
        }
    }

    private init?(_ entry: [String: Any]) {
        guard let number = entry[kCGWindowNumber as String] as? Int,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
        id = CGWindowID(number)
        self.frame = frame
        appName = entry[kCGWindowOwnerName as String] as? String ?? "Window"
        // Titles are only visible to apps with Screen Recording access.
        title = entry[kCGWindowName as String] as? String ?? ""
    }
}

/// Lets you click the window to record, as Loom's window selection does: an overlay on every
/// screen highlights the window under the pointer with its name and video size. Esc cancels.
final class WindowPicker {
    private var windows: [NSWindow] = []
    private var completion: ((WindowInfo?) -> Void)?

    var isOpen: Bool { !windows.isEmpty }

    func begin(completion: @escaping (WindowInfo?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        // Windows don't move while you're choosing, so the list is read once.
        let candidates = WindowInfo.onScreen()
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = WindowPickerView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen,
                                        candidates: candidates, showsHint: screen == NSScreen.screens.first)
            view.onFinish = { [weak self] choice in self?.finish(choice) }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        let start = windows.first { $0.frame.contains(pointer) } ?? windows.first
        start?.makeKeyAndOrderFront(nil)
        windows.forEach { ($0.contentView as? WindowPickerView)?.pointerMoved(to: pointer) }
    }

    private func finish(_ choice: WindowInfo?) {
        guard let completion else { return }
        self.completion = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion(choice)
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class WindowPickerView: NSView {
    var onFinish: ((WindowInfo?) -> Void)?

    private let screen: NSScreen
    private let candidates: [WindowInfo]
    private let showsHint: Bool
    private var hovered: WindowInfo? {
        didSet { if hovered?.id != oldValue?.id { needsDisplay = true } }
    }

    init(frame: NSRect, screen: NSScreen, candidates: [WindowInfo], showsHint: Bool) {
        self.screen = screen
        self.candidates = candidates
        self.showsHint = showsHint
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil   // the pointer is on another screen now; that screen's overlay highlights
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    /// The topmost candidate under `point` (global AppKit coordinates).
    func pointerMoved(to point: NSPoint) {
        hovered = candidates.first { $0.frame.flippedForAppKit.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        pointerMoved(to: NSEvent.mouseLocation)
        if let hovered { onFinish?(hovered) } else { NSSound.beep() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }   // Esc
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Nearly clear rather than clear, so this window receives the clicks.
        NSColor(white: 0, alpha: 0.01).setFill()
        bounds.fill()

        if let hovered {
            let rect = hovered.frame.flippedForAppKit.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            if rect.intersects(bounds) {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                rect.fill()
                let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
                border.lineWidth = 3
                NSColor.controlAccentColor.setStroke()
                border.stroke()
                let pixels = ScreenRecorder.outputSize(points: hovered.frame.size, scale: screen.backingScaleFactor)
                drawPill("\(hovered.label)  ·  \(pixels.width) × \(pixels.height)",
                         at: NSPoint(x: rect.midX, y: rect.midY))
            }
        }
        if showsHint {
            drawPill("Click the window to record  ·  Esc to cancel", at: NSPoint(x: bounds.midX, y: bounds.maxY - 60))
        }
    }

    private func drawPill(_ string: String, at center: NSPoint) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let background = NSRect(origin: origin, size: size).insetBy(dx: -12, dy: -6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: background, xRadius: background.height / 2, yRadius: background.height / 2).fill()
        text.draw(at: origin)
    }
}
