import AVFoundation

/// Encodes screen frames as H.264 and microphone audio as AAC into an .mp4 (the same two codecs
/// Loom's recorder produces). Not thread-safe: call every method from one serial queue.
///
/// Samples arrive stamped with host time. The writer turns that into movie time: nothing before
/// the requested start (the countdown) is kept, and paused stretches are cut out with everything
/// after them shifted back to close the gap, as Loom's `TimeShiftOnPauseFilter` does.
final class MovieWriter {
    enum WriterError: LocalizedError {
        case noFrames
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "No screen frames were captured."
            case .failed(let error): return error?.localizedDescription ?? "The movie file could not be written."
            }
        }
    }

    /// What the microphone is asked to deliver: 48 kHz mono float PCM, matching the AAC track below.
    static let microphonePCMSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let frames: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let frameDuration: CMTime
    /// Host time the movie should start at, or nil to start with the first frame.
    private let requestedStart: CMTime?
    /// The newest frame from before `requestedStart`: what's on screen when the movie begins.
    private var pendingFrame: CVPixelBuffer?
    /// Paused stretches in host time, oldest first. Only the last may still be open.
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    private var startTime: CMTime?
    /// The latest host time already written, so a pause can't reach back into it.
    private var writtenUntil = CMTime.invalid
    private var lastFrameTime = CMTime.invalid
    private var lastFrame: CVPixelBuffer?
    private var audioEnd = CMTime.invalid
    private var isFinishing = false

    /// `bitsPerPixel` sets the average bitrate: about 0.1 per pixel per frame suits screen content
    /// (static screens cost far less), and a camera picture wants about twice that.
    /// `audioChannels` is 0 for no sound, 1 for the microphone alone, 2 for the mic and computer sound mixed.
    /// With `fillingFrame`, frames of another shape are scaled to fill the movie and cut to it from
    /// their middle, so a camera picture can be recorded square or portrait.
    init(url: URL, width: Int, height: Int, frameRate: Int, bitsPerPixel: Double = 0.1, audioChannels: Int,
         fillingFrame: Bool = false, startingAt requestedStart: CMTime? = nil) throws {
        self.url = url
        self.requestedStart = requestedStart
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let bitrate = min(max(Int(Double(width * height * frameRate) * bitsPerPixel), 2_000_000), 24_000_000)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        if fillingFrame { settings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw WriterError.failed(writer.error) }
        writer.add(video)

        if audioChannels > 0 {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: min(audioChannels, 2),
                AVEncoderBitRateKey: audioChannels > 1 ? 192_000 : 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw WriterError.failed(writer.error) }
            writer.add(audio)
            self.audio = audio
        } else {
            audio = nil
        }

        guard writer.startWriting() else { throw WriterError.failed(writer.error) }
    }

    // MARK: - Samples

    /// Frames arriving while the encoder is busy are dropped.
    func appendFrame(_ pixelBuffer: CVPixelBuffer, at hostTime: CMTime) {
        guard !isFinishing, writer.status == .writing else { return }
        if let requestedStart, hostTime < requestedStart {
            pendingFrame = pixelBuffer
            return
        }
        let (time, paused) = movieTime(for: hostTime)
        guard !paused else { return }
        if startTime == nil { begin(at: pendingFrame == nil ? time : requestedStart ?? time) }
        if lastFrameTime.isValid, time <= lastFrameTime { return }
        guard video.isReadyForMoreMediaData, frames.append(pixelBuffer, withPresentationTime: time) else { return }
        lastFrameTime = time
        lastFrame = pixelBuffer
        written(until: hostTime)
    }

    /// `sampleBuffer` must already be stamped with host time, like the frames. Audio from before
    /// the movie starts, from paused stretches, or overlapping what's written (after a mic
    /// switch) is dropped.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing, writer.status == .writing, let audio else { return }
        let hostTime = sampleBuffer.presentationTimeStamp
        if startTime == nil, let requestedStart, hostTime >= requestedStart, pendingFrame != nil {
            begin(at: requestedStart)
        }
        let (time, paused) = movieTime(for: hostTime)
        guard !paused, let startTime, time >= startTime, audio.isReadyForMoreMediaData else { return }
        if audioEnd.isValid, time < audioEnd - CMTime(value: 1, timescale: 1000) { return }
        guard let shifted = sampleBuffer.shifted(by: time - hostTime), audio.append(shifted) else { return }
        audioEnd = time + sampleBuffer.duration
        written(until: hostTime + sampleBuffer.duration)
    }

    private func written(until hostTime: CMTime) {
        writtenUntil = writtenUntil.isValid ? CMTimeMaximum(writtenUntil, hostTime) : hostTime
    }

    /// Starts the movie at the requested start time even if the screen hasn't changed since,
    /// using the frame that was showing. Called when the countdown reaches zero.
    func beginAtRequestedStart() {
        guard !isFinishing, startTime == nil, let requestedStart, pendingFrame != nil, writer.status == .writing else { return }
        begin(at: requestedStart)
    }

    private func begin(at time: CMTime) {
        writer.startSession(atSourceTime: time)
        startTime = time
        if let pendingFrame, video.isReadyForMoreMediaData, frames.append(pendingFrame, withPresentationTime: time) {
            lastFrameTime = time
            lastFrame = pendingFrame
        }
        pendingFrame = nil
    }

    // MARK: - Pausing

    /// Pauses from `hostTime`, or from the end of what's already written if that's later. Samples
    /// already in the file can't be taken back, and cutting before them would freeze the picture
    /// after resuming until the movie caught up.
    func pause(at hostTime: CMTime) {
        if let last = pauses.last, last.end == nil { return }   // already paused
        pauses.append((writtenUntil.isValid ? CMTimeMaximum(hostTime, writtenUntil) : hostTime, nil))
    }

    func resume(at hostTime: CMTime) {
        guard let last = pauses.last, last.end == nil else { return }
        pauses[pauses.count - 1].end = CMTimeMaximum(hostTime, last.start)
    }

    /// Where `hostTime` lands in the movie once paused stretches are cut out. A time inside a pause
    /// lands where that pause began, and is reported as paused.
    private func movieTime(for hostTime: CMTime) -> (time: CMTime, paused: Bool) {
        var cut = CMTime.zero
        for pause in pauses where hostTime >= pause.start {
            guard let end = pause.end, hostTime >= end else { return (pause.start - cut, true) }
            cut = cut + (end - pause.start)
        }
        return (hostTime - cut, false)
    }

    // MARK: - Finishing

    /// Ends the movie at host time `endTime` and writes the file. Anything appended after it is cut.
    func finish(at endTime: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
        if startTime == nil, let requestedStart, endTime > requestedStart { beginAtRequestedStart() }
        isFinishing = true
        guard let startTime, let lastFrame, writer.status == .writing else {
            let error = writer.status == .failed ? WriterError.failed(writer.error) : WriterError.noFrames
            cancel()
            completion(.failure(error))
            return
        }
        let end = CMTimeMaximum(movieTime(for: endTime).time, startTime + frameDuration)
        // A frame lasts until the next one, so the last real frame needs a successor to stay on
        // screen until `end`. Repeat it there; the session ends at that instant, so it adds no frame.
        if end > lastFrameTime, video.isReadyForMoreMediaData {
            frames.append(lastFrame, withPresentationTime: end)
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.endSession(atSourceTime: end)
        writer.finishWriting { [writer, url] in
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(WriterError.failed(writer.error)))
            }
        }
    }

    /// Throws the recording away and deletes the file.
    func cancel() {
        isFinishing = true
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

extension CMSampleBuffer {
    /// A copy with every timestamp moved by `offset`. Returns self when there is nothing to move.
    func shifted(by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return self }
        guard var timing = try? sampleTimingInfos() else { return nil }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + offset
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + offset
            }
        }
        return try? CMSampleBuffer(copying: self, withNewTiming: timing)
    }
}
