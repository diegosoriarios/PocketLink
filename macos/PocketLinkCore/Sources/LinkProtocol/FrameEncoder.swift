public enum FrameEncoder {
    public static func encode(_ frame: Frame) throws -> [UInt8] {
        let payloadLength = frame.payloadLength
        guard payloadLength <= LinkProtocolConstants.maxPayloadSize else {
            throw FrameEncodeError.payloadTooLarge(declared: payloadLength)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(LinkProtocolConstants.headerSize + Int(payloadLength))
        bytes.append(contentsOf: LinkProtocolConstants.magicBytes)
        bytes.appendBE(frame.version)
        bytes.appendBE(frame.messageType.rawValue)
        bytes.appendBE(frame.streamId)
        bytes.appendBE(payloadLength)
        bytes.append(contentsOf: frame.payload)
        return bytes
    }
}

extension Array where Element == UInt8 {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
