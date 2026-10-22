import AppKit

/// The 3-2-1 shown before recording starts, centred on what will be recorded. The recorder leaves
/// its window out of the picture, and clicking it cancels the recording.
final class Countdown {
    static let seconds = 3

    /// Called when the countdown is clicked.
    var onClick: (() -> Void)?

    private var panel: NSPanel?
    private var view: CountdownView?
    private var ticks: [DispatchWorkItem] = []
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    /// The countdown's window, so the recorder can leave it out.
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    /// Shows 3 at once, then 2 and 1 a second apart, centred on `rect` (global coordinates).
    func show(over rect: NSRect, cancelHint: String) {
        let view = CountdownView(frame: NSRect(origin: .zero, size: CountdownView.size))
        view.hint = cancelHint
        view.onClick = { [weak self] in self?.onClick?() }
        let origin = NSPoint(x: rect.midX - CountdownView.size.width / 2, y: rect.midY - CountdownView.size.height / 2)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: CountdownView.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view
        result = nil

        view.number = Self.seconds
        for step in 1...Self.seconds {
            let tick = DispatchWorkItem { [weak self] in
                if step < Self.seconds {
                    self?.view?.number = Self.seconds - step
                } else {
                    self?.finish(completed: true)
                }
            }
            ticks.append(tick)
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(step), execute: tick)
        }
    }

    /// Stops the countdown early. `waitUntilDone()` then returns false.
    func cancel() {
        finish(completed: false)
    }

    /// Returns true when the countdown reaches zero, false if it was cancelled.
    @MainActor
    func waitUntilDone() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func finish(completed: Bool) {
        guard result == nil else { return }
        result = completed
        ticks.forEach { $0.cancel() }
        ticks.removeAll()
        panel?.orderOut(nil)
        panel = nil
        view = nil
        waiter?.resume(returning: completed)
        waiter = nil
    }
}

/// A dark rounded square with the number in large type and a line about cancelling.
final class CountdownView: NSView {
    static let size = NSSize(width: 220, height: 220)

    var number = 3 {
        didSet {
            needsDisplay = true
            // A quick fade-in on each new number.
            alphaValue = 0.35
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().alphaValue = 1
            }
        }
    }
    var hint = ""
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 40, yRadius: 40).fill()

        let digitFont = NSFont.systemFont(ofSize: 120, weight: .semibold)
        let digit = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont(descriptor: digitFont.fontDescriptor.withDesign(.rounded) ?? digitFont.fontDescriptor, size: 120) ?? digitFont,
            .foregroundColor: NSColor.white,
        ])
        let digitSize = digit.size()
        digit.draw(at: NSPoint(x: bounds.midX - digitSize.width / 2, y: bounds.midY - digitSize.height / 2 + 14))

        let caption = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ])
        let captionSize = caption.size()
        caption.draw(at: NSPoint(x: bounds.midX - captionSize.width / 2, y: 22))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
