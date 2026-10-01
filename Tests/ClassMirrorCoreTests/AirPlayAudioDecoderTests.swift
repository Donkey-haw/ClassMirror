import AudioToolbox
import Foundation
import Testing
@testable import ClassMirrorCore

struct AirPlayAudioDecoderTests {
    @Test
    func mapsAirPlayCompressionTypes() {
        #expect(AirPlayAudioCodec(compressionType: 1) == .pcm)
        #expect(AirPlayAudioCodec(compressionType: 2) == .alac)
        #expect(AirPlayAudioCodec(compressionType: 4) == .aacLC)
        #expect(AirPlayAudioCodec(compressionType: 8) == .aacELD)
        #expect(AirPlayAudioCodec(compressionType: 99) == .unsupported(99))
    }

    @Test
    func convertsPCMToFloatStereoBuffer() async {
        let (results, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let decoder = AirPlayAudioDecoder(
            onOutput: { decoded in
                let isValid =
                    decoded.buffer.frameLength == 4
                        && decoded.buffer.format.channelCount == 2
                        && decoded.presentationTimeNanoseconds == 123
                continuation.yield(isValid ? "success" : "invalid output")
                continuation.finish()
            },
            onFailure: { failure in
                continuation.yield("\(failure.status): \(failure.message)")
                continuation.finish()
            }
        )
        decoder.configure(AudioFormatInfo(
            compressionType: 1,
            samplesPerFrame: 4,
            isScreenAudio: true,
            isMedia: false,
            formatIdentifier: 0
        ))
        decoder.decode(CompressedAudioSample(
            compressionType: 1,
            data: Data([
                0x00, 0x00, 0x00, 0x00,
                0xFF, 0x7F, 0x00, 0x80,
                0x00, 0x40, 0x00, 0xC0,
                0x00, 0x00, 0x00, 0x00
            ]),
            sequenceNumber: 1,
            rtpTime: 1,
            localTimeNanoseconds: 122,
            remoteTimeNanoseconds: 123
        ))
        await decoder.finishPendingWork()
        continuation.finish()

        var iterator = results.makeAsyncIterator()
        let result = await iterator.next()
        #expect(result == "success")
    }

    @Test
    func decodesRawAACLCFrame() async {
        // One silent raw MPEG-4 AAC-LC access unit (44.1 kHz, stereo)
        // produced by Apple's encoder. AirPlay ct=4 likewise supplies raw
        // access units and the decoder configuration separately.
        let accessUnit = Data([
            0x21, 0x00, 0x03, 0x40, 0x68, 0x1C
        ])
        let (results, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let decoder = AirPlayAudioDecoder(
            onOutput: { decoded in
                let isValid =
                    decoded.buffer.frameLength == 1_024
                        && decoded.buffer.format.sampleRate == 44_100
                        && decoded.buffer.format.channelCount == 2
                        && decoded.presentationTimeNanoseconds == 456
                continuation.yield(isValid ? "success" : "invalid output")
                continuation.finish()
            },
            onFailure: { failure in
                continuation.yield("\(failure.status): \(failure.message)")
                continuation.finish()
            }
        )
        decoder.configure(AudioFormatInfo(
            compressionType: 4,
            samplesPerFrame: 1_024,
            isScreenAudio: false,
            isMedia: true,
            formatIdentifier: 0
        ))
        decoder.decode(CompressedAudioSample(
            compressionType: 4,
            data: accessUnit,
            sequenceNumber: 1,
            rtpTime: 1,
            localTimeNanoseconds: 455,
            remoteTimeNanoseconds: 456
        ))
        await decoder.finishPendingWork()
        continuation.finish()

        var iterator = results.makeAsyncIterator()
        let result = await iterator.next()
        #expect(result == "success")
    }

    @Test
    func decodesRawAACELDFrameAndDropsRedundantRTPPackets() async {
        // One 480-frame stereo AAC-ELD access unit produced by Apple's encoder.
        let accessUnit = Data([
            0x82, 0x95, 0xAA, 0x11, 0xC0, 0xAD, 0xF7, 0xDD,
            0xEB, 0xE3, 0xF7, 0x79, 0x74, 0x34, 0xC9, 0x3B,
            0x59, 0x16, 0xE2, 0xAC, 0x61, 0xF1, 0x21, 0x01,
            0xFD, 0x7F, 0x60, 0xAC, 0x61, 0xD5, 0xD0, 0x3C,
            0x72, 0x3E, 0xEA, 0x3A, 0xF1, 0x29, 0x1E, 0xF4,
            0xA1, 0xAA, 0xA2, 0xE7, 0xC9, 0xAD, 0x2C, 0x79,
            0x75, 0x16, 0xB3, 0x5D, 0xB5, 0x3D, 0x52, 0xBC,
            0xC3, 0x26, 0xB4, 0xD0, 0xD5, 0xA0, 0xA9, 0x5E,
            0x61, 0xA6, 0x2D, 0x4A, 0xE5, 0xD2, 0xD4, 0xAE,
            0x5D, 0x2D, 0x4A, 0xE4, 0x42, 0x52, 0xD7, 0x8D,
            0x78, 0xD7, 0x8D, 0x78, 0xD7, 0x8D, 0x78, 0xD7,
            0x88, 0xC6, 0xBC, 0x46, 0x23, 0x11, 0x88, 0xC6,
            0xD8, 0x3E, 0x1B, 0x71, 0x56, 0x30, 0xF8, 0x90,
            0x80, 0xF8
        ])
        let resultBox = AudioDecoderResultBox()
        let decoder = AirPlayAudioDecoder(
            onOutput: { decoded in
                resultBox.record(decoded)
            },
            onFailure: { failure in
                resultBox.record(failure)
            }
        )
        decoder.configure(AudioFormatInfo(
            compressionType: 8,
            samplesPerFrame: 480,
            isScreenAudio: true,
            isMedia: false,
            formatIdentifier: 0
        ))
        for rtpTime: UInt32 in [1_000, 1_000, 1_480, 1_000, 1_480] {
            decoder.decode(CompressedAudioSample(
                compressionType: 8,
                data: accessUnit,
                sequenceNumber: 1,
                rtpTime: rtpTime,
                localTimeNanoseconds: 0,
                remoteTimeNanoseconds: UInt64(rtpTime)
            ))
        }
        await decoder.finishPendingWork()

        let result = resultBox.result
        #expect(result.0 == 2)
        #expect(result.1)
        #expect(result.2.isEmpty)
    }

    @Test
    func configuresAdvertisedCompressedFormats() async {
        for (compressionType, samplesPerFrame): (UInt8, UInt16) in [
            (2, 352),
            (4, 1_024),
            (8, 480)
        ] {
            let (failures, continuation) = AsyncStream.makeStream(
                of: AudioDecoderFailure.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let decoder = AirPlayAudioDecoder(
                onOutput: { _ in },
                onFailure: { failure in continuation.yield(failure) }
            )
            decoder.configure(AudioFormatInfo(
                compressionType: compressionType,
                samplesPerFrame: samplesPerFrame,
                isScreenAudio: true,
                isMedia: false,
                formatIdentifier: 0
            ))
            await decoder.finishPendingWork()
            continuation.finish()

            var iterator = failures.makeAsyncIterator()
            let failure = await iterator.next()
            #expect(failure == nil)
        }
    }

    @Test
    func rejectsUnsupportedCompressionType() async {
        let (failures, continuation) = AsyncStream.makeStream(
            of: AudioDecoderFailure.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let decoder = AirPlayAudioDecoder(
            onOutput: { _ in },
            onFailure: { failure in
                continuation.yield(failure)
                continuation.finish()
            }
        )
        decoder.configure(AudioFormatInfo(
            compressionType: 99,
            samplesPerFrame: 1,
            isScreenAudio: true,
            isMedia: false,
            formatIdentifier: 0
        ))
        await decoder.finishPendingWork()
        continuation.finish()

        var iterator = failures.makeAsyncIterator()
        let failure = await iterator.next()
        #expect(failure?.status == kAudio_ParamError)
    }
}

private final class AudioDecoderResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outputCount = 0
    private var outputIsValid = false
    private var failures: [AudioDecoderFailure] = []

    var result: (Int, Bool, [AudioDecoderFailure]) {
        lock.withLock { (outputCount, outputIsValid, failures) }
    }

    func record(_ decoded: DecodedAudioBuffer) {
        lock.withLock {
            outputCount += 1
            outputIsValid = decoded.buffer.frameLength == 480
                && decoded.buffer.format.channelCount == 2
        }
    }

    func record(_ failure: AudioDecoderFailure) {
        lock.withLock { failures.append(failure) }
    }
}
