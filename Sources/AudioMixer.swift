import AVFoundation

/// Mixes the microphone and the computer's sound into one 48 kHz stereo stream for the movie, first
/// removing the computer's sound from the microphone (echo cancellation), so speakers can be used
/// instead of headphones.
///
/// Most players, and most websites a movie might be uploaded to, only play a file's first audio
/// track, so the two are mixed into one rather than written side by side.
///
/// Both sources arrive in small buffers stamped with host time, from different capture sessions
/// and slightly out of step. Each buffer is placed in its source's timeline at the sample its
/// timestamp falls on. The mix is worked out a fixed delay behind real time, so whatever has
/// arrived by then is in it, and a source that sends nothing (silence, or a stall) contributes
/// silence. It's done in WebRTC's 10 ms blocks: for each, the echo canceller is given what the
/// computer played, then cleans the microphone, then the two are added together.
/// Not thread-safe: use from one serial queue.
final class AudioMixer {
    enum Source: Hashable { case microphone, computer }

    static let sampleRate = 48_000.0
    /// How far behind real time the mix is worked out, so both sources' buffers have arrived.
    static let delay = CMTime(value: 150, timescale: 1000)
    /// WebRTC's block: 10 ms.
    static let blockFrames = Int(sampleRate) / 100
    /// The echo canceller is shown the computer's sound this far ahead (4 blocks, 40 ms) of the mic it
    /// cleans. It can only remove echo that comes after the sound that caused it. The mic's and the
    /// computer's timestamps come from different clocks, so this keeps it working even if the
    /// computer's sound is stamped up to 40 ms late. The mix itself stays aligned.
    static let lookaheadBlocks = 4
    /// A buffer stamped within this many frames (5 ms) of where its source's last one ended is
    /// treated as continuing it, so timestamp jitter doesn't leave gaps or overlaps that click.
    private static let snapFrames: Int64 = 240

    private let origin: CMTime
    private let format: CMAudioFormatDescription
    private let echoCanceller: EchoCanceller?
    /// The first frame not yet mixed, and each source's samples from there on.
    private var baseFrame: Int64 = 0
    private var microphone: [Float] = []
    private var computerLeft: [Float] = []
    private var computerRight: [Float] = []
    private var nextFrame: [Source: Int64] = [:]

    /// `origin` is the host time of the mix's first sample. With `cancelEcho`, the computer's sound
    /// is removed from the microphone before mixing.
    init(origin: CMTime, cancelEcho: Bool) throws {
        self.origin = origin
        format = try CMAudioFormatDescription(audioStreamBasicDescription: AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
        echoCanceller = cancelEcho ? EchoCanceller(sampleRate: Int(Self.sampleRate)) : nil
    }

    /// Whether echo cancellation is running (it was asked for and WebRTC started).
    var isCancellingEcho: Bool { echoCanceller != nil }

    /// Adds a buffer of 48 kHz float audio heard at host time `time`. The computer's sound keeps its
    /// two sides (a mono buffer goes to both); the microphone is mono. Anything that isn't 48 kHz
    /// float PCM is ignored.
    func add(_ sampleBuffer: CMSampleBuffer, from source: Source, at time: CMTime) {
        guard let channels = Self.channels(of: sampleBuffer), let left = channels.first, !left.isEmpty else { return }
        let right = channels.count > 1 ? channels[1] : left
        let frames = Int64(left.count)

        var position = Int64(((time - origin).seconds * Self.sampleRate).rounded())
        if let expected = nextFrame[source], abs(position - expected) <= Self.snapFrames { position = expected }
        nextFrame[source] = position + frames

        let skip = max(0, baseFrame - position)   // the part already mixed is too late to use
        guard skip < frames else { return }
        let needed = Int(position + frames - baseFrame)
        let offset = Int(position - baseFrame)
        switch source {
        case .microphone:
            Self.grow(&microphone, to: needed)
            for frame in Int(skip)..<Int(frames) { microphone[offset + frame] = left[frame] }
        case .computer:
            Self.grow(&computerLeft, to: needed)
            Self.grow(&computerRight, to: needed)
            for frame in Int(skip)..<Int(frames) {
                computerLeft[offset + frame] = left[frame]
                computerRight[offset + frame] = right[frame]
            }
        }
    }

    /// The mix up to host time `time`, stamped with host time, ready for the writer. With `flush`,
    /// the last part shorter than a block is included too.
    func drain(upTo time: CMTime, flush: Bool = false) -> [CMSampleBuffer] {
        let end = Int64(((time - origin).seconds * Self.sampleRate).rounded(.down))
        let start = origin + CMTime(value: baseFrame, timescale: CMTimeScale(Self.sampleRate))
        var mixed: [Float] = []
        while end - baseFrame >= Int64(Self.blockFrames) || (flush && end > baseFrame) {
            let frames = Int(min(Int64(Self.blockFrames), end - baseFrame))
            // WebRTC always takes whole blocks, so a short last block is padded with silence.
            if let echoCanceller {
                let ahead = Self.lookaheadBlocks * Self.blockFrames
                echoCanceller.process(farLeft: Self.peek(computerLeft, at: ahead), farRight: Self.peek(computerRight, at: ahead),
                                      microphone: &microphone)
            }
            let voice = Self.take(&microphone, frames)
            let left = Self.take(&computerLeft, frames)
            let right = Self.take(&computerRight, frames)
            for frame in 0..<frames {
                mixed.append(Self.softClip(voice[frame] + left[frame]))
                mixed.append(Self.softClip(voice[frame] + right[frame]))
            }
            baseFrame += Int64(frames)
        }
        guard !mixed.isEmpty, let buffer = makeBuffer(mixed, frames: mixed.count / 2, at: start) else { return [] }
        return [buffer]
    }

    /// The first block of `samples` (padded with silence to a whole block), removing `frames` of them.
    private static func take(_ samples: inout [Float], _ frames: Int) -> [Float] {
        var block = Array(samples.prefix(blockFrames))
        if block.count < blockFrames { block.append(contentsOf: repeatElement(0, count: blockFrames - block.count)) }
        samples.removeFirst(min(samples.count, frames))
        return block
    }

    /// One block of `samples` starting at `offset`, padded with silence past the end.
    private static func peek(_ samples: [Float], at offset: Int) -> [Float] {
        let available = max(0, min(blockFrames, samples.count - offset))
        var block = available > 0 ? Array(samples[offset..<offset + available]) : []
        block.append(contentsOf: repeatElement(0, count: blockFrames - available))
        return block
    }

    private static func grow(_ samples: inout [Float], to count: Int) {
        if samples.count < count { samples.append(contentsOf: repeatElement(0, count: count - samples.count)) }
    }

    /// Leaves quiet and normal levels alone and rounds off peaks smoothly below full scale, so the
    /// computer's sound and a voice together can't hard-clip.
    static func softClip(_ sample: Float) -> Float {
        let knee: Float = 0.8
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let rounded = knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))
        return sample < 0 ? -rounded : rounded
    }

    /// Each channel's samples from a 32-bit float PCM buffer, interleaved or not.
    static func channels(of sampleBuffer: CMSampleBuffer) -> [[Float]]? {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32,
              abs(description.mSampleRate - sampleRate) < 1 else { return nil }
        let channelCount = max(1, Int(description.mChannelsPerFrame))
        let nonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        return try? sampleBuffer.withAudioBufferList { list, _ -> [[Float]] in
            if nonInterleaved {
                return list.map { buffer in
                    guard let data = buffer.mData else { return [] }
                    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                     count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
                }
            }
            guard let buffer = list.first, let data = buffer.mData else { return [] }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                              count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            let frames = samples.count / channelCount
            return (0..<channelCount).map { channel in (0..<frames).map { samples[$0 * channelCount + channel] } }
        }
    }

    private func makeBuffer(_ samples: [Float], frames: Int, at time: CMTime) -> CMSampleBuffer? {
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer
    }
}

/// WebRTC's echo canceller, AEC3 (see Native/EchoCanceller.cpp): the one Loom's recorder links.
/// It learns how the computer's sound reaches the microphone (the speakers, the room, the delay)
/// and subtracts it, leaving your voice.
final class EchoCanceller {
    private let handle: OpaquePointer

    init?(sampleRate: Int) {
        guard let handle = myloom_echo_create(Int32(sampleRate)) else { return nil }
        self.handle = handle
    }

    deinit {
        myloom_echo_destroy(handle)
    }

    /// One 10 ms block: what the speakers played, then the microphone's first block, which is
    /// cleaned in place (padded with silence first if it's shorter than a block).
    func process(farLeft: [Float], farRight: [Float], microphone: inout [Float]) {
        farLeft.withUnsafeBufferPointer { left in
            farRight.withUnsafeBufferPointer { right in
                _ = myloom_echo_far_end(handle, left.baseAddress, right.baseAddress)
            }
        }
        let block = AudioMixer.blockFrames
        if microphone.count < block { microphone.append(contentsOf: repeatElement(0, count: block - microphone.count)) }
        microphone.withUnsafeMutableBufferPointer { _ = myloom_echo_near_end(handle, $0.baseAddress) }
    }
}
