import AppKit
import AVFoundation

let arguments = CommandLine.arguments

/// `MyLoom --selftest out.mp4` encodes 3 s of a moving test pattern and a tone through the same
/// MovieWriter the app uses, then checks the file. Needs no permissions.
if let flag = arguments.firstIndex(of: "--selftest"), flag + 1 < arguments.count {
    let output = URL(fileURLWithPath: arguments[flag + 1])
    Task.detached { exit(await SelfTest.writer(output: output)) }
    dispatchMain()
}

/// `MyLoom --record-test out.mp4 [seconds] [x,y,width,height | window | camera] [--computer-sound] [--mic name]`
/// records through the real recorder: the main display, an area of it (points from its top-left), the
/// frontmost window, or the camera alone, optionally with the computer's sound mixed in. Permissions
/// belong to whichever app launched it, such as Terminal.
if let flag = arguments.firstIndex(of: "--record-test"), flag + 1 < arguments.count {
    let output = URL(fileURLWithPath: arguments[flag + 1])
    let seconds = flag + 2 < arguments.count ? Double(arguments[flag + 2]) ?? 3 : 3
    var target = SelfTest.CaptureTarget.display(area: nil)
    if flag + 3 < arguments.count {
        let choice = arguments[flag + 3]
        let numbers = choice.split(separator: ",").compactMap { Double($0) }
        if choice == "window" {
            target = .frontWindow
        } else if choice == "camera" {
            target = .camera
        } else if numbers.count == 4 {
            target = .display(area: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        }
    }
    _ = NSApplication.shared
    let computerSound = arguments.contains("--computer-sound")
    let microphoneName = arguments.firstIndex(of: "--mic").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    Task.detached { [target] in exit(await SelfTest.capture(output: output, seconds: seconds, target: target, computerSound: computerSound,
                                                               microphoneName: microphoneName)) }
    dispatchMain()
}

/// `MyLoom --share-test movie.mp4 https://project.supabase.co publicKey email password` shares a
/// movie through the real sharing code and checks every step (see SelfTest.share).
/// `MyLoom --share-test movie.mp4 --stored` does the same with the project and sign-in saved by
/// Sharing Setup; run it through `open` so it can read MyLoom's keychain item.
if let flag = arguments.firstIndex(of: "--share-test"), flag + 2 < arguments.count {
    let movie = URL(fileURLWithPath: arguments[flag + 1])
    var details: (project: URL?, key: String?, email: String?, password: String?) = (nil, nil, nil, nil)
    if arguments[flag + 2] != "--stored" {
        guard flag + 5 < arguments.count, let project = URL(string: arguments[flag + 2]) else {
            print("usage: --share-test movie.mp4 (projectURL publicKey email password | --stored)")
            exit(2)
        }
        details = (project, arguments[flag + 3], arguments[flag + 4], arguments[flag + 5])
    }
    let given = details
    Task.detached {
        exit(await SelfTest.share(movie: movie, project: given.project, key: given.key, email: given.email, password: given.password))
    }
    dispatchMain()
}

/// `MyLoom --test-movie out.mp4 seconds` writes a neutral moving test pattern with a tone.
if let flag = arguments.firstIndex(of: "--test-movie"), flag + 2 < arguments.count, let seconds = Double(arguments[flag + 2]) {
    let output = URL(fileURLWithPath: arguments[flag + 1])
    Task.detached { exit(await SelfTest.testMovie(output: output, seconds: seconds)) }
    dispatchMain()
}

/// `MyLoom --upload-test megabytes` uploads that much random data with the saved sign-in, checks the
/// link serves it all, then deletes it. Run it through `open`, as for --list-devices.
if let flag = arguments.firstIndex(of: "--upload-test"), flag + 1 < arguments.count, let megabytes = Int(arguments[flag + 1]) {
    Task.detached { exit(await SelfTest.bigUpload(megabytes: megabytes)) }
    dispatchMain()
}

/// `MyLoom --keychain-probe` says whether MyLoom can read its saved Supabase sign-in (never printing
/// it), and with what result code. Run it through `open`, as for --list-devices.
if arguments.contains("--keychain-probe") {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.myloom",
        kSecAttrAccount as String: "supabase-session",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ] as CFDictionary, &result)
    let session = (result as? Data).flatMap { try? JSONDecoder().decode(Supabase.Session.self, from: $0) }
    print("read status \(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "?")); decodes: \(session != nil)")
    if let session { print("signed in as \(session.email), access token valid until \(session.expiresAt)") }
    exit(0)
}

/// `MyLoom --render-ui folder` draws the Custom Size overlay into PNGs, to check its layout.
if let flag = arguments.firstIndex(of: "--render-ui"), flag + 1 < arguments.count {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated { SelfTest.renderUI(to: URL(fileURLWithPath: arguments[flag + 1])) })
}

/// `MyLoom --effects-test photo.jpg folder` shows a photo in the camera bubble with each background
/// effect and saves what's on screen as PNGs. Needs Screen Recording access, not the camera.
if let flag = arguments.firstIndex(of: "--effects-test"), flag + 2 < arguments.count {
    let photo = URL(fileURLWithPath: arguments[flag + 1]), folder = URL(fileURLWithPath: arguments[flag + 2])
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await SelfTest.effects(photo: photo, folder: folder)) }
    NSApplication.shared.run()
}

/// `MyLoom --drawing-test folder` draws with the real mouse while recording and checks the movies.
/// Needs Screen Recording and Accessibility. It covers the main display with grey for ~12 s.
if let flag = arguments.firstIndex(of: "--drawing-test"), flag + 1 < arguments.count {
    let folder = URL(fileURLWithPath: arguments[flag + 1])
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await SelfTest.drawing(folder: folder)) }
    NSApplication.shared.run()
}

/// `MyLoom --list-devices` prints the cameras and microphones macOS offers MyLoom, and its permissions.
/// Run it through `open` so it asks as MyLoom rather than as Terminal:
/// `open -W --stdout /tmp/devices.txt build/MyLoom.app --args --list-devices`
if arguments.contains("--list-devices") {
    func access(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "allowed"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
    print("Camera access: \(access(AVCaptureDevice.authorizationStatus(for: .video)))")
    print("Microphone access: \(access(AVCaptureDevice.authorizationStatus(for: .audio)))")
    print("Screen Recording access: \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed")")
    print("Cameras:")
    for camera in Devices.cameras() { print("  \(camera.localizedName)  [\(camera.deviceType.rawValue)]") }
    print("  macOS's preferred camera: \(AVCaptureDevice.systemPreferredCamera?.localizedName ?? "none")")
    print("Microphones:")
    for microphone in Devices.microphones() { print("  \(microphone.localizedName)  [\(microphone.deviceType.rawValue)]") }
    print("  default: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")")
    exit(0)
}

/// `MyLoom --mic-probe name` listens to a microphone for a moment twice, in its own format and in the
/// format MyLoom records, and prints the level and format of each. Run it through `open`, as for --list-devices.
if let flag = arguments.firstIndex(of: "--mic-probe"), flag + 1 < arguments.count {
    let name = arguments[flag + 1]
    guard let device = Devices.microphones().first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) else {
        print("no microphone matching \(name)")
        exit(1)
    }
    final class Probe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        var sum = 0.0, count = 0, peak: Float = 0, format = ""
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if let description = sampleBuffer.formatDescription?.audioStreamBasicDescription, format.isEmpty {
                let float = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                format = "\(Int(description.mSampleRate)) Hz, \(description.mChannelsPerFrame) ch, \(description.mBitsPerChannel)-bit \(float ? "float" : "integer")"
            }
            if let channels = AudioMixer.channels(of: sampleBuffer) {
                for sample in channels.joined() { sum += Double(sample * sample); peak = max(peak, abs(sample)); count += 1 }
            } else if let description = sampleBuffer.formatDescription?.audioStreamBasicDescription, description.mBitsPerChannel == 16,
                      let block = sampleBuffer.dataBuffer {
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                pointer?.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                    for index in 0..<(length / 2) {
                        let sample = Float(samples[index]) / 32768
                        sum += Double(sample * sample); peak = max(peak, abs(sample)); count += 1
                    }
                }
            }
        }
    }
    print("microphone: \(device.localizedName)")
    for settings in [nil, MovieWriter.microphonePCMSettings] as [[String: Any]?] {
        let session = AVCaptureSession()
        let probe = Probe()
        let output = AVCaptureAudioDataOutput()
        if let settings { output.audioSettings = settings }
        let queue = DispatchQueue(label: "probe")
        output.setSampleBufferDelegate(probe, queue: queue)
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input), session.canAddOutput(output) else {
            print("couldn't open it"); exit(1)
        }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        // Measure the last 2 seconds of 5, so a device that takes a moment to wake up isn't judged early.
        Thread.sleep(forTimeInterval: 3)
        queue.sync { probe.sum = 0; probe.count = 0; probe.peak = 0 }
        Thread.sleep(forTimeInterval: 2)
        session.stopRunning()
        queue.sync {}
        let rms = probe.count > 0 ? (probe.sum / Double(probe.count)).squareRoot() : 0
        print(String(format: "%@: %@; %d samples, level %.1f dBFS, peak %.1f dBFS", settings == nil ? "own format" : "MyLoom's format",
                     probe.format, probe.count,
                     20 * log10(max(rms, 1e-9)), 20 * log10(max(Double(probe.peak), 1e-9))))
    }
    exit(0)
}

/// `MyLoom --continuity-probe` holds the iPhone camera open and tries reading the iPhone microphone at
/// the same time three ways, printing what each one hears. Run it through `open`, as for --list-devices.
if arguments.contains("--continuity-probe") {
    guard let camera = Devices.cameras().first(where: { $0.deviceType == .continuityCamera }),
          let microphone = Devices.microphones().first(where: { $0.localizedName.localizedCaseInsensitiveContains("iPhone") }) else {
        print("no iPhone camera or microphone"); exit(1)
    }
    final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
        var frames = 0, samples = 0, sum = 0.0
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if output is AVCaptureVideoDataOutput { frames += 1; return }
            for sample in (AudioMixer.channels(of: sampleBuffer) ?? []).joined() { sum += Double(sample * sample); samples += 1 }
        }
        func report(_ label: String) {
            let rms = samples > 0 ? (sum / Double(samples)).squareRoot() : 0
            print(String(format: "%@: %d camera frames, %d mic samples, mic level %.1f dBFS", label, frames, samples, 20 * log10(max(rms, 1e-9))))
            frames = 0; samples = 0; sum = 0
        }
    }
    let queue = DispatchQueue(label: "probe")
    let counter = Counter()
    func audioOutput() -> AVCaptureAudioDataOutput {
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = MovieWriter.microphonePCMSettings
        output.setSampleBufferDelegate(counter, queue: queue)
        return output
    }
    let cameraSession = AVCaptureSession()
    let video = AVCaptureVideoDataOutput()
    video.setSampleBufferDelegate(counter, queue: queue)
    cameraSession.addInput(try! AVCaptureDeviceInput(device: camera))
    cameraSession.addOutput(video)
    cameraSession.startRunning()
    Thread.sleep(forTimeInterval: 2)
    queue.sync { counter.report("camera alone") }

    // As in the app: a short session on the mic (the menu's meter) ends just as the recording's
    // own session starts, first after a full stop, then overlapping.
    func micSession(_ counter: Counter) -> AVCaptureSession {
        let session = AVCaptureSession()
        session.addInput(try! AVCaptureDeviceInput(device: microphone))
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = MovieWriter.microphonePCMSettings
        output.setSampleBufferDelegate(counter, queue: queue)
        session.addOutput(output)
        return session
    }
    let meterCounter = Counter(), recordCounter = Counter()
    let meter = micSession(meterCounter)
    meter.startRunning()
    Thread.sleep(forTimeInterval: 3)
    meter.stopRunning()
    queue.sync { meterCounter.report("1a. first mic session (the meter)") }
    let recording = micSession(recordCounter)
    recording.startRunning()
    Thread.sleep(forTimeInterval: 4)
    recording.stopRunning()
    queue.sync { recordCounter.report("1b. next mic session after it fully stopped") }

    let meter2 = micSession(meterCounter)
    meter2.startRunning()
    Thread.sleep(forTimeInterval: 3)
    let stopper = DispatchQueue(label: "meter")
    stopper.async { meter2.stopRunning() }   // stopped on another queue, as the meter does
    let recording2 = micSession(recordCounter)
    recording2.startRunning()
    Thread.sleep(forTimeInterval: 4)
    recording2.stopRunning()
    queue.sync { meterCounter.report("1c. meter session"); recordCounter.report("1d. recording session started while the meter was stopping") }

    // 3. The microphone through CoreAudio (AVAudioEngine), the camera still running.
    let engine = AVAudioEngine()
    var deviceID = AudioDeviceID(0)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid = microphone.uniqueID as CFString
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), &uid, &size, &deviceID)
    if let unit = engine.inputNode.audioUnit {
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
    let format = engine.inputNode.outputFormat(forBus: 0)
    var engineSamples = 0, engineSum = 0.0
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let data = buffer.floatChannelData?[0] else { return }
        queue.async { for index in 0..<Int(buffer.frameLength) { engineSum += Double(data[index] * data[index]) }; engineSamples += Int(buffer.frameLength) }
    }
    do { try engine.start() } catch { print("AVAudioEngine couldn't start: \(error)") }
    Thread.sleep(forTimeInterval: 4)
    engine.stop()
    queue.sync {
        let rms = engineSamples > 0 ? (engineSum / Double(engineSamples)).squareRoot() : 0
        print(String(format: "3. mic through CoreAudio (device %d, %.0f Hz): %d samples, level %.1f dBFS, camera frames meanwhile %d",
                     deviceID, format.sampleRate, engineSamples, 20 * log10(max(rms, 1e-9)), counter.frames))
    }
    cameraSession.stopRunning()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
