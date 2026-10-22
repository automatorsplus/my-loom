import AppKit
import AVFoundation

/// Listens to one microphone and reports how loud it is, for the level meter in the menu.
///
/// Loom has the same thing: its `MicrophoneLevelMonitor` reads `AVCaptureAudioChannel`'s
/// `averagePowerLevel`, smooths it (`SmoothedMicrophoneLevel`) and warns "No audio detected".
/// This one measures the samples itself, in the same 48 kHz mono format the recorder uses, so the
/// meter shows exactly what a recording would get.
final class MicrophoneMeter: NSObject {
    enum Status {
        case starting   // no sound has arrived yet
        case hearing    // speech-level sound within the last moment
        case quiet      // nothing loud right now, but no reason to worry yet
        case noAudio    // nothing speech-level since listening began
    }

    struct Reading {
        /// 0…1 for the bar: fast to rise, slower to fall, like a hardware meter.
        var level: Double
        /// 0…1, the loudest moment of the last second or so.
        var peak: Double
        var status: Status
    }

    /// The bar is empty at this level (dBFS) and below; 0 dBFS fills it.
    static let floor: Double = -60
    /// Speech near a microphone is usually around −35 to −15 dBFS; a quiet room sits well below this.
    static let speechThreshold: Double = -45
    /// How long a microphone can stay silent before the meter warns, as Loom's "No audio detected" does.
    static let silenceWarning: TimeInterval = 3

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "MyLoom.meter")
    private let lock = NSLock()
    // Written on `queue` by `ingest`, read on the main thread by `reading`; guarded by `lock`.
    private var latest: (rms: Double, peak: Double, at: TimeInterval)?
    private var lastHeardAt: TimeInterval?
    // Main thread only.
    private var startedAt: TimeInterval = 0
    private var shown = Reading(level: 0, peak: 0, status: .starting)
    private var shownAt: TimeInterval?
    private var peakHeldAt: TimeInterval = 0

    /// The microphone being listened to, or nil when stopped.
    private(set) var device: AVCaptureDevice?

    /// Starts listening to `device`, or switches to it. Call on the main thread.
    func listen(to device: AVCaptureDevice) {
        guard device.uniqueID != self.device?.uniqueID else { return }
        self.device = device
        begin(at: ProcessInfo.processInfo.systemUptime)
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if session.outputs.isEmpty {
                let output = AVCaptureAudioDataOutput()
                output.audioSettings = MovieWriter.microphonePCMSettings
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        device = nil
        queue.async { [session] in session.stopRunning() }
    }

    /// Forgets everything heard, as when a different microphone is chosen.
    func begin(at time: TimeInterval) {
        lock.lock()
        latest = nil
        lastHeardAt = nil
        lock.unlock()
        startedAt = time
        shown = Reading(level: 0, peak: 0, status: .starting)
        shownAt = nil
        peakHeldAt = time
    }

    /// The meter as it should look at `now`. Call on the main thread, about 30 times a second.
    func reading(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Reading {
        lock.lock()
        let latest = self.latest
        let lastHeardAt = self.lastHeardAt
        lock.unlock()

        // Sound older than half a second means the microphone has gone quiet or stopped sending.
        let fresh = latest.flatMap { now - $0.at < 0.5 ? $0 : nil }
        let target = fresh.map { Self.fraction($0.rms) } ?? 0
        let peakTarget = fresh.map { Self.fraction($0.peak) } ?? 0
        let elapsed = shownAt.map { max(0, now - $0) } ?? 0
        shownAt = now

        var reading = shown
        // Rise at once; fall from full to empty in about 0.6 s.
        reading.level = target >= shown.level ? target : max(target, shown.level - elapsed / 0.6)
        // Hold the peak for a second, then let it fall.
        if peakTarget >= shown.peak {
            reading.peak = peakTarget
            peakHeldAt = now
        } else if now - peakHeldAt > 1 {
            reading.peak = max(peakTarget, shown.peak - elapsed / 0.8)
        }

        if latest == nil, now - startedAt < Self.silenceWarning {
            reading.status = .starting
        } else if let lastHeardAt, now - lastHeardAt < 1.5 {
            reading.status = .hearing
        } else if lastHeardAt != nil || now - startedAt < Self.silenceWarning {
            reading.status = .quiet
        } else {
            reading.status = .noAudio
        }
        shown = reading
        return reading
    }

    /// Takes one buffer of float samples heard at `time` (seconds of system uptime).
    func ingest(_ samples: UnsafeBufferPointer<Float>, at time: TimeInterval) {
        guard !samples.isEmpty else { return }
        let levels = Self.levels(of: samples)
        lock.lock()
        latest = (levels.rms, levels.peak, time)
        if levels.rms >= Self.speechThreshold { lastHeardAt = time }
        lock.unlock()
    }

    /// The RMS and peak of `samples`, in dBFS (−100 for silence).
    static func levels(of samples: UnsafeBufferPointer<Float>) -> (rms: Double, peak: Double) {
        var sumOfSquares: Double = 0
        var peak: Float = 0
        for sample in samples {
            sumOfSquares += Double(sample * sample)
            peak = max(peak, abs(sample))
        }
        func decibels(_ value: Double) -> Double { 20 * log10(max(value, 0.00001)) }
        return (decibels((sumOfSquares / Double(samples.count)).squareRoot()), decibels(Double(peak)))
    }

    /// Where `decibels` falls on the bar, 0…1.
    static func fraction(_ decibels: Double) -> Double {
        min(1, max(0, (decibels - floor) / -floor))
    }
}

extension MicrophoneMeter: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            ingest(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count), at: time)
        }
    }
}

/// The meter shown in the menu: which microphone, a bar that moves with your voice, and a word on
/// whether it's hearing you. It can also show a message instead, such as a permission prompt.
final class MicrophoneMeterView: NSView {
    enum Content {
        case live(name: String, reading: MicrophoneMeter.Reading)
        case message(String, color: NSColor)
    }

    static let size = NSSize(width: 310, height: 46)

    var content: Content = .message("", color: .secondaryLabelColor) {
        didSet { needsDisplay = true }
    }
    /// Called when the meter is clicked, for messages that offer to do something.
    var onClick: (() -> Void)?

    /// Lines up with the titles of ordinary menu items, past the tick column.
    private static let leftInset: CGFloat = 21
    private static let rightInset: CGFloat = 14

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width - Self.leftInset - Self.rightInset
        switch content {
        case .message(let text, let color):
            draw(text, size: 12, color: color, at: NSPoint(x: Self.leftInset, y: bounds.midY - 8), maxWidth: width)

        case .live(let name, let reading):
            var (status, statusColor) = Self.describe(reading.status)
            // Near clipping, say so: a mic gain set too high is worth fixing before recording.
            if reading.status == .hearing, reading.level > MicrophoneMeter.fraction(-6) {
                (status, statusColor) = ("Very loud", .systemRed)
            }
            let statusText = NSAttributedString(string: status, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: statusColor,
            ])
            let statusWidth = statusText.size().width
            statusText.draw(at: NSPoint(x: bounds.maxX - Self.rightInset - statusWidth, y: 25))
            draw("🎙 " + name, size: 12, color: .labelColor, at: NSPoint(x: Self.leftInset, y: 24),
                 maxWidth: width - statusWidth - 10)

            let track = NSRect(x: Self.leftInset, y: 10, width: width, height: 7)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
            if reading.level > 0.005 {
                let fill = NSRect(x: track.minX, y: track.minY, width: max(track.height, track.width * reading.level), height: track.height)
                Self.color(for: reading.level).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()
            }
            if reading.peak > 0.02 {
                let x = track.minX + track.width * reading.peak
                Self.color(for: reading.peak).setFill()
                NSRect(x: min(x, track.maxX - 2), y: track.minY - 2, width: 2, height: track.height + 4).fill()
            }
        }
    }

    private func draw(_ string: String, size: CGFloat, color: NSColor, at point: NSPoint, maxWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style,
        ]).draw(in: NSRect(x: point.x, y: point.y, width: maxWidth, height: size + 6))
    }

    private static func describe(_ status: MicrophoneMeter.Status) -> (String, NSColor) {
        switch status {
        case .starting: return ("Listening…", .secondaryLabelColor)
        case .hearing: return ("Picking you up", .systemGreen)
        case .quiet: return ("Say something to test", .secondaryLabelColor)
        case .noAudio: return ("No audio detected", .systemOrange)
        }
    }

    /// Green for normal speech, yellow when loud (above −18 dBFS), red near clipping (above −6 dBFS).
    private static func color(for fraction: Double) -> NSColor {
        if fraction > MicrophoneMeter.fraction(-6) { return .systemRed }
        if fraction > MicrophoneMeter.fraction(-18) { return .systemYellow }
        return .systemGreen
    }
}
