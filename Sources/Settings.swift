import AppKit
import AVFoundation

/// Choices remembered between launches.
enum Settings {
    private static let defaults = UserDefaults.standard
    private static let noMicrophone = "none"

    /// The screen to record. Falls back to the main display (the one with the menu bar).
    static var screen: NSScreen {
        get {
            let saved = CGDirectDisplayID(defaults.integer(forKey: "displayID"))
            return NSScreen.screens.first { $0.displayID == saved } ?? NSScreen.screens[0]
        }
        set { defaults.set(Int(newValue.displayID), forKey: "displayID") }
    }

    static var savedCameraID: String? { defaults.string(forKey: "cameraID") }

    /// The camera chosen in the menu if it's connected. Otherwise macOS's preferred camera, which
    /// becomes an iPhone by itself once Continuity Camera is ready.
    static var camera: AVCaptureDevice? {
        get {
            let cameras = Devices.cameras()
            return cameras.first { $0.uniqueID == savedCameraID }
                ?? AVCaptureDevice.systemPreferredCamera.flatMap { preferred in cameras.first { $0.uniqueID == preferred.uniqueID } }
                ?? AVCaptureDevice.default(for: .video).flatMap { fallback in cameras.first { $0.uniqueID == fallback.uniqueID } }
                ?? cameras.first
        }
        set { defaults.set(newValue?.uniqueID, forKey: "cameraID") }
    }

    /// The microphone to record, or nil for none. Falls back to the system default input.
    static var microphone: AVCaptureDevice? {
        get {
            let saved = defaults.string(forKey: "microphoneID")
            if saved == noMicrophone { return nil }
            let microphones = Devices.microphones()
            return microphones.first { $0.uniqueID == saved }
                ?? AVCaptureDevice.default(for: .audio).flatMap { fallback in microphones.first { $0.uniqueID == fallback.uniqueID } }
                ?? microphones.first
        }
        set { defaults.set(newValue?.uniqueID ?? noMicrophone, forKey: "microphoneID") }
    }

    /// Bubble diameter in points.
    static var bubbleDiameter: CGFloat {
        get {
            let saved = defaults.double(forKey: "bubbleDiameter")
            return saved > 0 ? CGFloat(saved) : 240
        }
        set { defaults.set(Double(newValue), forKey: "bubbleDiameter") }
    }

    /// The camera bubble's shape over a screen recording. A circle unless chosen.
    static var bubbleShape: CameraBubble.Shape {
        get { defaults.string(forKey: "bubbleShape").flatMap(CameraBubble.Shape.init(rawValue:)) ?? .circle }
        set { defaults.set(newValue.rawValue, forKey: "bubbleShape") }
    }

    /// The shape of Camera Only recordings, and of the preview showing them. The camera's own
    /// (landscape) unless chosen; never a circle, since a movie can't be round.
    static var cameraOnlyShape: CameraBubble.Shape {
        get {
            let saved = defaults.string(forKey: "cameraOnlyShape").flatMap(CameraBubble.Shape.init(rawValue:))
            return saved == nil || saved == .circle ? .landscape : saved!
        }
        set { defaults.set(newValue.rawValue, forKey: "cameraOnlyShape") }
    }

    /// The shape the camera takes in `mode`.
    static func cameraShape(for mode: CaptureMode) -> CameraBubble.Shape {
        mode == .cameraOnly ? cameraOnlyShape : bubbleShape
    }

    /// What a recording captures: Loom's four choices.
    enum CaptureMode: String {
        case fullScreen, customSize, window, cameraOnly

        var title: String {
            switch self {
            case .fullScreen: return "Full Screen"
            case .customSize: return "Custom Size"
            case .window: return "Window"
            case .cameraOnly: return "Camera Only"
            }
        }
    }

    static var captureMode: CaptureMode {
        get {
            if let saved = defaults.string(forKey: "captureMode").flatMap(CaptureMode.init(rawValue:)) { return saved }
            return defaults.bool(forKey: "useCustomArea") ? .customSize : .fullScreen   // before modes existed
        }
        set { defaults.set(newValue.rawValue, forKey: "captureMode") }
    }

    /// The window chosen for Window mode. Window numbers last as long as the window does.
    static var windowID: CGWindowID? {
        get { (defaults.object(forKey: "windowID") as? NSNumber).map { CGWindowID($0.uint32Value) } }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "windowID") }
    }

    /// Whether the camera is shown and recorded like a mirror. On unless turned off.
    static var mirrorCamera: Bool {
        get { !defaults.bool(forKey: "unmirrorCamera") }
        set { defaults.set(!newValue, forKey: "unmirrorCamera") }
    }

    /// What's shown behind you in the camera bubble. Off unless chosen.
    static var cameraBackground: CameraBackground {
        get { CameraBackground(storageValue: defaults.string(forKey: "cameraBackground") ?? "") }
        set {
            defaults.set(newValue.storageValue, forKey: "cameraBackground")
            if newValue != .none { defaults.set(newValue.storageValue, forKey: "lastCameraBackground") }
        }
    }

    /// The background the on/off shortcut turns back on: the last one chosen, Blur at first.
    static var lastCameraBackground: CameraBackground {
        let saved = CameraBackground(storageValue: defaults.string(forKey: "lastCameraBackground") ?? "")
        return saved == .none ? .blur : saved
    }

    /// How strongly Blur blurs, from 0 to 1.
    static var blurStrength: Double {
        get { defaults.object(forKey: "blurStrength") as? Double ?? CameraEffects.defaultBlurStrength }
        set { defaults.set(newValue, forKey: "blurStrength") }
    }

    /// The drawing tool, colour and whether drawings fade, as last chosen.
    static var drawingTool: DrawingOverlay.Tool {
        get { defaults.string(forKey: "drawingTool").flatMap(DrawingOverlay.Tool.init(rawValue:)) ?? .pen }
        set { defaults.set(newValue.rawValue, forKey: "drawingTool") }
    }

    static var drawingColor: Int {
        get { min(max(defaults.integer(forKey: "drawingColor"), 0), DrawingOverlay.colors.count - 1) }
        set { defaults.set(newValue, forKey: "drawingColor") }
    }

    /// On unless turned off.
    static var drawingsFade: Bool {
        get { !defaults.bool(forKey: "drawingsStay") }
        set { defaults.set(!newValue, forKey: "drawingsStay") }
    }

    /// The last custom area drawn and the display it belongs to.
    static var customArea: RecordingArea? {
        get { defaults.data(forKey: "customArea").flatMap { try? JSONDecoder().decode(RecordingArea.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "customArea") }
    }

    /// The custom area to record on `screen`, if Custom Size is on and the area was drawn there.
    /// In the screen's own points, origin at its bottom-left.
    static func area(on screen: NSScreen) -> CGRect? {
        guard captureMode == .customSize, let area = customArea, area.displayID == screen.displayID else { return nil }
        let rect = area.rect.intersection(CGRect(origin: .zero, size: screen.frame.size))
        return rect.width >= 32 && rect.height >= 32 ? rect : nil
    }

    /// Whether recordings include what the Mac is playing, mixed with the microphone. Off unless turned on.
    static var recordComputerSound: Bool {
        get { defaults.bool(forKey: "recordComputerSound") }
        set { defaults.set(newValue, forKey: "recordComputerSound") }
    }

    /// Whether the computer's sound is removed from the microphone when both are recorded, so
    /// speakers can be used instead of headphones. On unless turned off.
    static var echoCancellation: Bool {
        get { !defaults.bool(forKey: "noEchoCancellation") }
        set { defaults.set(!newValue, forKey: "noEchoCancellation") }
    }

    /// Whether a 3-2-1 countdown runs before each recording. On unless turned off.
    static var countdownEnabled: Bool {
        get { !defaults.bool(forKey: "skipCountdown") }
        set { defaults.set(!newValue, forKey: "skipCountdown") }
    }

    /// The global shortcut for `action`: its default until changed, nil once cleared.
    static func shortcut(for action: GlobalHotkeys.Action) -> Shortcut? {
        guard let data = defaults.data(forKey: "shortcut.\(action.rawValue)") else { return action.defaultShortcut }
        // Not `try?`: it would flatten a stored "no shortcut" into the same nil as a failed read.
        do {
            return try JSONDecoder().decode(Shortcut?.self, from: data)
        } catch {
            return action.defaultShortcut
        }
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: GlobalHotkeys.Action) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut.\(action.rawValue)")
    }

    static func resetShortcuts() {
        for action in GlobalHotkeys.Action.allCases { defaults.removeObject(forKey: "shortcut.\(action.rawValue)") }
    }

    /// Every action's current shortcut, leaving out cleared ones.
    static var shortcuts: [GlobalHotkeys.Action: Shortcut] {
        Dictionary(uniqueKeysWithValues: GlobalHotkeys.Action.allCases.compactMap { action in
            shortcut(for: action).map { (action, $0) }
        })
    }

    /// Whether the system Screen Recording prompt has been shown once already.
    static var askedForScreenRecording: Bool {
        get { defaults.bool(forKey: "askedForScreenRecording") }
        set { defaults.set(newValue, forKey: "askedForScreenRecording") }
    }
}

struct RecordingArea: Codable {
    var displayID: CGDirectDisplayID
    var x, y, width, height: Double

    init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        (x, y, width, height) = (rect.minX, rect.minY, rect.width, rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum Devices {
    /// Built-in, USB and iPhone (Continuity Camera and Desk View) cameras that are connected now.
    static func cameras() -> [AVCaptureDevice] {
        connected(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices)
    }

    /// Built-in, USB, Bluetooth and iPhone microphones that are connected now.
    static func microphones() -> [AVCaptureDevice] {
        connected(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices)
    }

    private static func connected(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { $0.isConnected && seen.insert($0.uniqueID).inserted }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Converts a rectangle in this screen's own points (origin bottom-left) to global screen coordinates.
    func globalRect(_ local: CGRect) -> CGRect {
        local.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// Converts a rectangle in this screen's own points (origin bottom-left) to ScreenCaptureKit's
    /// display coordinates (origin top-left).
    func captureRect(_ local: CGRect) -> CGRect {
        CGRect(x: local.minX, y: frame.height - local.maxY, width: local.width, height: local.height)
    }
}

extension CGRect {
    /// Converts between Quartz window coordinates (origin top-left of the main display, y down), as
    /// window lists and ScreenCaptureKit use, and AppKit's (origin bottom-left, y up). The same
    /// flip works in both directions.
    var flippedForAppKit: CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: mainHeight - maxY, width: width, height: height)
    }
}

/// Where finished recordings go: ~/Movies/MyLoom 2026-10-16 at 09.41.07.mp4
enum Recordings {
    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }

    static func newFileURL() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("MyLoom \(formatter.string(from: Date())).mp4")
    }
}
