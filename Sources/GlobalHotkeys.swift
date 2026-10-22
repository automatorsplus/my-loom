import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts that work whichever app is in front, registered with Carbon's
/// `RegisterEventHotKey` (what Loom uses too). They need no Accessibility permission.
///
/// Every menu action can have one. The app decides which are live from what each one can do right
/// now (see `Availability`). A shortcut is only held while its action is live, so it's free for
/// other apps the rest of the time, and two actions that are never live together can share a key.
final class GlobalHotkeys {
    enum Availability {
        case idle        // only when not recording
        case recording   // only from the countdown until the recording is saved
        case always

        var phrase: String {
            switch self {
            case .idle: return "when you're not recording"
            case .recording: return "during a recording"
            case .always: return "at any time"
            }
        }
    }

    enum Action: String, CaseIterable {
        case start, stop, pauseResume, toggleDrawing, clearDrawings
        case toggleBubble, toggleMirror, nextShape, toggleBackground
        case fullScreen, customSize, window, cameraOnly
        case toggleComputerSound, toggleEchoCancellation, toggleCountdown, openMoviesFolder, shareLastRecording

        var title: String {
            switch self {
            case .start: return "Start Recording"
            case .stop: return "Stop Recording"
            case .pauseResume: return "Pause / Resume"
            case .toggleDrawing: return "Draw on Screen On / Off"
            case .clearDrawings: return "Clear Drawings"
            case .toggleBubble: return "Show / Hide Camera Bubble"
            case .toggleMirror: return "Mirror Camera On / Off"
            case .nextShape: return "Next Camera Shape"
            case .toggleBackground: return "Background Effect On / Off"
            case .fullScreen: return "Record Full Screen"
            case .customSize: return "Record Custom Size…"
            case .window: return "Record Window…"
            case .cameraOnly: return "Record Camera Only"
            case .toggleComputerSound: return "Computer Sound On / Off"
            case .toggleEchoCancellation: return "Echo Cancellation On / Off"
            case .toggleCountdown: return "Countdown On / Off"
            case .openMoviesFolder: return "Open Movies Folder"
            case .shareLastRecording: return "Share Last Recording"
            }
        }

        /// The title without a trailing "…", for use inside sentences.
        var name: String { title.hasSuffix("…") ? String(title.dropLast()) : title }

        var availability: Availability {
            switch self {
            case .start, .fullScreen, .customSize, .window, .cameraOnly, .toggleComputerSound, .toggleEchoCancellation, .toggleCountdown,
                 .shareLastRecording:
                return .idle
            case .stop, .pauseResume: return .recording
            case .toggleDrawing, .clearDrawings, .toggleBubble, .toggleMirror, .nextShape, .toggleBackground, .openMoviesFolder:
                return .always
            }
        }

        /// Recording controls, drawing and the bubble come with Control-Option-Command plus a letter, which
        /// apps and macOS rarely use. The rest start unset, so MyLoom doesn't take keys unasked.
        var defaultShortcut: Shortcut? {
            let modifiers = controlKey | optionKey | cmdKey
            switch self {
            case .start: return Shortcut(keyCode: kVK_ANSI_R, modifiers: modifiers)
            case .stop: return Shortcut(keyCode: kVK_ANSI_S, modifiers: modifiers)
            case .pauseResume: return Shortcut(keyCode: kVK_ANSI_P, modifiers: modifiers)
            case .toggleBubble: return Shortcut(keyCode: kVK_ANSI_B, modifiers: modifiers)
            case .toggleDrawing: return Shortcut(keyCode: kVK_ANSI_D, modifiers: modifiers)
            default: return nil
            }
        }

        /// Which block of the Shortcuts menu the action is listed in.
        var group: Int {
            switch self {
            case .start, .stop, .pauseResume, .toggleDrawing, .clearDrawings: return 0
            case .toggleBubble, .toggleMirror, .nextShape, .toggleBackground: return 1
            case .fullScreen, .customSize, .window, .cameraOnly: return 2
            case .toggleComputerSound, .toggleEchoCancellation, .toggleCountdown, .openMoviesFolder, .shareLastRecording: return 3
            }
        }

        fileprivate var id: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
    }

    private static let signature: OSType = 0x4D59_4C4D   // "MYLM"

    /// Called on the main thread when a live shortcut is pressed.
    var onPress: ((Action) -> Void)?

    private var registered: [Action: (shortcut: Shortcut, ref: EventHotKeyRef)] = [:]
    private var wanted: [Action: Shortcut] = [:]
    private var handler: EventHandlerRef?

    /// Makes exactly these shortcuts live, registering, re-registering or releasing as needed.
    func activate(_ shortcuts: [Action: Shortcut]) {
        installHandler()
        // Release first, so a key moving from one action to another (Start to Stop) is free again.
        for (action, entry) in registered where shortcuts[action] != entry.shortcut {
            UnregisterEventHotKey(entry.ref)
            registered[action] = nil
        }
        wanted = shortcuts
        for (action, shortcut) in shortcuts where registered[action] == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.id)
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                registered[action] = (shortcut, ref)
            }
        }
    }

    /// Live actions whose shortcut macOS wouldn't register.
    ///
    /// This doesn't catch another app using the same keys: macOS lets every app register a
    /// shortcut, and a press then reaches all of them. That was tested on this Mac with two
    /// processes holding ⌃⌥⌘S. There's no public way to see other apps' shortcuts.
    var unavailable: [Action] {
        Action.allCases.filter { wanted[$0] != nil && registered[$0] == nil }
    }

    func isHeld(_ action: Action) -> Bool { registered[action] != nil }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalHotkeys.signature,
                  let action = Action.allCases.first(where: { $0.id == id.id }) else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue().onPress?(action)
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
