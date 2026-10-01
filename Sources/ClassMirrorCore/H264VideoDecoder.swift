@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

public struct VideoDecoderFailure: Error, Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case parsing
        case formatDescription
        case sessionCreation
        case sampleCreation
        case decoding
    }

    public let stage: Stage
    public let status: OSStatus
    public let message: String

    public init(stage: Stage, status: OSStatus, message: String) {
        self.stage = stage
        self.status = status
        self.message = message
    }
}

public final class H264VideoDecoder: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime) -> Void
    public typealias FailureHandler = @Sendable (VideoDecoderFailure) -> Void

    private let queue = DispatchQueue(label: "com.classmirror.video-decoder", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private let frameHandler: FrameHandler
    private let failureHandler: FailureHandler
    private var parser = H264AccessUnitParser()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var activeParameterSetRevision: UInt64?

    public init(
        onFrame: @escaping FrameHandler,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        frameHandler = onFrame
        failureHandler = onFailure
        queue.setSpecific(key: queueKey, value: ())
    }

    public func decode(_ sample: CompressedVideoSample) {
        queue.async { [self] in
            decodeOnQueue(sample)
        }
    }

    public func reset() {
        queue.async { [self] in
            resetOnQueue()
        }
    }

    public func finishPendingFrames() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let session {
                    VTDecompressionSessionWaitForAsynchronousFrames(session)
                }
                continuation.resume()
            }
        }
    }

    public func isUsingHardwareAcceleration() async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            queue.async { [self] in
                guard let session else {
                    continuation.resume(returning: nil)
                    return
                }
                var value: CFTypeRef?
                let status = withUnsafeMutablePointer(to: &value) { pointer in
                    VTSessionCopyProperty(
                        session,
                        key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                        allocator: kCFAllocatorDefault,
                        valueOut: UnsafeMutableRawPointer(pointer)
                    )
                }
                continuation.resume(returning: status == noErr ? value as? Bool : nil)
            }
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            invalidateSessionOnQueue()
        } else {
            queue.sync { [self] in
                invalidateSessionOnQueue()
            }
        }
    }

    fileprivate func publish(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime
    ) {
        guard status == noErr, let pixelBuffer = imageBuffer else {
            failureHandler(VideoDecoderFailure(
                stage: .decoding,
                status: status,
                message: "VideoToolbox가 영상 프레임을 출력하지 못했습니다."
            ))
            return
        }
        frameHandler(pixelBuffer, presentationTimeStamp)
    }

    private func decodeOnQueue(_ sample: CompressedVideoSample) {
        let accessUnit: H264AccessUnit
        do {
            guard let parsed = try parser.parse(sample) else { return }
            accessUnit = parsed
        } catch {
            failureHandler(VideoDecoderFailure(
                stage: .parsing,
                status: OSStatus(paramErr),
                message: "H.264 Annex-B access unit을 해석하지 못했습니다: \(error)"
            ))
            return
        }

        if session == nil || activeParameterSetRevision != accessUnit.parameterSetRevision {
            do {
                try rebuildSession(for: accessUnit)
            } catch let failure as VideoDecoderFailure {
                failureHandler(failure)
                return
            } catch {
                failureHandler(VideoDecoderFailure(
                    stage: .sessionCreation,
                    status: OSStatus(paramErr),
                    message: "VideoToolbox 세션을 만들지 못했습니다: \(error)"
                ))
                return
            }
        }

        guard let session, let formatDescription else { return }
        do {
            let sampleBuffer = try makeSampleBuffer(
                accessUnit: accessUnit,
                formatDescription: formatDescription
            )
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
                frameRefcon: nil,
                infoFlagsOut: &infoFlags
            )
            if status == kVTInvalidSessionErr {
                invalidateSessionOnQueue()
            }
            guard status == noErr else {
                throw VideoDecoderFailure(
                    stage: .decoding,
                    status: status,
                    message: "VideoToolbox가 압축 프레임을 디코드하지 못했습니다."
                )
            }
        } catch let failure as VideoDecoderFailure {
            failureHandler(failure)
        } catch {
            failureHandler(VideoDecoderFailure(
                stage: .sampleCreation,
                status: OSStatus(paramErr),
                message: "압축 프레임용 CMSampleBuffer를 만들지 못했습니다: \(error)"
            ))
        }
    }

    private func rebuildSession(for accessUnit: H264AccessUnit) throws {
        invalidateSessionOnQueue()

        var description: CMFormatDescription?
        let descriptionStatus = accessUnit.sequenceParameterSet.withUnsafeBytes { spsBytes in
            accessUnit.pictureParameterSet.withUnsafeBytes { ppsBytes in
                guard let sps = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let pps = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(paramErr)
                }
                let pointers = [sps, pps]
                let sizes = [accessUnit.sequenceParameterSet.count, accessUnit.pictureParameterSet.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard descriptionStatus == noErr, let description else {
            throw VideoDecoderFailure(
                stage: .formatDescription,
                status: descriptionStatus,
                message: "H.264 SPS/PPS로 영상 포맷을 만들지 못했습니다."
            )
        }

        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: classMirrorDecompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var createdSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &createdSession
        )
        guard sessionStatus == noErr, let createdSession else {
            throw VideoDecoderFailure(
                stage: .sessionCreation,
                status: sessionStatus,
                message: "하드웨어 H.264 디코더를 시작하지 못했습니다."
            )
        }
        VTSessionSetProperty(
            createdSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        session = createdSession
        formatDescription = description
        activeParameterSetRevision = accessUnit.parameterSetRevision
    }

    private func makeSampleBuffer(
        accessUnit: H264AccessUnit,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: accessUnit.avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: accessUnit.avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw VideoDecoderFailure(
                stage: .sampleCreation,
                status: status,
                message: "영상 block buffer를 만들지 못했습니다."
            )
        }

        status = accessUnit.avccData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(paramErr) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: accessUnit.avccData.count
            )
        }
        guard status == noErr else {
            throw VideoDecoderFailure(
                stage: .sampleCreation,
                status: status,
                message: "영상 데이터를 block buffer로 복사하지 못했습니다."
            )
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(clamping: accessUnit.presentationTimeNanoseconds),
                timescale: 1_000_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = accessUnit.avccData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw VideoDecoderFailure(
                stage: .sampleCreation,
                status: status,
                message: "영상 CMSampleBuffer를 만들지 못했습니다."
            )
        }

        if !accessUnit.isKeyFrame,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
               sampleBuffer,
               createIfNecessary: true
           ),
           CFArrayGetCount(attachments) > 0,
           let dictionaryPointer = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = Unmanaged<CFMutableDictionary>
                .fromOpaque(dictionaryPointer)
                .takeUnretainedValue()
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private func resetOnQueue() {
        parser.reset()
        invalidateSessionOnQueue()
    }

    private func invalidateSessionOnQueue() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        formatDescription = nil
        activeParameterSetRevision = nil
    }
}

private func classMirrorDecompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let decompressionOutputRefCon else { return }
    let decoder = Unmanaged<H264VideoDecoder>
        .fromOpaque(decompressionOutputRefCon)
        .takeUnretainedValue()
    decoder.publish(
        status: status,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp
    )
}
