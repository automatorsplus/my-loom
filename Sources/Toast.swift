import AppKit

/// A short notice near the top of the screen, for shortcuts whose effect isn't otherwise visible,
/// such as switching recording mode. It fades after a moment and never takes clicks.
final class Toast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Its window, so recordings can leave it out. It exists from the first time this is asked.
    var windowID: CGWindowID { CGWindowID((panel ?? makePanel()).windowNumber) }

    func show(_ message: String, on screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 36, height: label.frame.height + 20)
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 40)

        let panel = self.panel ?? makePanel()
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = size.height / 2
        label.frame.origin = NSPoint(x: 18, y: 10)
        background.addSubview(label)
        panel.contentView = background
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let hide = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: hide)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel = panel
        return panel
    }
}
