import Foundation

public struct H264AccessUnit: Equatable, Sendable {
    public let avccData: Data
    public let sequenceParameterSet: Data
    public let pictureParameterSet: Data
    public let isKeyFrame: Bool
    public let parameterSetRevision: UInt64
    public let presentationTimeNanoseconds: UInt64

    public init(
        avccData: Data,
        sequenceParameterSet: Data,
        pictureParameterSet: Data,
        isKeyFrame: Bool,
        parameterSetRevision: UInt64,
        presentationTimeNanoseconds: UInt64
    ) {
        self.avccData = avccData
        self.sequenceParameterSet = sequenceParameterSet
        self.pictureParameterSet = pictureParameterSet
        self.isKeyFrame = isKeyFrame
        self.parameterSetRevision = parameterSetRevision
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
    }
}

public enum H264AccessUnitParserError: Error, Equatable, Sendable {
    case unsupportedCodec(VideoCodec)
    case malformedAnnexB
    case oversizedNALUnit
}

public struct H264AccessUnitParser: Sendable {
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var parameterSetRevision: UInt64 = 0

    public init() {}

    public mutating func parse(_ sample: CompressedVideoSample) throws -> H264AccessUnit? {
        guard sample.codec == .h264 else {
            throw H264AccessUnitParserError.unsupportedCodec(sample.codec)
        }

        let nalUnits = try Self.splitAnnexB(sample.data)
        guard !nalUnits.isEmpty else {
            throw H264AccessUnitParserError.malformedAnnexB
        }

        var parameterSetsChanged = false
        var isKeyFrame = false
        var avccData = Data()
        avccData.reserveCapacity(sample.data.count)

        for nalUnit in nalUnits {
            guard let header = nalUnit.first else { continue }
            let type = header & 0x1F
            switch type {
            case 5:
                isKeyFrame = true
            case 7:
                if sequenceParameterSet != nalUnit {
                    sequenceParameterSet = nalUnit
                    parameterSetsChanged = true
                }
            case 8:
                if pictureParameterSet != nalUnit {
                    pictureParameterSet = nalUnit
                    parameterSetsChanged = true
                }
            default:
                break
            }

            guard nalUnit.count <= Int(UInt32.max) else {
                throw H264AccessUnitParserError.oversizedNALUnit
            }
            var length = UInt32(nalUnit.count).bigEndian
            withUnsafeBytes(of: &length) { bytes in
                avccData.append(contentsOf: bytes)
            }
            avccData.append(nalUnit)
        }

        if parameterSetsChanged {
            parameterSetRevision &+= 1
        }

        guard let sequenceParameterSet, let pictureParameterSet else {
            return nil
        }

        return H264AccessUnit(
            avccData: avccData,
            sequenceParameterSet: sequenceParameterSet,
            pictureParameterSet: pictureParameterSet,
            isKeyFrame: isKeyFrame,
            parameterSetRevision: parameterSetRevision,
            presentationTimeNanoseconds: sample.remoteTimeNanoseconds
        )
    }

    public mutating func reset() {
        sequenceParameterSet = nil
        pictureParameterSet = nil
        parameterSetRevision = 0
    }

    private static func splitAnnexB(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, prefixLength: Int)] = []
        var index = 0

        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0,
                      bytes[index + 1] == 0,
                      bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }

        guard !starts.isEmpty, starts[0].offset == 0 else {
            throw H264AccessUnitParserError.malformedAnnexB
        }

        var result: [Data] = []
        result.reserveCapacity(starts.count)
        for (position, start) in starts.enumerated() {
            let payloadStart = start.offset + start.prefixLength
            var payloadEnd = position + 1 < starts.count
                ? starts[position + 1].offset
                : bytes.count
            while payloadEnd > payloadStart, bytes[payloadEnd - 1] == 0 {
                payloadEnd -= 1
            }
            guard payloadStart < payloadEnd else { continue }
            result.append(Data(bytes[payloadStart ..< payloadEnd]))
        }
        return result
    }
}
