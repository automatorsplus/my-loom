import AppKit

/// The small floating bar shown from the moment you start recording until the movie is saved, like
/// Loom's recording controls: the time, Pause / Resume, Draw, Share, Stop and Discard. It's left out of the
/// recording, so it can sit anywhere. Drag it by its background to move it; it stays where you put it.
final class RecordingControls: NSObject {
    enum Action { case stop, pauseResume, draw, share, discard }
    enum Phase { case starting, recording, paused, saving }

    var onAction: ((Action) -> Void)?
    /// Its window, so recordings can leave it out.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }
    var isVisible: Bool { panel.isVisible }

    /// How long Discard waits for its second click.
    private static let confirmTime: TimeInterval = 3

    private let panel = HUDPanel()
    private let dot = NSView()
    private let time = NSTextField(labelWithString: "")
    private var pauseButton: HUDButton!
    private var drawButton: HUDButton!
    private var shareButton: HUDButton!
    private var stopButton: HUDButton!
    private var discardButton: HUDButton!
    private var phase = Phase.starting
    private var elapsed = "0:00"
    private var confirmingDiscard: DispatchWorkItem?
    /// Where it was dragged to on each screen, so the next recording puts it back there.
    private var placed: [CGDirectDisplayID: NSPoint] = [:]
    private var isPlacing = false

    override init() {
        super.init()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        time.textColor = .white
        time.translatesAutoresizingMaskIntoConstraints = false
        time.widthAnchor.constraint(equalToConstant: 66).isActive = true

        pauseButton = HUDButton(symbol: "pause.fill", tip: "Pause", target: self, action: #selector(pause))
        drawButton = HUDButton(symbol: "scribble.variable", tip: "Draw on screen", target: self, action: #selector(draw))
        shareButton = HUDButton(symbol: "link", tip: "Share when saved", target: self, action: #selector(share))
        stopButton = HUDButton(symbol: "stop.fill", tip: "Stop and save", target: self, action: #selector(stop))
        stopButton.contentTintColor = .systemRed
        discardButton = HUDButton(symbol: "trash", tip: "Discard", target: self, action: #selector(discard))
        panel.setRow([dot, time, HUDPanel.divider(), pauseButton, drawButton, shareButton, stopButton, HUDPanel.divider(), discardButton],
                     widerGapsAfter: [dot])
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: panel)
    }

    /// Shows the bar at the bottom middle of `screen`, or where it was last dragged to there.
    func show(on screen: NSScreen) {
        guard !panel.isVisible else { return }
        let area = screen.visibleFrame
        var origin = placed[screen.displayID] ?? NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 24)
        origin.x = min(max(origin.x, area.minX), area.maxX - panel.frame.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - panel.frame.height)
        isPlacing = true
        panel.setFrameOrigin(origin)
        isPlacing = false
        panel.orderFrontRegardless()
    }

    func hide() {
        resetDiscard()
        panel.orderOut(nil)
    }

    /// Shows the recording's phase and time, whether drawing is on and whether it can be, and
    /// whether the recording will be shared when it's saved.
    /// `shortcuts` gives the key names for Stop, Pause and Draw, for the tooltips.
    func update(_ phase: Phase, elapsed: String, drawing: Bool, canDraw: Bool, sharing: Bool, shortcuts: [Action: String]) {
        self.phase = phase
        self.elapsed = elapsed
        func tip(_ text: String, _ action: Action) -> String { shortcuts[action].map { "\(text) (\($0))" } ?? text }
        let colour: NSColor
        switch phase {
        case .starting: colour = .systemGray
        case .recording: colour = .systemRed
        case .paused: colour = .systemOrange
        case .saving: colour = .systemGray
        }
        dot.layer?.backgroundColor = colour.cgColor
        if confirmingDiscard == nil { showTime() }

        let paused = phase == .paused
        pauseButton.setSymbol(paused ? "play.fill" : "pause.fill", tip: tip(paused ? "Resume" : "Pause", .pauseResume))
        pauseButton.isEnabled = phase == .recording || phase == .paused
        drawButton.setSymbol("scribble.variable", tip: canDraw ? tip("Draw on screen", .draw) : "Drawing is for screen recordings")
        drawButton.isOn = drawing
        drawButton.isEnabled = canDraw && phase != .saving
        shareButton.isOn = sharing
        shareButton.setSymbol("link", tip: sharing ? "Will upload and copy a link when you stop (click to cancel)"
                                                   : "Share: upload and copy a link when you stop (it works for 14 days)")
        shareButton.isEnabled = phase != .saving
        stopButton.setSymbol("stop.fill", tip: tip(phase == .starting ? "Cancel" : "Stop and save", .stop))
        stopButton.isEnabled = phase != .saving
        discardButton.isEnabled = phase != .saving
        for button in [pauseButton!, drawButton!, shareButton!, stopButton!, discardButton!] { button.alphaValue = button.isEnabled ? 1 : 0.35 }
    }

    private func showTime() {
        time.textColor = .white
        switch phase {
        case .starting: time.stringValue = "Starting"
        case .recording: time.stringValue = elapsed
        case .paused: time.stringValue = elapsed + " ❙❙"
        case .saving: time.stringValue = "Saving…"
        }
    }

    // MARK: - Buttons

    @objc private func pause() { onAction?(.pauseResume) }
    @objc private func draw() { onAction?(.draw) }
    @objc private func share() { onAction?(.share) }
    @objc private func stop() {
        resetDiscard()
        onAction?(.stop)
    }

    /// Discarding throws the recording away, so it takes a second click within a few seconds.
    @objc private func discard() {
        if confirmingDiscard != nil || phase == .starting {
            resetDiscard()
            onAction?(.discard)
            return
        }
        time.stringValue = "Discard?"
        time.textColor = .systemRed
        discardButton.setSymbol("trash.fill", tip: "Click again to discard this recording")
        discardButton.contentTintColor = .systemRed
        let reset = DispatchWorkItem { [weak self] in self?.resetDiscard() }
        confirmingDiscard = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmTime, execute: reset)
    }

    private func resetDiscard() {
        confirmingDiscard?.cancel()
        confirmingDiscard = nil
        discardButton.setSymbol("trash", tip: "Discard")
        discardButton.contentTintColor = .white
        showTime()
    }

    @objc private func moved() {
        guard !isPlacing, let screen = panel.screen else { return }
        placed[screen.displayID] = panel.frame.origin
    }
}
