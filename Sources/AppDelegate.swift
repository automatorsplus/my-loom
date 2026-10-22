import AppKit
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Everything here runs on the main thread, which AppKit requires for windows and menus. Its async
/// methods (showing the camera, starting a recording) stay there too, rather than resuming on a
/// background thread after each `await`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        /// `starting` covers the countdown and the capture warming up.
        case idle, starting, recording, paused, saving
    }

    /// How long the menu takes to fade out. Recording starts or resumes after it when chosen from the
    /// menu with no countdown, so the menu isn't in the movie.
    private static let menuFadeOut = CMTime(value: 3, timescale: 10)

    private var statusItem: NSStatusItem!
    private let recorder = ScreenRecorder()
    private let bubble = CameraBubble()
    private let areaSelector = AreaSelector()
    private let windowPicker = WindowPicker()
    private let areaOutline = AreaOutline()
    private let countdown = Countdown()
    private let hotkeys = GlobalHotkeys()
    private let shortcutRecorder = ShortcutRecorder()
    private let toast = Toast()
    private let drawing = DrawingOverlay()
    private let controls = RecordingControls()
    private let sharing = Sharing()
    /// Whether the recording in progress is shared when it's saved (the control bar's Share button).
    private var shareWhenSaved = false
    /// The last recording saved, for Share Last Recording.
    private var lastRecording: URL? {
        get { UserDefaults.standard.string(forKey: "lastRecording").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "lastRecording") }
    }
    /// The live level meter under Microphone in the menu, and the submenu whose hovered mic it follows.
    private let meter = MicrophoneMeter()
    private var meterView: MicrophoneMeterView?
    private var meterTimer: Timer?
    private weak var microphoneMenu: NSMenu?
    /// AppKit may build the menu before or after saying it opened; the meter starts in whichever comes second.
    private var mainMenuOpen = false
    private var clockTimer: Timer?
    /// Recorded seconds before the current stretch, and the host time the current stretch began
    /// (nil while paused). Together they give the clock in the menu bar, which skips paused time.
    private var recordedBeforePause: Double = 0
    private var stretchStartedAt: CMTime?
    /// Host time when the menu was last opened during a recording. Stopping from the menu ends the
    /// movie here, so it doesn't finish on footage of the menu being used.
    private var menuOpenedAt: CMTime?
    /// Where the window being recorded is now (Quartz coordinates), for its outline.
    private var recordingWindowFrame: CGRect?
    private var startCancelled = false
    private var quitAfterSaving = false
    /// Shown after saving if the microphone changed during the recording.
    private var microphoneNote: String?

    private var state: State = .idle {
        didSet {
            if state == .idle { recordingWindowFrame = nil }
            updateHotkeys()
            refreshStatusItem()
            refreshOutline()
            refreshControls()
        }
    }

    private var isCapturing: Bool { state == .recording || state == .paused }
    private var isBusy: Bool { areaSelector.isOpen || windowPicker.isOpen || shortcutRecorder.isOpen }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        bubble.diameter = Settings.bubbleDiameter
        bubble.mirrored = Settings.mirrorCamera
        bubble.background = Settings.cameraBackground
        bubble.blurStrength = Settings.blurStrength
        drawing.tool = Settings.drawingTool
        drawing.colorIndex = Settings.drawingColor
        drawing.fades = Settings.drawingsFade
        drawing.onSettingsChanged = { [weak self] in
            guard let self else { return }
            Settings.drawingTool = drawing.tool
            Settings.drawingColor = drawing.colorIndex
            Settings.drawingsFade = drawing.fades
        }
        drawing.onCanvasShown = { [weak self] id in self?.drawingWindowShown(id) }
        drawing.onDrawingChanged = { [weak self] in self?.refreshControls() }
        controls.onAction = { [weak self] action in self?.controlPressed(action) }
        sharing.onChange = { [weak self] in self?.refreshControls() }
        bubble.shape = Settings.cameraShape(for: Settings.captureMode)
        bubble.onResize = { Settings.bubbleDiameter = $0 }
        bubble.snapBounds = { [weak self] frame in self?.snapBounds(for: frame) }
        recorder.onInterrupted = { [weak self] error in self?.captureInterrupted(error) }
        recorder.onWindowMoved = { [weak self] from, to in self?.recordedWindowMoved(from: from, to: to) }
        recorder.onMicrophoneChanged = { [weak self] lost, replacement in
            self?.microphoneNote = replacement.map { "\(lost) disconnected during the recording, so MyLoom switched to \($0)." }
                ?? "\(lost) disconnected during the recording and no other microphone was available, so the rest is silent."
        }
        countdown.onClick = { [weak self] in self?.cancelStart() }
        hotkeys.onPress = { [weak self] action in self?.shortcutPressed(action) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(deviceConnected(_:)), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceDisconnected(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        updateHotkeys()
        refreshStatusItem()
        refreshOutline()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch state {
        case .idle:
            return .terminateNow
        case .starting:
            quitAfterSaving = true
            cancelStart()
            return .terminateLater
        case .recording, .paused:
            quitAfterSaving = true
            finishRecording(endingAt: menuOpenedAt)
            return .terminateLater
        case .saving:
            quitAfterSaving = true
            return .terminateLater
        }
    }

    // MARK: - Shortcuts

    /// Holds the shortcuts whose actions can run now (see `GlobalHotkeys.Availability`). None while a
    /// shortcut is being recorded, so pressing a current one records it instead of triggering it.
    private func updateHotkeys() {
        let live: Set<GlobalHotkeys.Availability>
        if shortcutRecorder.isOpen {
            live = []
        } else {
            switch state {
            case .idle: live = [.idle, .always]
            case .starting, .recording, .paused: live = [.recording, .always]
            case .saving: live = [.always]
            }
        }
        hotkeys.activate(Settings.shortcuts.filter { live.contains($0.key.availability) })
    }

    /// Does what the menu item would. Changes that wouldn't otherwise show are confirmed with a toast.
    private func shortcutPressed(_ action: GlobalHotkeys.Action) {
        switch action {
        case .start: startRecording()
        case .stop: state == .starting ? cancelStart() : stop(endingAt: nil)
        case .pauseResume: togglePause(fromMenu: false)
        case .toggleBubble: toggleBubble()
        case .toggleMirror:
            toggleMirror()
            toast.show(Settings.mirrorCamera ? "Camera mirrored" : "Camera not mirrored")
        case .toggleBackground:
            toggleBackground()
            let background = Settings.cameraBackground
            toast.show(background == .none ? "Background effect off" : "Background: \(background.title)")
        case .nextShape:
            toast.show(nextShape() ? "Camera shape: \(bubble.shape.title)" : "The shape can't change during a Camera Only recording")
        case .fullScreen:
            chooseFullScreen()
            toast.show("Recording: Full Screen")
        case .customSize: chooseCustomSize()
        case .window: chooseWindow()
        case .cameraOnly:
            chooseCameraOnly()
            toast.show("Recording: Camera Only")
        case .toggleComputerSound:
            toggleComputerSound()
            toast.show(Settings.recordComputerSound ? "Computer sound on" : "Computer sound off")
        case .toggleEchoCancellation:
            toggleEchoCancellation()
            toast.show(Settings.echoCancellation ? "Echo cancellation on" : "Echo cancellation off")
        case .toggleCountdown:
            toggleCountdown()
            toast.show(Settings.countdownEnabled ? "Countdown on" : "Countdown off")
        case .openMoviesFolder: openMoviesFolder()
        case .shareLastRecording: shareLastRecording()
        case .toggleDrawing:
            if canDraw { drawing.toggle() } else { toast.show("Drawing is for screen recordings, not Camera Only") }
        case .clearDrawings:
            if drawing.hasDrawings { toast.show("Drawings cleared") }
            drawing.clear()
        }
    }

    // MARK: - Recording

    /// Starts capture straight away while the countdown runs, so it's warmed up when the countdown
    /// reaches zero; the movie itself begins at zero.
    @objc private func startRecording() {
        guard state == .idle, !isBusy else { return }
        shareWhenSaved = false   // each recording starts unshared; the control bar's Share button turns it on
        let mode = Settings.captureMode
        let computerSound = Settings.recordComputerSound
        // The computer's sound comes through ScreenCaptureKit too, so Camera Only needs the same access then.
        if mode != .cameraOnly || computerSound, !hasScreenRecordingAccess() { return }
        var window: WindowInfo?
        if mode == .window {
            guard let chosen = Settings.windowID.flatMap(WindowInfo.find) else {
                showAlert("Choose a window", "The window chosen for recording isn't open any more. Choose one with Record Window….")
                return
            }
            window = chosen
        }
        let screen = Settings.screen
        let area = Settings.area(on: screen)
        let microphone = Settings.microphone
        let useCountdown = Settings.countdownEnabled
        startCancelled = false
        state = .starting

        Task { @MainActor in
            if microphone != nil, !(await Self.requestAccess(for: .audio)) {
                state = .idle
                showPermissionAlert("Allow microphone access",
                                    "Turn on MyLoom in System Settings → Privacy & Security → Microphone, or choose None from the Microphone menu.",
                                    pane: "Privacy_Microphone")
                return
            }
            // Camera Only records what the preview shows, so the camera has to be on first.
            if mode == .cameraOnly, !(await showBubble()) {
                state = .idle
                return
            }
            let bounds = recordingBounds(on: screen)
            if bubble.isVisible, mode != .cameraOnly { bubble.keep(inside: bounds) }
            let lead = useCountdown ? CMTime(value: CMTimeValue(Countdown.seconds), timescale: 1) : Self.menuFadeOut
            let startAt = CMClockGetTime(CMClockGetHostTimeClock()) + lead
            if useCountdown {
                let stopKey = Settings.shortcut(for: .stop)
                countdown.show(over: bounds, cancelHint: stopKey.map { "Click or press \($0.title) to cancel" } ?? "Click to cancel")
            }

            let source: CaptureSource
            switch mode {
            case .fullScreen, .customSize:
                source = .display(screen.displayID, area: area.map(screen.captureRect))
            case .window:
                // A window recording only draws the windows it's told about: add the bubble and drawings.
                let extras = (bubble.isVisible ? bubble.windowID.map { [$0] } ?? [] : []) + drawing.visibleCanvasIDs
                source = .window(window!.id, alsoShowing: extras)
                recordingWindowFrame = window!.frame
            case .cameraOnly:
                source = .camera(bubble)
            }

            do {
                microphoneNote = nil
                try await recorder.start(source, microphone: microphone, computerSound: computerSound,
                                         cancelEcho: Settings.echoCancellation,
                                         excludingWindows: [countdown.windowID, controls.windowID, drawing.toolbarWindowID,
                                                            toast.windowID, sharing.panel.windowID].compactMap { $0 },
                                         startingAt: startAt, to: Recordings.newFileURL())
            } catch {
                countdown.cancel()
                state = .idle
                if quitAfterSaving { NSApp.reply(toApplicationShouldTerminate: true) }
                if !startCancelled { showAlert("Couldn't start recording", error.localizedDescription) }
                return
            }

            let reachedZero = useCountdown ? await countdown.waitUntilDone() : true
            guard reachedZero, !startCancelled else {
                await recorder.cancel()
                state = .idle
                if quitAfterSaving { NSApp.reply(toApplicationShouldTerminate: true) }
                return
            }
            recordedBeforePause = 0
            stretchStartedAt = startAt
            menuOpenedAt = nil
            state = .recording
        }
    }

    /// Cancels a recording that hasn't started yet (during the countdown). Nothing is saved.
    @objc private func cancelStart() {
        guard state == .starting else { return }
        startCancelled = true
        countdown.cancel()
    }

    /// Throws the recording away, or cancels it during the countdown. Nothing is saved.
    private func discardRecording() {
        switch state {
        case .starting:
            cancelStart()
        case .recording, .paused:
            state = .saving
            Task { @MainActor in
                await recorder.cancel()
                microphoneNote = nil
                state = .idle
                toast.show("Recording discarded")
                if quitAfterSaving { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        case .idle, .saving:
            break
        }
    }

    // MARK: - Sharing

    @objc private func shareLastRecording() {
        guard state == .idle, let url = lastRecording, FileManager.default.fileExists(atPath: url.path) else {
            toast.show("No recording to share yet")
            return
        }
        sharing.share(url)
    }

    @objc private func showShareProgress() { sharing.panel.showCurrent() }
    @objc private func showSharingSetup() { sharing.setup.show() }

    private func share(for item: NSMenuItem) -> Sharing.Share? {
        guard let path = item.representedObject as? String else { return nil }
        return sharing.activeShares.first { $0.path == path }
    }

    @objc private func copyShareLink(_ item: NSMenuItem) {
        guard let share = share(for: item) else { return }
        sharing.copyToClipboard(share)
        toast.show("Link copied")
    }

    @objc private func openShareLink(_ item: NSMenuItem) {
        if let share = share(for: item) { NSWorkspace.shared.open(share.link) }
    }

    @objc private func deleteShare(_ item: NSMenuItem) {
        guard let share = share(for: item) else { return }
        Task { @MainActor in
            do {
                try await sharing.delete(share)
                toast.show("Deleted: the link no longer works")
            } catch {
                showAlert("Couldn't delete the shared video", error.localizedDescription)
            }
        }
    }

    // MARK: - Recording controls

    private func controlPressed(_ action: RecordingControls.Action) {
        switch action {
        case .stop: state == .starting ? cancelStart() : stop(endingAt: nil)
        case .pauseResume: togglePause(fromMenu: false)
        case .draw: toggleDrawing()
        case .share:
            guard sharing.isReady else {
                toast.show("Set up sharing first: Sharing Setup… in MyLoom's menu")
                return
            }
            shareWhenSaved.toggle()
            toast.show(shareWhenSaved ? "This recording will be uploaded and its link copied when you stop" : "This recording won't be shared")
            refreshControls()
        case .discard: discardRecording()
        }
    }

    /// Shows the floating controls from Start Recording until the movie is saved, on the screen
    /// being recorded.
    private func refreshControls() {
        let phase: RecordingControls.Phase
        switch state {
        case .idle:
            controls.hide()
            return
        case .starting: phase = .starting
        case .recording: phase = .recording
        case .paused: phase = .paused
        case .saving: phase = .saving
        }
        let shortcuts = Settings.shortcuts
        controls.update(phase, elapsed: elapsedText, drawing: drawing.isDrawing, canDraw: canDraw, sharing: shareWhenSaved, shortcuts: [
            .stop: shortcuts[.stop]?.title, .pauseResume: shortcuts[.pauseResume]?.title, .draw: shortcuts[.toggleDrawing]?.title,
        ].compactMapValues { $0 })
        if !controls.isVisible {
            let bounds = recordingBounds(on: Settings.screen)
            let middle = NSPoint(x: bounds.midX, y: bounds.midY)
            controls.show(on: NSScreen.screens.first { $0.frame.contains(middle) } ?? Settings.screen)
        }
    }

    @objc private func stopFromMenu() {
        if state == .starting { return cancelStart() }
        stop(endingAt: menuOpenedAt)
    }

    private func stop(endingAt end: CMTime?) {
        guard isCapturing else { return }
        finishRecording(endingAt: end)
    }

    @objc private func togglePauseFromMenu() {
        togglePause(fromMenu: true)
    }

    /// Pausing takes effect now: frames already written can't be taken back, so a pause chosen from
    /// the menu keeps a moment of the menu. Resuming from the menu waits for it to fade out.
    private func togglePause(fromMenu: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        switch state {
        case .recording:
            recorder.pause(at: now)
            recordedBeforePause += max(0, (now - (stretchStartedAt ?? now)).seconds)
            stretchStartedAt = nil
            state = .paused
        case .paused:
            let resumeAt = fromMenu ? now + Self.menuFadeOut : now
            recorder.resume(at: resumeAt)
            stretchStartedAt = resumeAt
            state = .recording
        default:
            break
        }
    }

    private func finishRecording(endingAt end: CMTime?, after interruption: Error? = nil) {
        state = .saving
        Task { @MainActor in
            do {
                let url = try await recorder.stop(endingAt: end)
                lastRecording = url
                if !quitAfterSaving { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if shareWhenSaved, !quitAfterSaving { sharing.share(url) }
                if let interruption {
                    showAlert("Recording stopped", "\(interruption.localizedDescription)\n\nEverything up to that point was saved.")
                }
                if let microphoneNote {
                    showAlert("Microphone changed during recording", microphoneNote)
                } else if let problem = recorder.microphoneProblem {
                    showAlert("No sound from \(problem.name)",
                              "\(problem.name) sent \(problem.sentNothing ? "nothing" : "only silence") during the recording, so the movie has no voice. "
                              + "If it's a USB mic, check it isn't muted (many have a mute button or light) and its gain isn't turned right down. "
                              + "Before recording, point at it under Microphone to watch its level.")
                }
            } catch {
                showAlert("Couldn't save the recording", error.localizedDescription)
            }
            microphoneNote = nil
            state = .idle
            if quitAfterSaving { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    private func captureInterrupted(_ error: Error) {
        if state == .starting { return cancelStart() }
        guard isCapturing else { return }
        // Stopping from the macOS screen-sharing menu is a normal way to stop, not a failure.
        let stoppedByUser = (error as? SCStreamError)?.code == .userStopped
        finishRecording(endingAt: nil, after: stoppedByUser ? nil : error)
    }

    private func hasScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !Settings.askedForScreenRecording {
            // The first request shows the system prompt, which explains itself.
            Settings.askedForScreenRecording = true
            CGRequestScreenCaptureAccess()
            return false
        }
        showPermissionAlert("Allow screen recording",
                            "Turn on MyLoom in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen MyLoom.",
                            pane: "Privacy_ScreenCapture")
        return false
    }

    // MARK: - What to record

    private func setMode(_ mode: Settings.CaptureMode) {
        Settings.captureMode = mode
        if mode == .cameraOnly { drawing.stop() }
        // Camera Only has its own shape, never round, since the preview shows exactly what's recorded.
        bubble.shape = Settings.cameraShape(for: mode)
        refreshOutline()
    }

    @objc private func chooseFullScreen() {
        guard state == .idle, !isBusy else { return }
        setMode(.fullScreen)
    }

    @objc private func chooseCustomSize() {
        guard state == .idle, !isBusy else { return }
        let screen = Settings.screen
        let previous = Settings.customArea.flatMap { $0.displayID == screen.displayID ? $0.rect : nil }
        areaOutline.hide()
        areaSelector.begin(on: screen, initial: previous) { [weak self] rect in
            guard let self else { return }
            if let rect {
                Settings.customArea = RecordingArea(displayID: screen.displayID, rect: rect)
                self.setMode(.customSize)
                self.bubble.keep(inside: screen.globalRect(rect))
            }
            self.refreshOutline()
        }
    }

    @objc private func chooseWindow() {
        guard state == .idle, !isBusy else { return }
        windowPicker.begin { [weak self] choice in
            guard let self, let choice else { return }
            Settings.windowID = choice.id
            self.setMode(.window)
            self.bubble.keep(inside: choice.frame.flippedForAppKit)
        }
    }

    @objc private func chooseCameraOnly() {
        guard state == .idle, !isBusy else { return }
        setMode(.cameraOnly)
        if !bubble.isVisible { Task { @MainActor in _ = await showBubble() } }
    }

    /// What will be recorded, in global AppKit coordinates. Camera Only records no screen, so the
    /// countdown sits in the middle of the screen, clear of the camera preview.
    private func recordingBounds(on screen: NSScreen) -> NSRect {
        switch Settings.captureMode {
        case .window:
            if let window = Settings.windowID.flatMap(WindowInfo.find) { return window.frame.flippedForAppKit }
            return screen.visibleFrame
        case .cameraOnly, .fullScreen, .customSize:
            return Settings.area(on: screen).map(screen.globalRect) ?? screen.visibleFrame
        }
    }

    /// The bubble snaps to the corners of the area or window being recorded when dropped inside it,
    /// otherwise to its screen's.
    private func snapBounds(for frame: NSRect) -> NSRect? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = Settings.screen
        if Settings.captureMode == .window,
           let window = (recordingWindowFrame ?? Settings.windowID.flatMap(WindowInfo.find)?.frame)?.flippedForAppKit,
           window.contains(center) {
            return window
        }
        if let area = Settings.area(on: screen).map(screen.globalRect), area.contains(center) { return area }
        return NSScreen.screens.first { $0.frame.contains(center) }?.visibleFrame
    }

    /// A dashed frame marks a custom area; during a recording it turns red, and in Window mode a
    /// red frame follows the window being recorded.
    private func refreshOutline() {
        let recording = state == .starting || isCapturing
        if !areaSelector.isOpen, recording, Settings.captureMode == .window, let frame = recordingWindowFrame {
            return areaOutline.show(around: frame.flippedForAppKit, recording: true)
        }
        let screen = Settings.screen
        guard !areaSelector.isOpen, let area = Settings.area(on: screen) else { return areaOutline.hide() }
        areaOutline.show(around: screen.globalRect(area), recording: recording)
    }

    /// The bubble moves with the window it sits on. If the window is resized, it's kept inside.
    private func recordedWindowMoved(from old: CGRect, to new: CGRect) {
        recordingWindowFrame = new
        let oldFrame = old.flippedForAppKit, newFrame = new.flippedForAppKit
        if bubble.isVisible, let bubbleFrame = bubble.frame,
           oldFrame.contains(NSPoint(x: bubbleFrame.midX, y: bubbleFrame.midY)) {
            if oldFrame.size == newFrame.size {
                bubble.move(by: CGSize(width: newFrame.minX - oldFrame.minX, height: newFrame.minY - oldFrame.minY))
            } else {
                bubble.keep(inside: newFrame)
            }
        }
        refreshOutline()
    }

    @objc private func screensChanged() {
        refreshOutline()
        drawing.screensChanged()
    }

    // MARK: - Drawing

    /// Drawings are on the screen, so there's nothing to draw on in Camera Only.
    private var canDraw: Bool { Settings.captureMode != .cameraOnly }

    @objc private func toggleDrawing() {
        guard canDraw else { return }
        drawing.toggle()
    }

    @objc private func clearDrawings() {
        drawing.clear()
    }

    /// A window recording only draws the windows it was told about, so add a drawing window that
    /// has just appeared.
    private func drawingWindowShown(_ id: CGWindowID) {
        guard Settings.captureMode == .window, state == .starting || isCapturing else { return }
        Task { await recorder.alsoShow(id) }
    }

    // MARK: - Camera

    @objc private func toggleBubble() {
        if bubble.isVisible {
            bubble.hide()
            return
        }
        Task { @MainActor in
            guard await showBubble() else { return }
            // A window recording only draws the windows it was told about, so add the bubble.
            if Settings.captureMode == .window, state == .starting || isCapturing, let id = bubble.windowID {
                await recorder.alsoShow(id)
            }
        }
    }

    /// Shows the camera, asking for access first if needed. False if it couldn't be shown.
    private func showBubble() async -> Bool {
        if bubble.isVisible { return true }
        guard let camera = Settings.camera else {
            showAlert("No camera found", "Connect a camera, or bring your iPhone close and lock it to use it as a camera.")
            return false
        }
        guard await Self.requestAccess(for: .video) else {
            showPermissionAlert("Allow camera access",
                                "Turn on MyLoom in System Settings → Privacy & Security → Camera.",
                                pane: "Privacy_Camera")
            return false
        }
        do {
            try bubble.show(camera: camera, home: recordingBounds(on: Settings.screen))
            return true
        } catch {
            showAlert("Couldn't show the camera", error.localizedDescription)
            return false
        }
    }

    @objc private func chooseCamera(_ item: NSMenuItem) {
        guard let camera = item.representedObject as? AVCaptureDevice else { return }
        Settings.camera = camera
        guard bubble.isVisible else { return }
        do {
            try bubble.use(camera)
        } catch {
            showAlert("Couldn't switch camera", error.localizedDescription)
        }
    }

    @objc private func toggleMirror() {
        Settings.mirrorCamera.toggle()
        bubble.mirrored = Settings.mirrorCamera
    }

    // MARK: - Shape

    /// The shapes the camera can take now: any over a screen recording, but not round for Camera Only.
    private var availableShapes: [CameraBubble.Shape] {
        CameraBubble.Shape.allCases.filter { Settings.captureMode != .cameraOnly || $0 != .circle }
    }

    /// A Camera Only movie keeps the shape it started with, so then it can only change before recording.
    private var canChangeShape: Bool { Settings.captureMode != .cameraOnly || state == .idle }

    private func setShape(_ shape: CameraBubble.Shape) {
        guard canChangeShape, availableShapes.contains(shape) else { return }
        if Settings.captureMode == .cameraOnly { Settings.cameraOnlyShape = shape } else { Settings.bubbleShape = shape }
        bubble.shape = shape
    }

    @objc private func chooseShape(_ item: NSMenuItem) {
        guard let shape = (item.representedObject as? String).flatMap(CameraBubble.Shape.init(rawValue:)) else { return }
        setShape(shape)
    }

    /// Moves on to the next shape. False if the shape can't change now.
    @discardableResult
    @objc private func nextShape() -> Bool {
        guard canChangeShape else { return false }
        let shapes = availableShapes
        setShape(shapes[((shapes.firstIndex(of: bubble.shape) ?? -1) + 1) % shapes.count])
        return true
    }

    // MARK: - Background

    private func setBackground(_ background: CameraBackground) {
        Settings.cameraBackground = background
        bubble.background = background
    }

    @objc private func toggleBackground() {
        setBackground(Settings.cameraBackground == .none ? Settings.lastCameraBackground : .none)
    }

    @objc private func chooseBackground(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String else { return }
        setBackground(CameraBackground(storageValue: value))
    }

    /// Opens the Colors window; the background follows it as you pick.
    @objc private func chooseBackgroundColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        if case .color(let red, let green, let blue) = Settings.cameraBackground {
            panel.color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        panel.setTarget(self)
        panel.setAction(#selector(backgroundColorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        backgroundColorChanged(panel)
    }

    @objc private func backgroundColorChanged(_ panel: NSColorPanel) {
        guard let color = panel.color.usingColorSpace(.sRGB) else { return }
        setBackground(.color(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent)))
    }

    @objc private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Background Picture"
        panel.allowedContentTypes = [.image]
        if case .image(let url) = Settings.cameraBackground { panel.directoryURL = url.deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CIImage(contentsOf: url) != nil else {
            showAlert("Couldn't open that picture", "\(url.lastPathComponent) isn't a picture MyLoom can read. Try a JPEG, PNG or HEIC.")
            return
        }
        setBackground(.image(url))
    }

    @objc private func chooseBubbleSize(_ item: NSMenuItem) {
        let diameter = CGFloat(item.tag)
        Settings.bubbleDiameter = diameter
        bubble.diameter = diameter
    }

    /// When the chosen camera comes back (an iPhone picked up and put down again, a USB camera
    /// replugged), the bubble switches back to it.
    @objc private func deviceConnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else { return }
        DispatchQueue.main.async { [self] in
            let wanted = Settings.savedCameraID ?? AVCaptureDevice.systemPreferredCamera?.uniqueID
            guard device.hasMediaType(.video), bubble.isVisible, device.uniqueID == wanted,
                  bubble.cameraID != device.uniqueID else { return }
            try? bubble.use(device)
        }
    }

    /// When the bubble's camera goes away, it falls back to another camera, or hides if none is left.
    @objc private func deviceDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else { return }
        DispatchQueue.main.async { [self] in
            guard device.hasMediaType(.video), bubble.isVisible, bubble.cameraID == device.uniqueID else { return }
            if let fallback = Settings.camera, fallback.uniqueID != device.uniqueID, (try? bubble.use(fallback)) != nil { return }
            bubble.hide()
        }
    }

    // MARK: - Screen, microphone and the rest

    @objc private func chooseScreen(_ item: NSMenuItem) {
        guard let screen = item.representedObject as? NSScreen else { return }
        Settings.screen = screen
        if Settings.captureMode != .cameraOnly { bubble.keep(inside: recordingBounds(on: screen)) }
        refreshOutline()
    }

    @objc private func chooseMicrophone(_ item: NSMenuItem) {
        Settings.microphone = item.representedObject as? AVCaptureDevice
    }

    @objc private func toggleCountdown() {
        guard state == .idle else { return }
        Settings.countdownEnabled.toggle()
    }

    @objc private func toggleComputerSound() {
        guard state == .idle else { return }
        Settings.recordComputerSound.toggle()
    }

    @objc private func toggleEchoCancellation() {
        guard state == .idle else { return }
        Settings.echoCancellation.toggle()
    }

    @objc private func openMoviesFolder() {
        NSWorkspace.shared.open(Recordings.folder)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        mainMenuOpen = true
        if isCapturing { menuOpenedAt = CMClockGetTime(CMClockGetHostTimeClock()) }
        if state == .idle { showMeter(for: Settings.microphone) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu {
            mainMenuOpen = false
            stopMeter()
        } else if menu === microphoneMenu, state == .idle {
            showMeter(for: Settings.microphone)   // back to the chosen mic
        }
    }

    /// Hovering over a microphone in the submenu points the meter at it, so each one can be tried
    /// before choosing.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === microphoneMenu, state == .idle, let item else { return }
        if let device = item.representedObject as? AVCaptureDevice {
            showMeter(for: device)
        } else if item.action == #selector(chooseMicrophone(_:)) {
            showMeter(for: nil)
        }
    }

    // MARK: - Microphone level meter

    /// Points the meter at `device` (nil for no microphone), or explains what's needed first.
    private func showMeter(for device: AVCaptureDevice?) {
        guard let meterView else { return }
        meterView.onClick = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            guard let device else {
                meter.stop()
                meterView.content = .message("No microphone: recordings will have no sound", color: .secondaryLabelColor)
                return
            }
            meter.listen(to: device)
            if meterTimer == nil {
                // Common modes keep it moving while the menu is open.
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateMeter() }
                }
                RunLoop.main.add(timer, forMode: .common)
                meterTimer = timer
            }
            updateMeter()
        case .notDetermined:
            meter.stop()
            meterView.content = .message("Click to test your microphone", color: .controlAccentColor)
            meterView.onClick = {
                Task { @MainActor in _ = await AVCaptureDevice.requestAccess(for: .audio) }
            }
        default:
            meter.stop()
            meterView.content = .message("Microphone access is off. Click to open Settings.", color: .systemOrange)
            meterView.onClick = {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func updateMeter() {
        guard let meterView, let device = meter.device else { return }
        meterView.content = .live(name: device.localizedName, reading: meter.reading())
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        meter.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The Microphone submenu has this delegate too (for its live meter); it's built with the main menu.
        guard menu === statusItem.menu else { return }
        menu.removeAllItems()
        let idle = state == .idle && !isBusy
        let shortcuts = Settings.shortcuts

        switch state {
        case .idle:
            menu.addItem(shortcutItem("Start Recording", idle ? #selector(startRecording) : nil, shortcuts[.start]))
        case .starting:
            menu.addItem(shortcutItem("Cancel Recording", #selector(cancelStart), shortcuts[.stop]))
        case .recording, .paused:
            menu.addItem(shortcutItem("Stop Recording (\(elapsedText))", #selector(stopFromMenu), shortcuts[.stop]))
            menu.addItem(shortcutItem(state == .paused ? "Resume Recording" : "Pause Recording",
                                      #selector(togglePauseFromMenu), shortcuts[.pauseResume]))
        case .saving:
            menu.addItem(item("Saving…", nil))
        }
        let draw = shortcutItem("Draw on Screen", canDraw ? #selector(toggleDrawing) : nil, shortcuts[.toggleDrawing])
        draw.state = drawing.isDrawing ? .on : .off
        menu.addItem(draw)
        if drawing.hasDrawings {
            menu.addItem(shortcutItem("Clear Drawings", #selector(clearDrawings), shortcuts[.clearDrawings]))
        }
        for action in hotkeys.unavailable {
            menu.addItem(item("⚠︎ macOS wouldn't register \(shortcuts[action]?.title ?? "") for \(action.title)", nil))
        }
        menu.addItem(.separator())

        // What to record: Loom's four modes
        let screen = Settings.screen
        menu.addItem(submenu("Screen", enabled: idle, NSScreen.screens.map { candidate in
            let size = candidate.frame.size
            let entry = item("\(candidate.localizedName) (\(Int(size.width))×\(Int(size.height)))", #selector(chooseScreen(_:)))
            entry.representedObject = candidate
            entry.state = candidate == screen ? .on : .off
            return entry
        }))
        let mode = Settings.captureMode
        let area = Settings.area(on: screen)
        let effectiveMode: Settings.CaptureMode = mode == .customSize && area == nil ? .fullScreen : mode

        let fullScreen = shortcutItem("Full Screen", idle ? #selector(chooseFullScreen) : nil, shortcuts[.fullScreen])
        fullScreen.state = effectiveMode == .fullScreen ? .on : .off
        menu.addItem(fullScreen)

        var customTitle = "Custom Size…"
        if let area {
            let pixels = ScreenRecorder.outputSize(points: area.size, scale: screen.backingScaleFactor)
            customTitle = "Custom Size (\(pixels.width) × \(pixels.height))…"
        }
        let custom = shortcutItem(customTitle, idle ? #selector(chooseCustomSize) : nil, shortcuts[.customSize])
        custom.state = effectiveMode == .customSize ? .on : .off
        menu.addItem(custom)

        var windowTitle = "Window…"
        if mode == .window {
            if let window = Settings.windowID.flatMap(WindowInfo.find) {
                let label = window.label.count > 40 ? String(window.label.prefix(39)) + "…" : window.label
                windowTitle = "Window: \(label)…"
            } else {
                windowTitle = "Window… (the chosen one was closed)"
            }
        }
        let windowItem = shortcutItem(windowTitle, idle ? #selector(chooseWindow) : nil, shortcuts[.window])
        windowItem.state = effectiveMode == .window ? .on : .off
        menu.addItem(windowItem)

        let cameraOnly = shortcutItem("Camera Only", idle ? #selector(chooseCameraOnly) : nil, shortcuts[.cameraOnly])
        cameraOnly.state = effectiveMode == .cameraOnly ? .on : .off
        menu.addItem(cameraOnly)

        // Camera
        menu.addItem(.separator())
        let bubbleItem = shortcutItem(mode == .cameraOnly ? "Show Camera Preview" : "Show Camera Bubble",
                                      #selector(toggleBubble), shortcuts[.toggleBubble], fallbackKey: "b")
        bubbleItem.state = bubble.isVisible ? .on : .off
        menu.addItem(bubbleItem)

        let cameras = Devices.cameras()
        let selectedCamera = bubble.isVisible ? bubble.cameraID : Settings.camera?.uniqueID
        var cameraItems = cameras.map { camera in
            let entry = item(camera.localizedName, #selector(chooseCamera(_:)))
            entry.representedObject = camera
            entry.state = camera.uniqueID == selectedCamera ? .on : .off
            return entry
        }
        if !cameras.contains(where: { $0.deviceType == .continuityCamera }) {
            cameraItems += [.separator(), item("Your iPhone appears here when it's nearby, locked and still", nil)]
        }
        let mirror = shortcutItem("Mirror Camera", #selector(toggleMirror), shortcuts[.toggleMirror])
        mirror.state = Settings.mirrorCamera ? .on : .off
        cameraItems += [.separator(), mirror]
        menu.addItem(submenu("Camera", enabled: true, cameraItems))

        let diameter = bubble.diameter
        var sizeItems = CameraBubble.presets.map { preset in
            let entry = item("\(preset.title) (\(Int(preset.diameter)) pt)", #selector(chooseBubbleSize(_:)))
            entry.tag = Int(preset.diameter)
            entry.state = abs(preset.diameter - diameter) < 0.5 ? .on : .off
            return entry
        }
        if !CameraBubble.presets.contains(where: { abs($0.diameter - diameter) < 0.5 }) {
            let current = item("Custom (\(Int(diameter.rounded())) pt)", nil)
            current.state = .on
            sizeItems.append(current)
        }
        sizeItems += [.separator(), item("Drag the rim for any size", nil)]
        menu.addItem(submenu(mode == .cameraOnly ? "Preview Size" : "Bubble Size", enabled: true, sizeItems))

        let shapeAction = canChangeShape ? #selector(chooseShape(_:)) : nil
        var shapeItems = availableShapes.map { shape in
            let entry = item(shape.title, shapeAction)
            entry.representedObject = shape.rawValue
            entry.state = shape == bubble.shape ? .on : .off
            return entry
        }
        shapeItems += [.separator(), shortcutItem("Next Shape", canChangeShape ? #selector(nextShape) : nil, shortcuts[.nextShape])]
        if mode == .cameraOnly { shapeItems.append(item("Camera Only movies are recorded in this shape", nil)) }
        menu.addItem(submenu(mode == .cameraOnly ? "Recording Shape" : "Bubble Shape", enabled: true, shapeItems))

        let background = Settings.cameraBackground
        func backgroundItem(_ title: String, _ choice: CameraBackground) -> NSMenuItem {
            let entry = item(title, #selector(chooseBackground(_:)))
            entry.representedObject = choice.storageValue
            entry.state = background == choice ? .on : .off
            return entry
        }
        // Blur's strength, live: the bubble follows the slider as it's dragged.
        let strength = MenuSliderView(title: "Blur Strength", value: Settings.blurStrength,
                                      minimumSymbol: "drop", maximumSymbol: "drop.fill")
        strength.isEnabled = background == .blur
        strength.onChange = { [weak self] value in
            Settings.blurStrength = value
            self?.bubble.blurStrength = value
        }
        let strengthItem = NSMenuItem()
        strengthItem.view = strength
        var backgroundItems = [backgroundItem("Off", .none), backgroundItem("Blur", .blur), strengthItem, .separator()]
        backgroundItems += CameraBackground.Scene.allCases.map { backgroundItem($0.title, .scene($0)) }
        let color = item("Color…", #selector(chooseBackgroundColor))
        if case .color = background { color.state = .on }
        let image = item("Picture…", #selector(chooseBackgroundImage))
        if case .image(let url) = background {
            image.title = "Picture: \(url.lastPathComponent)…"
            image.state = .on
        }
        backgroundItems += [.separator(), color, image, .separator(), item("Works best facing the camera in good light", nil)]
        menu.addItem(submenu("Background", enabled: true, backgroundItems))

        // Sound
        menu.addItem(.separator())
        let selectedMicrophone = Settings.microphone?.uniqueID
        let none = item("None", #selector(chooseMicrophone(_:)))
        none.state = selectedMicrophone == nil ? .on : .off
        let microphones = submenu("Microphone", enabled: idle, [none, .separator()] + Devices.microphones().map { microphone in
            let entry = item(microphone.localizedName, #selector(chooseMicrophone(_:)))
            entry.representedObject = microphone
            entry.state = microphone.uniqueID == selectedMicrophone ? .on : .off
            return entry
        })
        microphones.submenu?.delegate = self
        microphoneMenu = microphones.submenu
        menu.addItem(microphones)
        // The live meter, only before recording: hover over a mic in the submenu to try it.
        meterView = nil
        if state == .idle {
            let view = MicrophoneMeterView()
            let meterItem = NSMenuItem()
            meterItem.view = view
            menu.addItem(meterItem)
            meterView = view
            if mainMenuOpen { showMeter(for: Settings.microphone) }
        }
        let computerSound = shortcutItem("Record Computer Sound", idle ? #selector(toggleComputerSound) : nil,
                                         shortcuts[.toggleComputerSound])
        computerSound.state = Settings.recordComputerSound ? .on : .off
        menu.addItem(computerSound)
        if Settings.recordComputerSound, Settings.microphone != nil {
            // WebRTC's echo canceller, as in Loom, takes the speakers' sound back out of the mic.
            let echo = shortcutItem("Cancel Echo (No Headphones Needed)", idle ? #selector(toggleEchoCancellation) : nil,
                                    shortcuts[.toggleEchoCancellation])
            echo.state = Settings.echoCancellation ? .on : .off
            menu.addItem(echo)
            if !Settings.echoCancellation {
                menu.addItem(item("Use headphones: on speakers the mic hears the sound too", nil))
            }
        }

        menu.addItem(.separator())
        let countdownItem = shortcutItem("Countdown Before Recording", idle ? #selector(toggleCountdown) : nil, shortcuts[.toggleCountdown])
        countdownItem.state = Settings.countdownEnabled ? .on : .off
        menu.addItem(countdownItem)
        menu.addItem(submenu("Shortcuts", enabled: idle, shortcutMenuItems(shortcuts)))
        menu.addItem(shortcutItem("Open Movies Folder", #selector(openMoviesFolder), shortcuts[.openMoviesFolder]))

        // Sharing: a link to a recording, through your own Supabase project.
        menu.addItem(.separator())
        if sharing.isSharing {
            menu.addItem(item("Sharing… (Show Progress)", #selector(showShareProgress)))
        } else {
            let canShareLast = idle && lastRecording.map { FileManager.default.fileExists(atPath: $0.path) } == true
            menu.addItem(shortcutItem("Share Last Recording", canShareLast ? #selector(shareLastRecording) : nil,
                                      shortcuts[.shareLastRecording]))
        }
        let active = sharing.activeShares
        if !active.isEmpty {
            menu.addItem(submenu("Recent Shares", enabled: true, active.map { share in
                let days = max(0, Int(ceil(share.expiresAt.timeIntervalSinceNow / 86_400)))
                let entry = NSMenuItem(title: "\(share.title)  ·  \(days) day\(days == 1 ? "" : "s") left", action: nil, keyEquivalent: "")
                let copy = item("Copy Link", #selector(copyShareLink(_:)))
                let open = item("Open in Browser", #selector(openShareLink(_:)))
                let delete = item("Delete Now", #selector(deleteShare(_:)))
                for action in [copy, open, delete] { action.representedObject = share.path }
                let actions = NSMenu()
                actions.autoenablesItems = false
                [copy, open, .separator(), delete].forEach(actions.addItem)
                entry.submenu = actions
                return entry
            } + [.separator(), item("Links stop working, and videos are deleted, after 14 days", nil)]))
        }
        menu.addItem(item(sharing.isReady ? "Sharing Setup…" : "Set Up Sharing…", #selector(showSharingSetup)))
        menu.addItem(.separator())
        menu.addItem(item("Quit MyLoom", #selector(quit), key: "q"))
    }

    /// One item per action showing its shortcut (click to change it), grouped as in the main menu,
    /// then any clashes with macOS.
    private func shortcutMenuItems(_ shortcuts: [GlobalHotkeys.Action: Shortcut]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        var warnings: [NSMenuItem] = []
        var group: Int?
        for action in GlobalHotkeys.Action.allCases {
            if let group, group != action.group { items.append(.separator()) }
            group = action.group
            let shortcut = shortcuts[action]
            let entry = shortcutItem(shortcut == nil ? "\(action.title): Not Set" : action.title,
                                     #selector(editShortcut(_:)), shortcut)
            entry.representedObject = action.rawValue
            items.append(entry)

            guard let shortcut else { continue }
            let others = shortcuts.filter { $0.key != action }
            if ShortcutCheck.issues(for: shortcut, action: action, others: others).contains(where: { $0.kind == .macOSClash }) {
                warnings.append(item("⚠︎ \(action.title): \(shortcut.title) is also a macOS shortcut", nil))
            }
        }
        items.append(.separator())
        items += warnings.isEmpty ? [item("No clashes with macOS shortcuts", nil)] : warnings
        items.append(.separator())
        items.append(item("Click an action to change its shortcut", nil))
        items.append(item("Restore Default Shortcuts", #selector(restoreDefaultShortcuts)))
        return items
    }

    @objc private func editShortcut(_ item: NSMenuItem) {
        guard state == .idle, let raw = item.representedObject as? String,
              let action = GlobalHotkeys.Action(rawValue: raw) else { return }
        shortcutRecorder.begin(for: action, current: Settings.shortcut(for: action), others: Settings.shortcuts) { [weak self] outcome in
            if case .save(let shortcut) = outcome { Settings.setShortcut(shortcut, for: action) }
            self?.updateHotkeys()
        }
        updateHotkeys()   // releases MyLoom's shortcuts while recording a new one
    }

    @objc private func restoreDefaultShortcuts() {
        Settings.resetShortcuts()
        updateHotkeys()
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        return item
    }

    /// A menu item with its global shortcut shown beside it, the native way where the key allows.
    /// While MyLoom holds the shortcut, pressing it reaches the shortcut handler rather than the menu,
    /// so the two never both fire. `fallbackKey` is a ⌘ key that only works while the menu is open.
    private func shortcutItem(_ title: String, _ action: Selector?, _ shortcut: Shortcut?, fallbackKey: String = "") -> NSMenuItem {
        let entry = item(title, action, key: shortcut == nil ? fallbackKey : "")
        guard let shortcut else { return entry }
        if let key = shortcut.menuKeyEquivalent {
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = shortcut.modifierFlags
        } else {
            entry.title += "  \(shortcut.title)"
        }
        return entry
    }

    private func submenu(_ title: String, enabled: Bool, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for entry in items { menu.addItem(entry) }
        parent.submenu = menu
        parent.isEnabled = enabled && !items.isEmpty
        return parent
    }

    // MARK: - Status item

    /// Recorded time so far, paused stretches left out, so it matches the movie's length.
    private var elapsedText: String {
        var seconds = recordedBeforePause
        if let stretchStartedAt {
            seconds += max(0, (CMClockGetTime(CMClockGetHostTimeClock()) - stretchStartedAt).seconds)
        }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        clockTimer?.invalidate()
        clockTimer = nil
        button.imagePosition = .imageLeading
        button.contentTintColor = nil
        button.title = ""

        switch state {
        case .idle:
            button.image = symbol("record.circle")
        case .starting:
            button.image = symbol("timer")
        case .saving:
            button.image = symbol("hourglass")
        case .paused:
            button.image = symbol("pause.circle.fill")
            button.contentTintColor = .systemOrange
            button.title = " " + elapsedText
        case .recording:
            button.image = symbol("record.circle.fill")
            button.contentTintColor = .systemRed
            button.title = " " + elapsedText
            // Common modes keep the clock ticking while the menu is open.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.statusItem.button?.title = " " + self.elapsedText
                    self.refreshControls()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            clockTimer = timer
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "MyLoom")
    }

    // MARK: - Alerts and permissions

    private static func requestAccess(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showPermissionAlert(_ title: String, _ message: String, pane: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
