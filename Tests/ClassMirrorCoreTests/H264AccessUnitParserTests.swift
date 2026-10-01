import Foundation
import Testing
@testable import ClassMirrorCore

struct H264AccessUnitParserTests {
    @Test
    func convertsAnnexBToLengthPrefixedAccessUnit() throws {
        var parser = H264AccessUnitParser()
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F]
        let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
        let idr: [UInt8] = [0x65, 0x88, 0x84]
        let sample = videoSample(nalUnits: [sps, pps, idr])

        let parsed = try parser.parse(sample)
        let accessUnit = try #require(parsed)

        #expect(accessUnit.sequenceParameterSet == Data(sps))
        #expect(accessUnit.pictureParameterSet == Data(pps))
        #expect(accessUnit.isKeyFrame)
        #expect(accessUnit.parameterSetRevision == 1)
        #expect(accessUnit.presentationTimeNanoseconds == 42)
        #expect(accessUnit.avccData == avcc(nalUnits: [sps, pps, idr]))
    }

    @Test
    func retainsParameterSetsForFollowingFrames() throws {
        var parser = H264AccessUnitParser()
        _ = try parser.parse(videoSample(nalUnits: [
            [0x67, 0x64, 0x00, 0x1F],
            [0x68, 0xEE, 0x3C, 0x80],
            [0x65, 0x01]
        ]))

        let parsed = try parser.parse(videoSample(nalUnits: [[0x41, 0x02]]))
        let accessUnit = try #require(parsed)

        #expect(!accessUnit.isKeyFrame)
        #expect(accessUnit.parameterSetRevision == 1)
        #expect(accessUnit.avccData == avcc(nalUnits: [[0x41, 0x02]]))
    }

    @Test
    func parameterSetChangeAdvancesRevision() throws {
        var parser = H264AccessUnitParser()
        _ = try parser.parse(videoSample(nalUnits: [
            [0x67, 0x01], [0x68, 0x02], [0x65, 0x03]
        ]))

        let parsed = try parser.parse(videoSample(nalUnits: [
            [0x67, 0x04], [0x68, 0x02], [0x65, 0x05]
        ]))
        let accessUnit = try #require(parsed)

        #expect(accessUnit.parameterSetRevision == 2)
        #expect(accessUnit.sequenceParameterSet == Data([0x67, 0x04]))
    }

    @Test
    func acceptsThreeByteStartCodes() throws {
        var parser = H264AccessUnitParser()
        let data = Data([
            0, 0, 1, 0x67, 0x01,
            0, 0, 1, 0x68, 0x02,
            0, 0, 1, 0x65, 0x03
        ])

        let parsed = try parser.parse(CompressedVideoSample(
            codec: .h264,
            data: data,
            nalCount: 3,
            localTimeNanoseconds: 0,
            remoteTimeNanoseconds: 0
        ))
        let accessUnit = try #require(parsed)

        #expect(accessUnit.isKeyFrame)
    }

    @Test
    func rejectsMissingStartCodeAndUnsupportedCodec() {
        var parser = H264AccessUnitParser()

        #expect(throws: H264AccessUnitParserError.malformedAnnexB) {
            try parser.parse(CompressedVideoSample(
                codec: .h264,
                data: Data([0x65, 0x01]),
                nalCount: 1,
                localTimeNanoseconds: 0,
                remoteTimeNanoseconds: 0
            ))
        }
        #expect(throws: H264AccessUnitParserError.unsupportedCodec(.h265)) {
            try parser.parse(CompressedVideoSample(
                codec: .h265,
                data: Data([0, 0, 0, 1, 0x26]),
                nalCount: 1,
                localTimeNanoseconds: 0,
                remoteTimeNanoseconds: 0
            ))
        }
    }

    private func videoSample(nalUnits: [[UInt8]]) -> CompressedVideoSample {
        var data = Data()
        for nalUnit in nalUnits {
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(contentsOf: nalUnit)
        }
        return CompressedVideoSample(
            codec: .h264,
            data: data,
            nalCount: nalUnits.count,
            localTimeNanoseconds: 41,
            remoteTimeNanoseconds: 42
        )
    }

    private func avcc(nalUnits: [[UInt8]]) -> Data {
        var data = Data()
        for nalUnit in nalUnits {
            var length = UInt32(nalUnit.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: nalUnit)
        }
        return data
    }
}
