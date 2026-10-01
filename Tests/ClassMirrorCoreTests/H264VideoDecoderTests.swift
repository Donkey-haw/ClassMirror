import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import ClassMirrorCore

struct H264VideoDecoderTests {
    @Test
    func decodesVideoToolboxEncodedFrame() async throws {
        let encodedFrame = try makeEncodedFrame()
        let (results, continuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let decoder = H264VideoDecoder(
            onFrame: { pixelBuffer, _ in
                continuation.yield(
                    CVPixelBufferGetWidth(pixelBuffer) == 64
                        && CVPixelBufferGetHeight(pixelBuffer) == 64
                )
                continuation.finish()
            },
            onFailure: { _ in
                continuation.yield(false)
                continuation.finish()
            }
        )

        decoder.decode(CompressedVideoSample(
            codec: .h264,
            data: encodedFrame,
            nalCount: 3,
            localTimeNanoseconds: 0,
            remoteTimeNanoseconds: 0
        ))
        await decoder.finishPendingFrames()
        continuation.finish()

        var iterator = results.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(await decoder.isUsingHardwareAcceleration() == true)
    }

    private func makeEncodedFrame() throws -> Data {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw DecoderFixtureError.pixelBuffer(pixelStatus)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x7F, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let box = EncodedFrameBox()
        var compressionSession: VTCompressionSession?
        let sessionStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 64,
            height: 64,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: classMirrorTestCompressionCallback,
            refcon: Unmanaged.passUnretained(box).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        guard sessionStatus == noErr, let compressionSession else {
            throw DecoderFixtureError.compressionSession(sessionStatus)
        }
        defer { VTCompressionSessionInvalidate(compressionSession) }

        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )
        VTCompressionSessionPrepareToEncodeFrames(compressionSession)

        var flags = VTEncodeInfoFlags()
        let encodeStatus = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 30),
            frameProperties: [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true
            ] as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        guard encodeStatus == noErr else {
            throw DecoderFixtureError.encoding(encodeStatus)
        }
        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
        guard box.semaphore.wait(timeout: .now() + 5) == .success else {
            throw DecoderFixtureError.timeout
        }
        if let failure = box.failure {
            throw failure
        }
        guard let data = box.data else {
            throw DecoderFixtureError.emptyOutput
        }
        return data
    }
}

private final class EncodedFrameBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    private var storedData: Data?
    private var storedFailure: DecoderFixtureError?

    var data: Data? { lock.withLock { storedData } }
    var failure: DecoderFixtureError? { lock.withLock { storedFailure } }

    func complete(data: Data) {
        lock.withLock { storedData = data }
        semaphore.signal()
    }

    func fail(_ failure: DecoderFixtureError) {
        lock.withLock { storedFailure = failure }
        semaphore.signal()
    }
}

private enum DecoderFixtureError: Error {
    case pixelBuffer(CVReturn)
    case compressionSession(OSStatus)
    case encoding(OSStatus)
    case compressionCallback(OSStatus)
    case parameterSet(OSStatus)
    case malformedAVCC
    case timeout
    case emptyOutput
}

private func classMirrorTestCompressionCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    let box = Unmanaged<EncodedFrameBox>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    guard status == noErr, let sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer) else {
        box.fail(.compressionCallback(status))
        return
    }

    do {
        let data = try annexBData(from: sampleBuffer)
        box.complete(data: data)
    } catch let failure as DecoderFixtureError {
        box.fail(failure)
    } catch {
        box.fail(.emptyOutput)
    }
}

private func annexBData(from sampleBuffer: CMSampleBuffer) throws -> Data {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        throw DecoderFixtureError.emptyOutput
    }

    var result = Data()
    for index in 0 ..< 2 {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr, let pointer else {
            throw DecoderFixtureError.parameterSet(status)
        }
        result.append(contentsOf: [0, 0, 0, 1])
        result.append(pointer, count: size)
    }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        throw DecoderFixtureError.emptyOutput
    }
    let totalLength = CMBlockBufferGetDataLength(blockBuffer)
    var avcc = Data(count: totalLength)
    let copyStatus = avcc.withUnsafeMutableBytes { bytes in
        CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: totalLength,
            destination: bytes.baseAddress!
        )
    }
    guard copyStatus == noErr else {
        throw DecoderFixtureError.compressionCallback(copyStatus)
    }

    var offset = 0
    while offset + 4 <= avcc.count {
        let length = avcc[offset ..< offset + 4].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
        offset += 4
        guard length > 0, offset + Int(length) <= avcc.count else {
            throw DecoderFixtureError.malformedAVCC
        }
        result.append(contentsOf: [0, 0, 0, 1])
        result.append(avcc[offset ..< offset + Int(length)])
        offset += Int(length)
    }
    guard offset == avcc.count else {
        throw DecoderFixtureError.malformedAVCC
    }
    return result
}
