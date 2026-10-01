@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

public enum AirPlayAudioCodec: Equatable, Sendable {
    case pcm
    case alac
    case aacLC
    case aacELD
    case unsupported(UInt8)

    public init(compressionType: UInt8) {
        switch compressionType {
        case 1: self = .pcm
        case 2: self = .alac
        case 4: self = .aacLC
        case 8: self = .aacELD
        default: self = .unsupported(compressionType)
        }
    }
}

public struct DecodedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let presentationTimeNanoseconds: UInt64

    public init(buffer: AVAudioPCMBuffer, presentationTimeNanoseconds: UInt64) {
        self.buffer = buffer
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
    }
}

public struct AudioDecoderFailure: Error, Equatable, Sendable {
    public let status: OSStatus
    public let message: String

    public init(status: OSStatus, message: String) {
        self.status = status
        self.message = message
    }
}

public final class AirPlayAudioDecoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (DecodedAudioBuffer) -> Void
    public typealias FailureHandler = @Sendable (AudioDecoderFailure) -> Void

    private let queue = DispatchQueue(label: "com.classmirror.audio-decoder", qos: .userInteractive)
    private let outputHandler: OutputHandler
    private let failureHandler: FailureHandler
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var configuredCompressionType: UInt8?
    private var configuredSamplesPerFrame: UInt32 = 0
    private var newestAACELDRTPTime: UInt32?
    private var outputFrameCapacity: AVAudioFrameCount = 1_024

    public init(
        onOutput: @escaping OutputHandler,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        outputHandler = onOutput
        failureHandler = onFailure
    }

    public func configure(_ format: AudioFormatInfo) {
        queue.async { [self] in
            configureOnQueue(format)
        }
    }

    public func decode(_ sample: CompressedAudioSample) {
        queue.async { [self] in
            decodeOnQueue(sample)
        }
    }

    public func reset() {
        queue.async { [self] in
            resetOnQueue()
        }
    }

    public func finishPendingWork() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func configureOnQueue(_ format: AudioFormatInfo) {
        resetOnQueue()
        let codec = AirPlayAudioCodec(compressionType: format.compressionType)
        guard case .unsupported = codec else {
            var sourceDescription = sourceDescription(for: codec, format: format)
            var destinationDescription = Self.destinationDescription()
            if codec == .pcm {
                guard let outputFormat = AVAudioFormat(streamDescription: &destinationDescription) else {
                    failureHandler(AudioDecoderFailure(
                        status: OSStatus(paramErr),
                        message: "PCM 출력 형식을 만들지 못했습니다."
                    ))
                    return
                }
                self.outputFormat = outputFormat
                configuredCompressionType = format.compressionType
                outputFrameCapacity = AVAudioFrameCount(max(format.samplesPerFrame, 1_024))
                return
            }
            guard let inputFormat = AVAudioFormat(streamDescription: &sourceDescription),
                  let outputFormat = AVAudioFormat(streamDescription: &destinationDescription),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                failureHandler(AudioDecoderFailure(
                    status: OSStatus(paramErr),
                    message: "오디오 디코더를 시작하지 못했습니다."
                ))
                return
            }

            let cookie = magicCookie(for: codec)
            if !cookie.isEmpty {
                converter.magicCookie = cookie
            }
            self.converter = converter
            self.inputFormat = inputFormat
            self.outputFormat = outputFormat
            configuredCompressionType = format.compressionType
            configuredSamplesPerFrame = UInt32(format.samplesPerFrame)
            outputFrameCapacity = AVAudioFrameCount(max(format.samplesPerFrame, 1_024))
            return
        }

        failureHandler(AudioDecoderFailure(
            status: kAudio_ParamError,
            message: "지원하지 않는 AirPlay 오디오 형식입니다: \(format.compressionType)"
        ))
    }

    private func decodeOnQueue(_ sample: CompressedAudioSample) {
        guard sample.compressionType == configuredCompressionType,
              let outputFormat,
              let pcmBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: outputFrameCapacity
              ) else {
            return
        }

        if sample.compressionType == 1 {
            decodePCM(sample, into: pcmBuffer)
            return
        }
        guard let converter, let inputFormat, !sample.data.isEmpty else { return }

        // AirPlay sends every AAC-ELD access unit redundantly. Its RTP pattern is
        // 0,0,1,0,1,2,1,2,3...; decoding all copies triples playback work and
        // continuously overfills the low-latency audio queue.
        if sample.compressionType == 8, !acceptAACELDRTPTime(sample.rtpTime) {
            return
        }

        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: sample.data.count
        )
        sample.data.copyBytes(
            to: compressedBuffer.data.assumingMemoryBound(to: UInt8.self),
            count: sample.data.count
        )
        compressedBuffer.byteLength = UInt32(sample.data.count)
        compressedBuffer.packetCount = 1
        if let packetDescription = compressedBuffer.packetDescriptions {
            packetDescription.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: configuredSamplesPerFrame,
                mDataByteSize: UInt32(sample.data.count)
            )
        }

        let inputProvider = CompressedAudioBufferProvider(buffer: compressedBuffer)
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: pcmBuffer, error: &conversionError) {
            _, inputStatus in inputProvider.next(status: inputStatus)
        }
        guard conversionError == nil, conversionStatus != .error else {
            failureHandler(AudioDecoderFailure(
                status: OSStatus(conversionError?.code ?? Int(paramErr)),
                message: conversionError?.localizedDescription
                    ?? "AirPlay 오디오 프레임을 PCM으로 변환하지 못했습니다."
            ))
            return
        }
        guard pcmBuffer.frameLength > 0 else { return }
        outputHandler(DecodedAudioBuffer(
            buffer: pcmBuffer,
            presentationTimeNanoseconds: sample.remoteTimeNanoseconds
        ))
    }

    private func decodePCM(_ sample: CompressedAudioSample, into pcmBuffer: AVAudioPCMBuffer) {
        let bytesPerFrame = 4
        let frameCount = sample.data.count / bytesPerFrame
        guard frameCount > 0,
              frameCount <= Int(pcmBuffer.frameCapacity),
              let channels = pcmBuffer.floatChannelData else {
            failureHandler(AudioDecoderFailure(
                status: OSStatus(paramErr),
                message: "PCM 오디오 프레임 크기가 올바르지 않습니다."
            ))
            return
        }

        sample.data.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self)
            for frameIndex in 0 ..< frameCount {
                for channelIndex in 0 ..< 2 {
                    let byteIndex = (frameIndex * 2 + channelIndex) * 2
                    let value = UInt16(input[byteIndex]) | (UInt16(input[byteIndex + 1]) << 8)
                    channels[channelIndex][frameIndex] =
                        Float(Int16(bitPattern: value)) / 32_768
                }
            }
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        outputHandler(DecodedAudioBuffer(
            buffer: pcmBuffer,
            presentationTimeNanoseconds: sample.remoteTimeNanoseconds
        ))
    }

    private func resetOnQueue() {
        converter?.reset()
        converter = nil
        inputFormat = nil
        outputFormat = nil
        configuredCompressionType = nil
        configuredSamplesPerFrame = 0
        newestAACELDRTPTime = nil
    }

    private func acceptAACELDRTPTime(_ rtpTime: UInt32) -> Bool {
        guard let newestAACELDRTPTime else {
            self.newestAACELDRTPTime = rtpTime
            return true
        }

        // RTP timestamps are wrapping UInt32 counters. Interpreting the delta
        // as signed preserves ordering as long as the stream gap is < 2^31.
        let delta = Int32(bitPattern: rtpTime &- newestAACELDRTPTime)
        guard delta > 0 else { return false }
        self.newestAACELDRTPTime = rtpTime
        return true
    }

    private func sourceDescription(
        for codec: AirPlayAudioCodec,
        format: AudioFormatInfo
    ) -> AudioStreamBasicDescription {
        let framesPerPacket = UInt32(format.samplesPerFrame)
        switch codec {
        case .pcm:
            return AudioStreamBasicDescription(
                mSampleRate: 44_100,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
        case .alac:
            return AudioStreamBasicDescription(
                mSampleRate: 44_100,
                mFormatID: kAudioFormatAppleLossless,
                mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
                mBytesPerPacket: 0,
                mFramesPerPacket: framesPerPacket == 0 ? 352 : framesPerPacket,
                mBytesPerFrame: 0,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 0,
                mReserved: 0
            )
        case .aacLC:
            return compressedAACDescription(
                formatID: kAudioFormatMPEG4AAC,
                // MPEG-4 object type 2 identifies AAC Low Complexity.
                formatFlags: 2,
                framesPerPacket: framesPerPacket == 0 ? 1_024 : framesPerPacket
            )
        case .aacELD:
            return compressedAACDescription(
                formatID: kAudioFormatMPEG4AAC_ELD,
                formatFlags: 0,
                framesPerPacket: framesPerPacket == 0 ? 480 : framesPerPacket
            )
        case .unsupported:
            return AudioStreamBasicDescription()
        }
    }

    private func compressedAACDescription(
        formatID: AudioFormatID,
        formatFlags: AudioFormatFlags,
        framesPerPacket: UInt32
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: formatID,
            mFormatFlags: formatFlags,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    private static func destinationDescription() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func magicCookie(for codec: AirPlayAudioCodec) -> Data {
        switch codec {
        case .aacELD:
            // kAudioFormatMPEG4AAC_ELD already makes AudioConverter configure
            // the standard 44.1 kHz stereo ELD AudioSpecificConfig. Replacing
            // that converter-owned cookie is rejected on current macOS.
            Data()
        case .aacLC:
            Self.makeESDSCookie(audioSpecificConfig: [0x12, 0x10])
        case .alac:
            Data([
                0x00, 0x00, 0x00, 0x24, 0x61, 0x6C, 0x61, 0x63,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x60,
                0x00, 0x10, 0x28, 0x0A, 0x0E, 0x02, 0x00, 0xFF,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0xAC, 0x44
            ])
        case .pcm, .unsupported:
            Data()
        }
    }

    /// AudioConverter expects the MPEG-4 AudioSpecificConfig inside an ESDS
    /// descriptor, while UxPlay/GStreamer expresses the AirPlay configuration
    /// as the bare two- or four-byte value.
    private static func makeESDSCookie(audioSpecificConfig: [UInt8]) -> Data {
        let specificLength = UInt8(audioSpecificConfig.count)
        let decoderConfigLength = UInt8(18 + audioSpecificConfig.count)
        let elementaryStreamLength = UInt8(32 + audioSpecificConfig.count)
        return Data([
            0x03, 0x80, 0x80, 0x80, elementaryStreamLength,
            0x00, 0x00, 0x00,
            0x04, 0x80, 0x80, 0x80, decoderConfigLength,
            0x40, 0x14, 0x00, 0x18, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, 0xF4, 0x00,
            0x05, 0x80, 0x80, 0x80, specificLength
        ] + audioSpecificConfig + [
            0x06, 0x80, 0x80, 0x80, 0x01, 0x02
        ])
    }
}

private final class CompressedAudioBufferProvider: @unchecked Sendable {
    private let buffer: AVAudioCompressedBuffer
    private let lock = NSLock()
    private var supplied = false

    init(buffer: AVAudioCompressedBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                // The converter is reused for the lifetime of the AirPlay
                // session. This call has run out of input, but the stream has
                // not ended; `.endOfStream` permanently drains AAC-ELD after
                // the first decoded packet.
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}
