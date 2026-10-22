import AppKit
import Carbon.HIToolbox

/// A key and its modifiers, as used for MyLoom's global shortcuts. The key is a virtual key code,
/// so the shortcut stays on the same physical key whatever the keyboard layout; the modifiers are
/// in Carbon's format, which is what `RegisterEventHotKey` and `CopySymbolicHotKeys` use.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers) & Self.modifierMask
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// For example "⌃⌥⌘S" or "⇧⌘Space", in Apple's modifier order.
    var title: String { Self.symbols(for: modifierFlags) + keyName }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    /// Without ⌘, ⌃ or ⌥ the key couldn't be typed normally anywhere while MyLoom holds it.
    /// Function keys are the exception: they're commonly used alone.
    var hasRequiredModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(Int(keyCode))
    }

    // MARK: - Key names

    var keyName: String {
        if let special = Self.specialKeys[Int(keyCode)] { return special.name }
        return character?.uppercased() ?? "Key \(keyCode)"
    }

    /// What NSMenuItem needs to show this shortcut beside an item, or nil if it has no way to.
    var menuKeyEquivalent: String? {
        if let special = Self.specialKeys[Int(keyCode)] { return special.equivalent }
        return character?.lowercased()
    }

    /// The character this key types on the current (Latin) keyboard layout, ignoring modifiers.
    private var character: String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                        characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static func function(_ scalar: Int) -> String { String(Character(UnicodeScalar(UInt32(scalar))!)) }

    /// Keys that don't type a character, with their names and menu key equivalents.
    private static let specialKeys: [Int: (name: String, equivalent: String)] = {
        var keys: [Int: (name: String, equivalent: String)] = [
            kVK_Space: ("Space", " "),
            kVK_Return: ("↩", "\r"),
            kVK_ANSI_KeypadEnter: ("⌤", function(NSEnterCharacter)),
            kVK_Tab: ("⇥", "\t"),
            kVK_Escape: ("⎋", "\u{1b}"),
            kVK_Delete: ("⌫", "\u{8}"),
            kVK_ForwardDelete: ("⌦", function(NSDeleteFunctionKey)),
            kVK_Home: ("↖", function(NSHomeFunctionKey)),
            kVK_End: ("↘", function(NSEndFunctionKey)),
            kVK_PageUp: ("⇞", function(NSPageUpFunctionKey)),
            kVK_PageDown: ("⇟", function(NSPageDownFunctionKey)),
            kVK_LeftArrow: ("←", function(NSLeftArrowFunctionKey)),
            kVK_RightArrow: ("→", function(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", function(NSUpArrowFunctionKey)),
            kVK_DownArrow: ("↓", function(NSDownArrowFunctionKey)),
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, keyCode) in fKeys.enumerated() {
            keys[keyCode] = ("F\(index + 1)", function(NSF1FunctionKey + index))
        }
        return keys
    }()
}

// MARK: - Clashes

/// Something to say about a shortcut. Errors stop it being saved; warnings and notes are shown alongside.
/// Loom draws the same line between a `systemConflict` (macOS) and a `loomConflict` (its own).
struct ShortcutIssue {
    enum Kind { case needsModifier, myLoomClash, shared, macOSClash, macOSUncheckable }
    enum Level { case error, warning, note }

    let kind: Kind
    let message: String

    var level: Level {
        switch kind {
        case .needsModifier, .myLoomClash: return .error
        case .macOSClash: return .warning
        case .shared, .macOSUncheckable: return .note
        }
    }
}

enum ShortcutCheck {
    /// Everything worth saying about using `shortcut` for `action`, worst first. `others` are
    /// MyLoom's other shortcuts. Other apps' shortcuts can't be checked (see `GlobalHotkeys.unavailable`).
    static func issues(for shortcut: Shortcut, action: GlobalHotkeys.Action,
                       others: [GlobalHotkeys.Action: Shortcut]) -> [ShortcutIssue] {
        var issues: [ShortcutIssue] = []
        if !shortcut.hasRequiredModifier {
            issues.append(ShortcutIssue(kind: .needsModifier, message:
                "Include ⌘, ⌥ or ⌃. Without one, \(shortcut.title) would stop that key working everywhere else."))
        }
        for (other, otherShortcut) in others where other != action && otherShortcut == shortcut {
            if canShare(action, other) {
                issues.append(ShortcutIssue(kind: .shared, message:
                    "Shared with \(other.name), which only works \(other.availability.phrase). This one only works \(action.availability.phrase), so the key does whichever fits."))
            } else {
                issues.append(ShortcutIssue(kind: .myLoomClash, message:
                    "\(shortcut.title) is already MyLoom's \(other.name) shortcut. Change that one first."))
            }
        }
        switch macOSConflict(for: shortcut) {
        case .free:
            break
        case .clash(let name):
            issues.append(ShortcutIssue(kind: .macOSClash, message:
                "\(shortcut.title) is also a macOS shortcut\(name.map { " (\($0))" } ?? ""). macOS may act on it instead of, or as well as, MyLoom. Turn it off in System Settings → Keyboard → Keyboard Shortcuts, or choose another."))
        case .unknown:
            issues.append(ShortcutIssue(kind: .macOSUncheckable, message: "Couldn't check macOS's own shortcuts."))
        }
        let order: [ShortcutIssue.Level] = [.error, .warning, .note]
        return issues.sorted { order.firstIndex(of: $0.level)! < order.firstIndex(of: $1.level)! }
    }

    /// Two actions can share a key when they're never live at the same time: one only when not
    /// recording, the other only during a recording. So Start can share with Stop (one key starts
    /// and stops) or with Pause / Resume (as Loom's "Start/Pause/Resume Recording" does).
    static func canShare(_ first: GlobalHotkeys.Action, _ second: GlobalHotkeys.Action) -> Bool {
        switch (first.availability, second.availability) {
        case (.idle, .recording), (.recording, .idle): return true
        default: return false
        }
    }

    enum MacOSConflict {
        case free
        case clash(name: String?)
        case unknown
    }

    /// Checks macOS's own keyboard shortcuts with `CopySymbolicHotKeys`, as Loom does. It lists
    /// every enabled one, but without names, so well-known defaults are named from a table.
    static func macOSConflict(for shortcut: Shortcut) -> MacOSConflict {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return .unknown }
        let taken = entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode] as? Int).map(UInt32.init) == shortcut.keyCode
                && (entry[kHISymbolicHotKeyModifiers] as? Int).map { UInt32($0) & Shortcut.modifierMask } == shortcut.modifiers
        }
        return taken ? .clash(name: knownMacOSShortcuts[shortcut]) : .free
    }

    /// macOS's default shortcuts most likely to be picked by mistake, by their System Settings names.
    private static let knownMacOSShortcuts: [Shortcut: String] = [
        Shortcut(keyCode: kVK_ANSI_3, modifiers: shiftKey | cmdKey): "Screenshots: Save picture of screen as a file",
        Shortcut(keyCode: kVK_ANSI_3, modifiers: controlKey | shiftKey | cmdKey): "Screenshots: Copy picture of screen to the clipboard",
        Shortcut(keyCode: kVK_ANSI_4, modifiers: shiftKey | cmdKey): "Screenshots: Save picture of selected area as a file",
        Shortcut(keyCode: kVK_ANSI_4, modifiers: controlKey | shiftKey | cmdKey): "Screenshots: Copy picture of selected area to the clipboard",
        Shortcut(keyCode: kVK_ANSI_5, modifiers: shiftKey | cmdKey): "Screenshots: Screenshot and recording options",
        Shortcut(keyCode: kVK_Space, modifiers: cmdKey): "Spotlight: Show Spotlight search",
        Shortcut(keyCode: kVK_Space, modifiers: optionKey | cmdKey): "Spotlight: Show Finder search window",
        Shortcut(keyCode: kVK_Space, modifiers: controlKey): "Input Sources: Select the previous input source",
        Shortcut(keyCode: kVK_Space, modifiers: controlKey | optionKey): "Input Sources: Select next source in Input menu",
        Shortcut(keyCode: kVK_ANSI_D, modifiers: optionKey | cmdKey): "Launchpad & Dock: Turn Dock hiding on/off",
        Shortcut(keyCode: kVK_UpArrow, modifiers: controlKey): "Mission Control",
        Shortcut(keyCode: kVK_DownArrow, modifiers: controlKey): "Mission Control: Application windows",
        Shortcut(keyCode: kVK_LeftArrow, modifiers: controlKey): "Mission Control: Move left a space",
        Shortcut(keyCode: kVK_RightArrow, modifiers: controlKey): "Mission Control: Move right a space",
        Shortcut(keyCode: kVK_Tab, modifiers: cmdKey): "switching between apps",
        Shortcut(keyCode: kVK_Escape, modifiers: optionKey | cmdKey): "Force Quit",
    ]
}
