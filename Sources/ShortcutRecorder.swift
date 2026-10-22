import AppKit
import Carbon.HIToolbox

/// A small window for choosing one global shortcut, like Loom's `KeyboardShortcutRecorderField`:
/// press the keys, see any clash, then Save. The app releases its own shortcuts while it's open,
/// so pressing a current one records it instead of triggering it.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    enum Outcome {
        case save(Shortcut?)   // nil clears the shortcut
        case cancel
    }

    private var window: NSPanel?
    private var completion: ((Outcome) -> Void)?

    var isOpen: Bool { window != nil }

    func begin(for action: GlobalHotkeys.Action, current: Shortcut?, others: [GlobalHotkeys.Action: Shortcut],
               completion: @escaping (Outcome) -> Void) {
        guard window == nil else { return }
        let view = ShortcutRecorderView(action: action, current: current, others: others)
        view.onFinish = { [weak self] outcome in self?.finish(outcome) }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Shortcut for \(action.name)"
        panel.contentView = view
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.window = panel
        self.completion = completion

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        view.focusField()
    }

    func windowWillClose(_ notification: Notification) {
        finish(.cancel)
    }

    private func finish(_ outcome: Outcome) {
        guard let window, let completion else { return }
        self.window = nil
        self.completion = nil
        window.delegate = nil
        window.close()
        completion(outcome)
    }
}

/// The recorder's contents. Kept separate from the window so its layout can be drawn offscreen.
final class ShortcutRecorderView: NSView {
    var onFinish: ((ShortcutRecorder.Outcome) -> Void)?

    private let action: GlobalHotkeys.Action
    private let others: [GlobalHotkeys.Action: Shortcut]
    private var candidate: Shortcut?
    private let field = ShortcutField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(action: GlobalHotkeys.Action, current: Shortcut?, others: [GlobalHotkeys.Action: Shortcut]) {
        self.action = action
        self.others = others.filter { $0.key != action }
        candidate = current
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 10))

        let heading = NSTextField(labelWithString: "Press the keys you want for \(action.name).")
        heading.font = .boldSystemFont(ofSize: 13)
        let hint = NSTextField(wrappingLabelWithString: hintText)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        field.onRecord = { [weak self] shortcut in
            self?.candidate = shortcut
            self?.evaluate()
        }
        field.onReturn = { [weak self] in self?.save() }
        field.onEscape = { [weak self] in self?.onFinish?(.cancel) }

        message.font = .systemFont(ofSize: 12)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        let useDefault = NSButton(title: "Use Default (\(action.defaultShortcut?.title ?? "none"))", target: self, action: #selector(useDefault))
        useDefault.isHidden = action.defaultShortcut == nil
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The spacer gives way first; no button label is ever cut short (Save becomes "Save Anyway").
        for button in [clear, useDefault, cancel, saveButton] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [clear, useDefault, spacer, cancel, saveButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [heading, hint, field, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: field)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let contentWidth: CGFloat = 420
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: contentWidth),
            field.heightAnchor.constraint(equalToConstant: 48),
            buttons.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        for label in [hint, message] {
            label.preferredMaxLayoutWidth = contentWidth
            label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        evaluate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    /// Shows a shortcut as if it had just been pressed. Used to draw the layout offscreen.
    func show(_ shortcut: Shortcut) {
        candidate = shortcut
        evaluate()
    }

    private var hintText: String {
        var text = "Works \(action.availability.phrase)."
        switch action {
        case .stop: text += " It also cancels the countdown."
        case .pauseResume: text += " Press it again to resume."
        default: break
        }
        switch action.availability {
        case .idle: text += " It can share a key with an action that only works during a recording, such as Stop."
        case .recording: text += " It can share a key with an action that only works when you're not recording, such as Start."
        case .always: break
        }
        return text
    }

    private func evaluate() {
        field.shortcut = candidate
        guard let candidate else {
            show(message: "No shortcut: \(action.name) will only be in the menu.", color: .secondaryLabelColor)
            saveButton.isEnabled = true
            return
        }
        let issues = ShortcutCheck.issues(for: candidate, action: action, others: others)
        saveButton.isEnabled = !issues.contains { $0.level == .error }
        saveButton.title = issues.contains { $0.level == .warning } ? "Save Anyway" : "Save"
        guard !issues.isEmpty else {
            show(message: "\(candidate.title) doesn't clash with macOS or MyLoom. Other apps' shortcuts can't be checked: if one (Loom, say) uses the same keys, one press will reach both.",
                 color: .secondaryLabelColor)
            return
        }
        let text = issues.map(\.message).joined(separator: "\n")
        switch issues[0].level {
        case .error: show(message: text, color: .systemRed)
        case .warning: show(message: text, color: .systemOrange)
        case .note: show(message: text, color: .secondaryLabelColor)
        }
    }

    private func show(message text: String, color: NSColor) {
        message.stringValue = text
        message.textColor = color
    }

    @objc private func clear() {
        candidate = nil
        evaluate()
        focusField()
    }

    @objc private func useDefault() {
        candidate = action.defaultShortcut
        evaluate()
        focusField()
    }

    @objc private func cancel() {
        onFinish?(.cancel)
    }

    @objc private func save() {
        guard saveButton.isEnabled else { return NSSound.beep() }
        onFinish?(.save(candidate))
    }
}

/// The box that captures a key combination. While modifiers are held it shows them, so you can
/// see what you're about to press.
private final class ShortcutField: NSView {
    var shortcut: Shortcut? {
        didSet { needsDisplay = true }
    }
    var onRecord: ((Shortcut) -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    private var heldModifiers: NSEvent.ModifierFlags = []
    private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        heldModifiers = []
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func flagsChanged(with event: NSEvent) {
        heldModifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        needsDisplay = true
    }

    /// Combinations with ⌘ or ⌃ arrive here before anything else can act on them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Plain Return and Esc mean Save and Cancel, as in any dialog.
        if event.modifierFlags.intersection(Self.relevantModifiers).isEmpty {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                onReturn?()
                return
            case kVK_Escape:
                onEscape?()
                return
            default:
                break
            }
        }
        record(event)
    }

    private func record(_ event: NSEvent) {
        heldModifiers = []
        onRecord?(Shortcut(event: event))
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        box.lineWidth = focused ? 3 : 1
        (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.stroke()

        let text: String
        let color: NSColor
        if !heldModifiers.isEmpty {
            text = Shortcut.symbols(for: heldModifiers) + "…"
            color = .labelColor
        } else if let shortcut {
            text = shortcut.title
            color = .labelColor
        } else {
            text = "Press a shortcut"
            color = .placeholderTextColor
        }
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: color,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
