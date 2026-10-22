import AppKit
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Command-line checks of the recording path. See main.swift.
enum SelfTest {
    /// Feeds 4 s of 1280×720 frames (a bar sweeping across) and a 440 Hz tone through MovieWriter
    /// in real time, timed on the host clock exactly as live capture is, then reads the file back.
    /// Like a real session, the movie starts 0.5 s in (where a countdown would reach zero) and is
    /// paused from 1.5 s to 2.5 s, so it should come out 2.5 s long with no gap.
    static func writer(output: URL) async -> Int32 {
        try? FileManager.default.removeItem(at: output)
        let frameRate = ScreenRecorder.frameRate
        let width = 1280, height = 720
        let samplesPerChunk = 1024
        func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48_000) }

        do {
            let begin = CMClockGetTime(CMClockGetHostTimeClock())
            let writer = try MovieWriter(url: output, width: width, height: height, frameRate: frameRate,
                                         audioChannels: 1, startingAt: begin + seconds(0.5))
            let end = begin + seconds(4)
            var controls: [(at: CMTime, run: () -> Void)] = [
                (begin + seconds(0.5), { writer.beginAtRequestedStart() }),
                (begin + seconds(1.5), { writer.pause(at: begin + seconds(1.5)) }),
                (begin + seconds(2.5), { writer.resume(at: begin + seconds(2.5)) }),
            ]
            var nextFrame = 0
            var nextSample = 0

            while true {
                let frameTime = begin + CMTime(value: CMTimeValue(nextFrame), timescale: CMTimeScale(frameRate))
                let audioTime = begin + CMTime(value: CMTimeValue(nextSample), timescale: 48_000)
                let nextTime = CMTimeMinimum(frameTime, audioTime)
                if nextTime >= end { break }
                let wait = (nextTime - CMClockGetTime(CMClockGetHostTimeClock())).seconds
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                while let control = controls.first, control.at <= nextTime {
                    control.run()
                    controls.removeFirst()
                }

                if frameTime <= audioTime {
                    writer.appendFrame(try testPattern(width: width, height: height, progress: Double(nextFrame) / Double(frameRate * 4)), at: frameTime)
                    nextFrame += 1
                } else {
                    writer.appendAudio(try tone(firstSample: nextSample, count: samplesPerChunk, at: audioTime))
                    nextSample += samplesPerChunk
                }
            }

            let url: URL = try await withCheckedThrowingContinuation { continuation in
                writer.finish(at: end) { continuation.resume(with: $0) }
            }
            return try await report(url, expectedSeconds: 2.5)
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    /// A neutral movie `seconds` long (the moving test pattern and a 440 Hz tone), written in real
    /// time through the same MovieWriter recordings use. For trying out sharing without uploading
    /// anything from the screen or camera.
    static func testMovie(output: URL, seconds length: Double) async -> Int32 {
        try? FileManager.default.removeItem(at: output)
        let frameRate = ScreenRecorder.frameRate
        let width = 1280, height = 720
        let samplesPerChunk = 1024
        do {
            let begin = CMClockGetTime(CMClockGetHostTimeClock())
            let writer = try MovieWriter(url: output, width: width, height: height, frameRate: frameRate, audioChannels: 1)
            let end = begin + CMTime(seconds: length, preferredTimescale: 48_000)
            var nextFrame = 0, nextSample = 0
            while true {
                let frameTime = begin + CMTime(value: CMTimeValue(nextFrame), timescale: CMTimeScale(frameRate))
                let audioTime = begin + CMTime(value: CMTimeValue(nextSample), timescale: 48_000)
                let nextTime = CMTimeMinimum(frameTime, audioTime)
                if nextTime >= end { break }
                let wait = (nextTime - CMClockGetTime(CMClockGetHostTimeClock())).seconds
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                if frameTime <= audioTime {
                    // The bar sweeps across every 4 seconds, so the picture is visibly moving.
                    let sweep = (Double(nextFrame) / Double(frameRate * 4)).truncatingRemainder(dividingBy: 1)
                    writer.appendFrame(try testPattern(width: width, height: height, progress: sweep), at: frameTime)
                    nextFrame += 1
                } else {
                    writer.appendAudio(try tone(firstSample: nextSample, count: samplesPerChunk, at: audioTime))
                    nextSample += samplesPerChunk
                }
            }
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                writer.finish(at: end) { continuation.resume(with: $0) }
            }
            return try await report(url, expectedSeconds: length)
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    /// Uploads `megabytes` of random data through the real upload code with the sign-in saved by
    /// Sharing Setup, the size of a long share, checks the link serves all of it, then deletes it.
    /// Shows that big videos fit the project's limits and upload reliably in 6 MB pieces.
    static func bigUpload(megabytes: Int) async -> Int32 {
        let defaults = UserDefaults.standard
        guard let project = defaults.string(forKey: "supabaseURL").flatMap(URL.init(string:)),
              let key = defaults.string(forKey: "supabaseKey"),
              let saved = Keychain.read("supabase-session"),
              let session = try? JSONDecoder().decode(Supabase.Session.self, from: Data(saved.utf8)) else {
            fail("sharing isn't set up: sign in under Sharing Setup… first")
            return 2
        }
        let client = Supabase(projectURL: project, apiKey: key, session: session)
        client.onSessionChange = { session in
            Keychain.write("supabase-session", session.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) })
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("myloom-upload-test.mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            var bytes = Data(count: megabytes * 1_000_000)
            bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            try bytes.write(to: file)
            let (_, userID) = try await client.accessToken()
            let path = "\(userID)/upload-test-\(UUID().uuidString.prefix(8)).mp4"
            let started = Date()
            var lastShown = -1
            try await client.upload(file, to: path, in: Sharing.bucket, contentType: "video/mp4") { fraction in
                let percent = Int(fraction * 100)
                if percent / 10 != lastShown / 10 { lastShown = percent; print("  \(percent)%") }
            }
            let seconds = Date().timeIntervalSince(started)
            print(String(format: "uploaded %d MB in %.0f s (%.1f MB/s) in %d pieces", megabytes, seconds, Double(megabytes) / seconds,
                         Int(ceil(Double(bytes.count) / Double(Supabase.chunkSize)))))
            let link = try await client.signedLink(to: path, in: Sharing.bucket, lifetime: Sharing.lifetime)
            var head = URLRequest(url: link)
            head.httpMethod = "HEAD"
            let (_, reply) = try await URLSession.shared.data(for: head)
            let length = (reply as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? 0
            let ok = (reply as? HTTPURLResponse)?.statusCode == 200 && length == bytes.count
            print(ok ? "ok   the link serves all \(length) bytes" : "FAIL the link served \(length) of \(bytes.count) bytes")
            try await client.delete([path], in: Sharing.bucket)
            print("deleted the test upload")
            print(ok ? "PASS" : "FAIL")
            return ok ? 0 : 1
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    enum CaptureTarget {
        case display(area: CGRect?)   // the main display, or an area of it (points, origin top-left)
        case frontWindow
        case camera
    }

    /// Records `target` through the real ScreenRecorder for `seconds`. Capture starts a second early
    /// and the movie starts on time, the way it does behind the countdown.
    static func capture(output: URL, seconds: Double, target: CaptureTarget, computerSound: Bool = false,
                        microphoneName: String? = nil) async -> Int32 {
        try? FileManager.default.removeItem(at: output)
        let source: CaptureSource
        switch target {
        case .display(let area):
            guard CGPreflightScreenCaptureAccess() else { return noAccess("Screen Recording") }
            source = .display(CGMainDisplayID(), area: area)
        case .frontWindow:
            guard CGPreflightScreenCaptureAccess() else { return noAccess("Screen Recording") }
            guard let window = WindowInfo.onScreen().first else {
                fail("no window on screen to record")
                return 1
            }
            let scale = NSScreen.screens.first { $0.frame.intersects(window.frame.flippedForAppKit) }?.backingScaleFactor ?? 2
            let expected = ScreenRecorder.outputSize(points: window.frame.size, scale: scale)
            print("window: \(window.appName), expecting about \(expected.width)×\(expected.height)")
            source = .window(window.id, alsoShowing: [])
        case .camera:
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return noAccess("Camera") }
            guard let camera = AVCaptureDevice.default(for: .video) else {
                fail("no camera")
                return 1
            }
            print("camera: \(camera.localizedName)")
            let feed = await MainActor.run {
                let bubble = CameraBubble()
                bubble.shape = .landscape   // the camera's whole picture
                return bubble
            }
            do {
                try await MainActor.run { try feed.use(camera) }
            } catch {
                fail(error.localizedDescription)
                return 1
            }
            source = .camera(feed)
        }
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? AVCaptureDevice.default(for: .audio) : nil
        if let microphoneName, microphone != nil {
            microphone = Devices.microphones().first { $0.localizedName.localizedCaseInsensitiveContains(microphoneName) }
        }
        print("microphone: \(microphone?.localizedName ?? "none (not allowed for the launching app)")")

        let recorder = ScreenRecorder()
        do {
            let start = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 1)
            print("computer sound: \(computerSound ? "on" : "off")")
            try await recorder.start(source, microphone: microphone, computerSound: computerSound, startingAt: start, to: output)
            let end = start + CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            try await Task.sleep(nanoseconds: UInt64(max(0, (end - CMClockGetTime(CMClockGetHostTimeClock())).seconds) * 1e9))
            let url = try await recorder.stop(endingAt: end)
            return try await report(url, expectedSeconds: seconds)
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    /// Draws the Custom Size overlay offscreen, empty and with a 720p area, into PNGs in `folder`.
    /// Shows the layout without a real screen behind it.
    @MainActor
    static func renderUI(to folder: URL) -> Int32 {
        let size = NSSize(width: 1512, height: 982)   // a 14-inch MacBook Pro at its default scaling
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, preset) in [("area-empty", nil), ("area-720p", CGSize(width: 1280, height: 720))] as [(String, CGSize?)] {
                let view = AreaSelectionView(frame: NSRect(origin: .zero, size: size), scale: 2, initial: nil)
                view.appearance = NSAppearance(named: .darkAqua)
                if let preset { view.setSize(pixels: preset) }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
                // A mid-grey backdrop stands in for the desktop under the overlay.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSColor(white: 0.55, alpha: 1).setFill()
                view.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let url = folder.appendingPathComponent("\(name).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }

            let countdown = CountdownView(frame: NSRect(origin: .zero, size: CountdownView.size))
            countdown.hint = "Click or press \(GlobalHotkeys.Action.stop.title) to cancel"
            countdown.number = 2
            countdown.alphaValue = 1
            guard let bitmap = countdown.bitmapImageRepForCachingDisplay(in: countdown.bounds) else { return 1 }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(white: 0.55, alpha: 1).setFill()
            countdown.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            countdown.cacheDisplay(in: countdown.bounds, to: bitmap)
            let url = folder.appendingPathComponent("countdown.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)

            // The microphone meter in four states, stacked as they'd look in the menu.
            let meterStates: [MicrophoneMeterView.Content] = [
                .live(name: "Blue Yeti (USB)", reading: .init(level: 0.62, peak: 0.70, status: .hearing)),
                .live(name: "Sam's iPhone Microphone", reading: .init(level: 0.93, peak: 0.96, status: .hearing)),
                .live(name: "MacBook Pro Microphone", reading: .init(level: 0, peak: 0, status: .noAudio)),
                .message("Click to test your microphone", color: .controlAccentColor),
            ]
            let stack = NSView(frame: NSRect(x: 0, y: 0, width: MicrophoneMeterView.size.width,
                                             height: MicrophoneMeterView.size.height * CGFloat(meterStates.count)))
            stack.appearance = NSAppearance(named: .aqua)
            for (index, content) in meterStates.enumerated() {
                let view = MicrophoneMeterView()
                view.content = content
                view.setFrameOrigin(NSPoint(x: 0, y: stack.bounds.height - MicrophoneMeterView.size.height * CGFloat(index + 1)))
                stack.addSubview(view)
            }
            guard let meterImage = stack.bitmapImageRepForCachingDisplay(in: stack.bounds) else { return 1 }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: meterImage)
            stack.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                stack.bounds.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            stack.cacheDisplay(in: stack.bounds, to: meterImage)
            let meterFile = folder.appendingPathComponent("microphone-meter.png")
            try meterImage.representation(using: .png, properties: [:])?.write(to: meterFile)
            print(meterFile.path)

            // The shortcut recorder with no clash, a macOS clash (warning) and a MyLoom clash (error).
            let defaults = GlobalHotkeys.Action.allCases.reduce(into: [GlobalHotkeys.Action: Shortcut]()) { result, action in
                result[action] = action.defaultShortcut
            }
            let cases: [(String, GlobalHotkeys.Action, Shortcut)] = [
                ("shortcut-free", .start, defaults[.start]!),
                ("shortcut-macos-clash", .start, Shortcut(keyCode: 20, modifiers: 0x200 | 0x100)),    // ⇧⌘3
                ("shortcut-myloom-clash", .pauseResume, defaults[.stop]!),
                ("shortcut-no-default", .window, Shortcut(keyCode: 13, modifiers: 0x1000 | 0x800 | 0x100)),   // ⌃⌥⌘W
            ]
            for (name, action, shortcut) in cases {
                let recorder = ShortcutRecorderView(action: action, current: action.defaultShortcut, others: defaults)
                recorder.appearance = NSAppearance(named: .aqua)
                recorder.show(shortcut)
                recorder.setFrameSize(recorder.fittingSize)
                recorder.layoutSubtreeIfNeeded()
                guard let image = recorder.bitmapImageRepForCachingDisplay(in: recorder.bounds) else { return 1 }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
                recorder.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    recorder.bounds.fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                recorder.cacheDisplay(in: recorder.bounds, to: image)
                let file = folder.appendingPathComponent("\(name).png")
                try image.representation(using: .png, properties: [:])?.write(to: file)
                print(file.path)
            }
            return 0
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Background effects

    /// Shows `photo` (a picture of a person, standing in for the camera) in the camera bubble with
    /// each background effect, through the same Vision segmentation and display layer camera frames
    /// go through, and saves what the window server shows, which is what a screen recording gets, as
    /// PNGs in `folder`. Checks a background spot and the time each frame takes. Needs Screen
    /// Recording access, not the camera.
    @MainActor
    static func effects(photo: URL, folder: URL) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else { return noAccess("Screen Recording") }
        let context = CIContext()
        guard let source = CIImage(contentsOf: photo, options: [.applyOrientationProperty: true]) else {
            fail("can't read \(photo.path)")
            return 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A 720p frame in the camera's 4:2:0 layout, filled with the photo.
            let frame = try pixelBuffer(width: 1280, height: 720, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let fill = max(1280 / source.extent.width, 720 / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            context.render(scaled.transformed(by: CGAffineTransform(translationX: (1280 - scaled.extent.width) / 2 - scaled.extent.minX,
                                                                    y: (720 - scaled.extent.height) / 2 - scaled.extent.minY)),
                           to: frame)
            // A picture of one's own for the Picture… choice, saved and read back the way a chosen file is.
            let picture = folder.appendingPathComponent("chosen-picture.png")
            let checks = CIFilter(name: "CICheckerboardGenerator", parameters: [
                "inputColor0": CIColor(red: 0.95, green: 0.8, blue: 0.3), "inputColor1": CIColor(red: 0.3, green: 0.2, blue: 0.5),
                "inputWidth": 120, "inputCenter": CIVector(x: 0, y: 0),
            ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1200))
            try context.writePNGRepresentation(of: checks, to: picture, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

            let bubble = CameraBubble()
            bubble.diameter = 320
            let home = NSScreen.main?.visibleFrame ?? .zero
            let green = (red: 0.1, green: 0.6, blue: 0.3)
            var cases: [(name: String, background: CameraBackground, shape: CameraBubble.Shape)] = [("blur", .blur, .circle)]
            cases += CameraBackground.Scene.allCases.map { ($0.rawValue, .scene($0), .circle) }
            cases += [("color", .color(red: green.red, green: green.green, blue: green.blue), .circle), ("picture", .image(picture), .circle),
                      ("square-blur", .blur, .square), ("landscape-blur", .blur, .landscape), ("portrait-blur", .blur, .portrait),
                      ("off", .none, .circle)]
            var ok = true
            for test in cases {
                bubble.shape = test.shape
                bubble.background = test.background
                // About a second of frames at 30 fps, timed, so Vision runs as it would live.
                var times: [Double] = []
                for _ in 0..<30 {
                    let start = CACurrentMediaTime()
                    bubble.showStill(frame, home: home)
                    times.append((CACurrentMediaTime() - start) * 1000)
                    try await Task.sleep(nanoseconds: 33_000_000)
                }
                guard let image = try await captureWindow(bubble.windowID) else {
                    fail("couldn't capture the bubble")
                    return 1
                }
                let file = folder.appendingPathComponent("bubble-\(test.name).png")
                try writePNG(image, to: file)
                times.sort()
                // The right of the bubble's middle row is background in the photo; the centre is the bubble middle.
                let spot = pixel(image, x: 0.8, y: 0.45)
                var line = String(format: "%@  %d×%d  frame median %.1f ms, slowest %.1f ms  background spot rgb(%d,%d,%d)",
                                  test.name, image.width, image.height, times[times.count / 2], times.last!, spot.r, spot.g, spot.b)
                switch test.background {
                case .color:
                    let expected = [green.red, green.green, green.blue].map { Int($0 * 255) }
                    let close = zip([spot.r, spot.g, spot.b], expected).allSatisfy { abs($0 - $1) <= 12 }
                    line += close ? "  = chosen colour" : "  ≠ chosen colour rgb(\(expected[0]),\(expected[1]),\(expected[2]))"
                    ok = ok && close
                case .none:
                    // No camera behind the effect, so with it off the bubble must be back to the empty preview.
                    let dark = max(spot.r, spot.g, spot.b) < 16
                    line += dark ? "  = effect removed" : "  ≠ effect still showing"
                    ok = ok && dark
                default:
                    break
                }
                print(line)
                print("  \(file.path)")
            }
            // Blur Strength: less of the room's detail should survive as it goes up.
            bubble.shape = .circle
            bubble.background = .blur
            var details: [Double] = []
            for strength in [0.0, CameraEffects.defaultBlurStrength, 1.0] {
                bubble.blurStrength = strength
                var times: [Double] = []
                for _ in 0..<20 {
                    let start = CACurrentMediaTime()
                    bubble.showStill(frame, home: home)
                    times.append((CACurrentMediaTime() - start) * 1000)
                    try await Task.sleep(nanoseconds: 33_000_000)
                }
                guard let image = try await captureWindow(bubble.windowID) else { return 1 }
                try writePNG(image, to: folder.appendingPathComponent(String(format: "bubble-blur-strength-%.1f.png", strength)))
                // The right of the bubble is background in the photo.
                let detail = detail(image, x: 0.6...0.85, y: 0.25...0.6)
                details.append(detail)
                times.sort()
                print(String(format: "blur strength %.1f  background detail %.2f  frame median %.1f ms, slowest %.1f ms",
                             strength, detail, times[times.count / 2], times.last!))
            }
            let weaker = details[0] > details[1] && details[1] > details[2]
            print(weaker ? "  = stronger blur leaves less detail" : "  ≠ blur strength didn't change the detail as expected")
            ok = ok && weaker
            bubble.hide()
            print(ok ? "PASS" : "FAIL")
            return ok ? 0 : 1
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Sharing

    /// Shares `movie` through the real sharing code: makes the share copy, signs in (and refreshes
    /// the sign-in), uploads in resumable pieces, makes the 14-day link and fetches the video
    /// through it, lists it, then checks the 14-day cleanup deletes it (on a local stand-in server,
    /// by making it look 15 days old; on a real project, by deleting it directly) and the link dies.
    /// With no email (`--stored`), it uses the project and sign-in saved by Sharing Setup instead, and
    /// saves the refreshed sign-in back, so nobody has to type a password into a terminal.
    static func share(movie: URL, project: URL?, key: String?, email: String?, password: String?) async -> Int32 {
        var ok = true
        func check(_ passed: Bool, _ what: String) {
            print("\(passed ? "ok  " : "FAIL") \(what)")
            ok = ok && passed
        }
        let defaults = UserDefaults.standard
        guard let project = project ?? defaults.string(forKey: "supabaseURL").flatMap(URL.init(string:)),
              let key = key ?? defaults.string(forKey: "supabaseKey") else {
            fail("sharing isn't set up: sign in under Sharing Setup… first")
            return 2
        }
        let local = project.host == "127.0.0.1"
        do {
            // 1. The share copy.
            let source = AVURLAsset(url: movie)
            let sourceDuration = try await source.load(.duration).seconds
            let sourceBytes = (try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let started = Date()
            let copy = try await ShareCopy.make(from: movie) { _ in }
            defer { try? FileManager.default.removeItem(at: copy) }
            let copied = AVURLAsset(url: copy)
            let copyDuration = try await copied.load(.duration).seconds
            let copyBytes = (try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let size = try await copied.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
            let hasSound = try await !copied.loadTracks(withMediaType: .audio).isEmpty
            let sourceHasSound = try await !source.loadTracks(withMediaType: .audio).isEmpty
            print(String(format: "share copy: %d×%d, %.2f s, %.1f MB (original %.1f MB), %.0f kbit/s, made in %.1f s",
                         Int(size.width), Int(size.height), copyDuration, Double(copyBytes) / 1e6, Double(sourceBytes) / 1e6,
                         Double(copyBytes) * 8 / max(copyDuration, 0.01) / 1000, Date().timeIntervalSince(started)))
            check(abs(copyDuration - sourceDuration) < 0.3, "copy is as long as the recording")
            check(size.width <= 1920 && size.height <= 1080 && size.width > 0, "copy is at most 1080p")
            check(hasSound == sourceHasSound, "copy keeps the sound track")

            // 2. Signing in, and refreshing the sign-in when it runs out.
            let first: Supabase.Session
            if let email, let password {
                let client = Supabase(projectURL: project, apiKey: key, session: nil)
                try await client.signIn(email: email, password: password)
                guard let session = client.session else { throw Supabase.Failure.signedOut }
                first = session
            } else {
                guard let saved = Keychain.read("supabase-session"),
                      let session = try? JSONDecoder().decode(Supabase.Session.self, from: Data(saved.utf8)) else {
                    fail("no saved sign-in: sign in under Sharing Setup… first")
                    return 2
                }
                first = session
                print("using the saved sign-in for \(session.email) at \(project.host ?? "?")")
            }
            let expired = Supabase.Session(accessToken: first.accessToken, refreshToken: first.refreshToken,
                                           expiresAt: .distantPast, userID: first.userID, email: first.email)
            let later = Supabase(projectURL: project, apiKey: key, session: expired)
            if email == nil {
                // Refreshing uses up the saved refresh token, so keep the new one for MyLoom.
                later.onSessionChange = { session in
                    Keychain.write("supabase-session", session.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) })
                }
            }
            let refreshed = try await later.accessToken()
            check(refreshed.token != first.accessToken && refreshed.userID == first.userID, "an expired sign-in is refreshed")

            // 3. Upload, in 6 MB resumable pieces.
            let path = "\(first.userID)/selftest-\(UUID().uuidString.prefix(8)).mp4"
            var updates = 0
            try await later.upload(copy, to: path, in: Sharing.bucket, contentType: "video/mp4") { _ in updates += 1 }
            let pieces = Int(ceil(Double(copyBytes) / Double(Supabase.chunkSize)))
            check(true, "uploaded \(String(format: "%.1f", Double(copyBytes) / 1e6)) MB in \(pieces) piece\(pieces == 1 ? "" : "s")")

            // 4. The link: anyone can watch, for 14 days.
            let link = try await later.signedLink(to: path, in: Sharing.bucket, lifetime: Sharing.lifetime)
            print("link: \(link.absoluteString.prefix(110))…")
            // Always from the server, never this Mac's cache, as a viewer elsewhere would get it.
            let viewerRequest = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData)
            let (data, response) = try await URLSession.shared.data(for: viewerRequest)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 200 && data.count == copyBytes, "the link plays the whole video without signing in (\(data.count) bytes)")
            check(http?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("video/mp4") == true, "served as video/mp4, so browsers play it")
            let verified = await Sharing.verify(link, bytes: copyBytes)
            check(verified, "MyLoom's own check before handing out a link passes")
            if local, let state = try? await mockState(project) {
                let asked = (state["log"] as? [String: Any])?["expires_in"] as? Int
                check(asked == Int(Sharing.lifetime), "the link was asked to last 14 days (\(asked ?? 0) s)")
                // The stand-in drops the connection on the second piece, so this needs two or more.
                if pieces > 1 {
                    check((state["log"] as? [String: Any])?["dropped"] as? Bool == true, "a dropped upload piece was resumed")
                }
            }

            // 5. Listing.
            let listed = try await later.list(first.userID, in: Sharing.bucket)
            check(listed.contains { "\(first.userID)/\($0.name)" == path }, "the video is listed in your folder")

            // 6. The 14-day cleanup.
            let fresh = try await Sharing.deleteExpired(using: later)
            check(fresh == 0, "a new video isn't deleted by the cleanup")
            if local {
                var request = URLRequest(url: project.appendingPathComponent("test/backdate"))
                request.url = URL(string: request.url!.absoluteString + "?path=\(path)&days=15")
                request.httpMethod = "POST"
                _ = try await URLSession.shared.data(for: request)
                let removed = try await Sharing.deleteExpired(using: later)
                check(removed == 1, "a 15-day-old video is deleted by the cleanup")
            } else {
                try await later.delete([path], in: Sharing.bucket)
            }
            let (_, after) = try await URLSession.shared.data(for: viewerRequest)
            check((after as? HTTPURLResponse)?.statusCode != 200, "once deleted, the link no longer plays (\((after as? HTTPURLResponse)?.statusCode ?? 0))")
            let verifiedAfter = await Sharing.verify(link, bytes: copyBytes)
            check(!verifiedAfter, "MyLoom's check catches a link that doesn't play")
            check(updates > 0, "upload progress was reported \(updates) times")
        } catch {
            fail(error.localizedDescription)
            return 1
        }
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    private static func mockState(_ project: URL) async throws -> [String: Any] {
        var request = URLRequest(url: project.appendingPathComponent("test/state"))
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - Drawing

    /// Draws on the main display with the real mouse, through the real drawing windows, while
    /// recording it, then checks the movie: each drawing in its colour, the toolbar left out, and
    /// the same in a window recording. Then Esc, Undo and fading. A grey window covers the screen
    /// meanwhile so colours can be checked exactly. Needs Screen Recording and Accessibility (to
    /// move and click the mouse) for the app it's run from. Before each click it checks that the
    /// drawing window is what's under the pointer, so no click can reach another app.
    @MainActor
    static func drawing(folder: URL) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else { return noAccess("Screen Recording") }
        guard AXIsProcessTrusted() else { return noAccess("Accessibility") }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) else { return 1 }
        let bounds = CGDisplayBounds(screen.displayID)   // global, top-left origin, as mouse events use
        func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y) }
        let savedMouse = CGEvent(source: nil)?.location
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let grey = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = grey
        backdrop.level = .floating
        backdrop.isReleasedWhenClosed = false
        backdrop.orderFrontRegardless()
        let overlay = DrawingOverlay()
        overlay.fades = false
        let toast = Toast()
        let controls = RecordingControls()
        var ok = true
        func check(_ passed: Bool, _ what: String) {
            print("\(passed ? "ok  " : "FAIL") \(what)")
            ok = ok && passed
        }
        defer {
            overlay.stop()
            overlay.clear()
            controls.hide()
            backdrop.orderOut(nil)
            if let savedMouse { CGWarpMouseCursorPosition(savedMouse) }
        }

        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            // Recording starts before drawing does, so the toolbar appears only after the capture
            // began: the harder case for leaving it out.
            let recorder = ScreenRecorder()
            let fullMovie = folder.appendingPathComponent("drawing-full-screen.mp4")
            try? FileManager.default.removeItem(at: fullMovie)
            try await recorder.start(.display(screen.displayID, area: nil), microphone: nil,
                                     excludingWindows: [overlay.toolbarWindowID, toast.windowID, controls.windowID], to: fullMovie)
            // The recording controls, as the app shows them once recording starts.
            controls.update(.recording, elapsed: "0:01", drawing: true, canDraw: true, sharing: false, shortcuts: [.stop: "⌃⌥⌘S", .pauseResume: "⌃⌥⌘P"])
            controls.show(on: screen)
            overlay.start(toolbarOn: screen)
            try await Task.sleep(nanoseconds: 400_000_000)
            check(overlay.keyCanvasID != nil, "a drawing window is key, so Esc and ⌘Z reach it")

            let strokes: [(DrawingOverlay.Tool, Int, [CGPoint])] = [
                (.pen, 0, stride(from: 0.20, through: 0.40, by: 0.01).map { at($0, 0.40) }),
                (.highlighter, 1, stride(from: 0.20, through: 0.40, by: 0.01).map { at($0, 0.50) }),
                (.arrow, 2, stride(from: 0.0, through: 1.0, by: 0.1).map { at(0.55 + 0.2 * $0, 0.65 - 0.2 * $0) }),
                (.box, 3, stride(from: 0.0, through: 1.0, by: 0.1).map { at(0.20 + 0.2 * $0, 0.60 + 0.15 * $0) }),
            ]
            for (tool, color, points) in strokes {
                overlay.tool = tool
                overlay.colorIndex = color
                guard try await safeDrag(points, onto: Set(overlay.visibleCanvasIDs)) else {
                    fail("something other than the drawing window was under the pointer, so the test stopped without clicking")
                    _ = try? await recorder.stop(endingAt: nil)
                    return 1
                }
            }
            check(overlay.drawingCount == 4, "four drawings made with the real mouse (got \(overlay.drawingCount))")

            // Esc goes to the key drawing window and ends drawing; the drawings stay.
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap) }
            try await Task.sleep(nanoseconds: 300_000_000)
            check(!overlay.isDrawing && overlay.drawingCount == 4, "Esc stops drawing and keeps the drawings")
            overlay.start(toolbarOn: screen)   // the toolbar back on screen for the recording check
            toast.show("A notice that should be left out", on: screen)
            try await Task.sleep(nanoseconds: 700_000_000)
            let toolbarFrame = NSApp.windows.first { CGWindowID($0.windowNumber) == overlay.toolbarWindowID }?.frame ?? .zero
            if let image = try await captureWindow(overlay.toolbarWindowID) {
                try writePNG(image, to: folder.appendingPathComponent("toolbar.png"))
            }
            if let image = try await captureWindow(controls.windowID) {
                try writePNG(image, to: folder.appendingPathComponent("recording-controls.png"))
            }
            let controlsFrame = NSApp.windows.first { CGWindowID($0.windowNumber) == controls.windowID }?.frame ?? .zero
            _ = try await recorder.stop(endingAt: nil)
            overlay.stop()

            func fraction(_ point: NSPoint) -> (Double, Double) {
                (Double((point.x - screen.frame.minX) / screen.frame.width), Double((screen.frame.maxY - point.y) / screen.frame.height))
            }
            let toolbarSpot = fraction(NSPoint(x: toolbarFrame.midX, y: toolbarFrame.midY))
            try await checkDrawings(in: fullMovie, name: "full screen", toolbar: toolbarSpot, folder: folder, check: check)
            // The recording controls, like the toolbar, must not be in the movie.
            let controlsSpot = fraction(NSPoint(x: controlsFrame.midX, y: controlsFrame.midY))
            try await checkLeftOut(in: fullMovie, at: controlsSpot, what: "recording controls", check: check)

            // A window recording only draws the windows it's told about: the grey window and the drawings.
            let windowMovie = folder.appendingPathComponent("drawing-window.mp4")
            try? FileManager.default.removeItem(at: windowMovie)
            let windowRecorder = ScreenRecorder()
            try await windowRecorder.start(.window(CGWindowID(backdrop.windowNumber), alsoShowing: overlay.visibleCanvasIDs),
                                           microphone: nil, to: windowMovie)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            _ = try await windowRecorder.stop(endingAt: nil)
            try await checkDrawings(in: windowMovie, name: "window", toolbar: nil, folder: folder, check: check)

            overlay.undo()
            check(overlay.drawingCount == 3, "Undo removes the last drawing")
            overlay.fades = true
            try await Task.sleep(nanoseconds: UInt64((DrawingOverlay.fadeDelay + DrawingOverlay.fadeDuration + 0.5) * 1e9))
            check(overlay.drawingCount == 0 && overlay.visibleCanvasIDs.isEmpty,
                  "with Fade on, drawings fade after \(Int(DrawingOverlay.fadeDelay)) s and the drawing windows leave the screen")
        } catch {
            fail(error.localizedDescription)
            return 1
        }
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    /// Presses, drags through `points` and releases with the real mouse, but only if one of
    /// `windows` is the frontmost window under every point.
    @MainActor
    private static func safeDrag(_ points: [CGPoint], onto windows: Set<CGWindowID>) async throws -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for point in points {
            // Front to back; skip the Dock, menu bar and other system layers above normal windows.
            let front = list.first { info in
                guard let layer = info[kCGWindowLayer as String] as? Int, layer < Int(CGWindowLevelForKey(.dockWindow)),
                      let rect = info[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }) else { return false }
                return rect.contains(point)
            }
            guard let id = front?[kCGWindowNumber as String] as? Int, windows.contains(CGWindowID(id)) else { return false }
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, points[0])
        try await Task.sleep(nanoseconds: 30_000_000)
        post(.leftMouseDown, points[0])
        for point in points.dropFirst() {
            try await Task.sleep(nanoseconds: 12_000_000)
            post(.leftMouseDragged, point)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        post(.leftMouseUp, points.last!)
        try await Task.sleep(nanoseconds: 100_000_000)
        return true
    }

    /// Checks the last frame of `movie` for the four test drawings over the grey, and that the
    /// toolbar (at `toolbar`, as fractions of the frame from the top-left) was left out.
    @MainActor
    private static func checkDrawings(in movie: URL, name: String, toolbar: (Double, Double)?, folder: URL,
                                      check: @MainActor (Bool, String) -> Void) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: duration - CMTime(value: 1, timescale: 10))
        try writePNG(frame, to: folder.appendingPathComponent("drawing-\(name.replacingOccurrences(of: " ", with: "-")).png"))
        // The movie's colours are shifted a little by encoding (the grey comes back lighter), so each
        // drawing is checked by which colour dominates, against the grey actually recorded.
        typealias RGB = (r: Int, g: Int, b: Int)
        func describe(_ spot: RGB) -> String { "rgb(\(spot.r),\(spot.g),\(spot.b))" }
        func grey(_ spot: RGB, like reference: RGB) -> Bool {
            abs(spot.r - reference.r) <= 8 && abs(spot.g - reference.g) <= 8 && abs(spot.b - reference.b) <= 8
        }
        let empty = pixel(frame, x: 0.85, y: 0.85)
        let pen = pixel(frame, x: 0.30, y: 0.40), highlight = pixel(frame, x: 0.30, y: 0.50)
        let arrow = pixel(frame, x: 0.65, y: 0.55), box = pixel(frame, x: 0.20, y: 0.675)
        check(abs(empty.r - empty.g) <= 6 && abs(empty.g - empty.b) <= 6, "\(name): grey where nothing was drawn, \(describe(empty))")
        check(pen.r > 200 && pen.r > pen.g + 100 && pen.r > pen.b + 100, "\(name): red pen line recorded, \(describe(pen))")
        // See-through yellow: the grey shows, warmer, with red and green raised over blue.
        check(highlight.r > empty.r + 25 && highlight.g > empty.g + 15 && highlight.b < empty.b && highlight.r > highlight.b + 50,
              "\(name): see-through yellow highlight recorded, \(describe(highlight))")
        check(arrow.g > 150 && arrow.g > arrow.r + 80 && arrow.g > arrow.b + 60, "\(name): green arrow recorded, \(describe(arrow))")
        check(box.b > 200 && box.b > box.r + 120 && box.b > box.g + 60, "\(name): blue box recorded, \(describe(box))")
        if let toolbar {
            let spot = pixel(frame, x: toolbar.0, y: toolbar.1)
            check(grey(spot, like: empty), "\(name): toolbar left out (grey where it sits), \(describe(spot))")
        }
    }

    /// Checks that the last frame of `movie` shows the grey backdrop at `spot` (fractions from the
    /// top-left), where a window that should have been left out sat.
    @MainActor
    private static func checkLeftOut(in movie: URL, at spot: (Double, Double), what: String,
                                     check: @MainActor (Bool, String) -> Void) async throws {
        let asset = AVURLAsset(url: movie)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: try await asset.load(.duration) - CMTime(value: 1, timescale: 10))
        let there = pixel(frame, x: spot.0, y: spot.1), empty = pixel(frame, x: 0.85, y: 0.85)
        let grey = abs(there.r - empty.r) <= 8 && abs(there.g - empty.g) <= 8 && abs(there.b - empty.b) <= 8
        check(grey, "full screen: \(what) left out (grey where they sit), rgb(\(there.r),\(there.g),\(there.b))")
    }

    /// What the window server shows of window `id`, without its shadow.
    private static func captureWindow(_ id: CGWindowID?) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let scale = NSScreen.screens.first { $0.frame.intersects(window.frame.flippedForAppKit) }?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                          configuration: configuration)
    }

    /// How busy a region is (fractions from the top-left): the average brightness difference
    /// between neighbouring pixels. Blurring lowers it.
    private static func detail(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let width = image.width, height = image.height
        var grey = [UInt8](repeating: 0, count: width * height)
        grey.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var total = 0.0, count = 0
        for row in Int(y.lowerBound * Double(height))..<Int(y.upperBound * Double(height)) {
            for column in Int(x.lowerBound * Double(width))..<Int(x.upperBound * Double(width)) - 1 {
                total += abs(Double(grey[row * width + column]) - Double(grey[row * width + column + 1]))
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// The colour at a point given as fractions of the width and height from the top-left.
    private static func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
            context.draw(image, in: CGRect(x: -px, y: -py, width: Double(image.width), height: Double(image.height)))
        }
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw CocoaError(.featureUnsupported)
        }
        return buffer
    }

    // MARK: - Checking the result

    private static func report(_ url: URL, expectedSeconds: Double) async throws -> Int32 {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var lines = ["\(url.path)", String(format: "duration %.2f s", duration)]
        var ok = abs(duration - expectedSeconds) < 0.5

        for track in try await asset.load(.tracks) {
            let formats = try await track.load(.formatDescriptions)
            let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            let range = try await track.load(.timeRange)
            var line = "\(track.mediaType.rawValue) \(codec)"
            if track.mediaType == .video {
                let size = try await track.load(.naturalSize)
                let rate = try await track.load(.nominalFrameRate)
                line += String(format: " %d×%d %.1f fps", Int(size.width), Int(size.height), rate)
            }
            line += String(format: " %.2f–%.2f s", range.start.seconds, range.end.seconds)
            lines.append(line)
            ok = ok && range.duration.seconds > expectedSeconds - 0.5
        }
        let kinds = Set(try await asset.load(.tracks).map(\.mediaType))
        print(lines.joined(separator: "\n"))
        if !kinds.contains(.video) { ok = false }
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    private static func noAccess(_ permission: String) -> Int32 {
        fail("the app that launched this has no \(permission) access, so nothing was recorded")
        return 2
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - Synthetic media

    /// A grey frame in the 4:2:0 layout ScreenCaptureKit delivers, with a white bar at `progress` across.
    private static func testPattern(width: Int, height: Int, progress: Double) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw MovieWriter.WriterError.failed(nil) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let barStart = Int(progress * Double(width - 80))
        for y in 0..<height {
            let row = luma + y * lumaStride
            memset(row, 90, width)
            memset(row + barStart, 235, 80)
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    /// `count` samples of a 440 Hz sine in the microphone's 48 kHz mono float format.
    private static func tone(firstSample: Int, count: Int, at time: CMTime) throws -> CMSampleBuffer {
        let description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let format = try CMAudioFormatDescription(audioStreamBasicDescription: description)

        let samples = (0..<count).map { Float(0.2 * sin(2 * Double.pi * 440 * Double(firstSample + $0) / 48_000)) }
        let bytes = count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { throw MovieWriter.WriterError.failed(nil) }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: count, presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw MovieWriter.WriterError.failed(nil) }
        return sampleBuffer
    }
}
