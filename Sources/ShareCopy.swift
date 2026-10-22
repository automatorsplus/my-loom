@preconcurrency import AVFoundation

/// Makes the copy of a recording that's uploaded for sharing: at most 1080p, H.264 at a bitrate
/// meant for streaming, AAC sound, laid out so it starts playing before it has fully downloaded.
/// A full-screen Retina recording can be several hundred MB for a few minutes; this brings ten
/// minutes down to about 200–250 MB. The original in ~/Movies is untouched.
enum ShareCopy {
    enum Failure: LocalizedError {
        case noVideo
        case couldNotRead(Error?)
        case couldNotWrite(Error?)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "The recording has no video track."
            case .couldNotRead(let error): return "Couldn't read the recording. \(error?.localizedDescription ?? "")"
            case .couldNotWrite(let error): return "Couldn't make the copy to share. \(error?.localizedDescription ?? "")"
            }
        }
    }

    /// Video bitrate: 3 Mbit/s at 1080p (screens, mostly still, look sharp at this; camera pictures fine),
    /// scaled by picture area for smaller recordings.
    private static func videoBitrate(width: Int, height: Int) -> Int {
        max(1_000_000, Int(3_000_000 * Double(width * height) / (1920 * 1080)))
    }

    /// Writes the copy to a new temporary file and returns it. `progress` gets 0 to 1.
    static func make(from source: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let natural = try await videoTrack.load(.naturalSize)
        let fit = min(1, 1920 / natural.width, 1080 / natural.height)
        let width = max(2, Int(natural.width * fit) & ~1), height = max(2, Int(natural.height * fit) & ~1)

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("MyLoom share \(UUID().uuidString).mp4")
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw Failure.couldNotRead(error)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = [(videoOut, videoIn)]
        if let audioTrack {
            let channels = (try? await audioTrack.load(.formatDescriptions).first?.audioStreamBasicDescription?.mChannelsPerFrame).flatMap { $0 } ?? 1
            let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(audioOut)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: Int(max(1, min(channels, 2))),
                AVEncoderBitRateKey: channels > 1 ? 160_000 : 96_000,
            ])
            audioIn.expectsMediaDataInRealTime = false
            writer.add(audioIn)
            pairs.append((audioOut, audioIn))
        }

        guard reader.startReading() else { throw Failure.couldNotRead(reader.error) }
        guard writer.startWriting() else { throw Failure.couldNotWrite(writer.error) }
        writer.startSession(atSourceTime: .zero)

        // Each track is copied on its own queue as fast as the encoder takes it.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, (from, to)) in pairs.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "MyLoom.share-copy.\(index)")
                var finished = false
                to.requestMediaDataWhenReady(on: queue) {
                    while to.isReadyForMoreMediaData, !finished {
                        guard let sample = from.copyNextSampleBuffer() else {
                            finished = true
                            to.markAsFinished()
                            group.leave()
                            return
                        }
                        if index == 0, duration > 0 {
                            progress(min(1, sample.presentationTimeStamp.seconds / duration))
                        }
                        if !to.append(sample) {
                            finished = true
                            to.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw Failure.couldNotRead(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.couldNotWrite(writer.error)
        }
        progress(1)
        return output
    }
}
