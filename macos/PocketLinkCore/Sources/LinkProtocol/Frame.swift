public struct Frame: Equatable, Sendable {
    public let version: UInt16
    public let messageType: MessageType
    public let streamId: UInt32
    public let payload: [UInt8]

    public var payloadLength: UInt32 { UInt32(payload.count) }

    public init(
        version: UInt16 = LinkProtocolConstants.protocolVersion,
        messageType: MessageType,
        streamId: UInt32,
        payload: [UInt8] = []
    ) {
        self.version = version
        self.messageType = messageType
        self.streamId = streamId
        self.payload = payload
    }

    public init(
        version: UInt16 = LinkProtocolConstants.protocolVersion,
        messageType: MessageType,
        streamId: UInt32,
        payloadString: String
    ) {
        self.init(
            version: version,
            messageType: messageType,
            streamId: streamId,
            payload: Array(payloadString.utf8)
        )
    }
}

public enum FrameEncodeError: Error, Equatable, Sendable {
    case payloadTooLarge(declared: UInt32)
}

public enum FrameDecodeError: Error, Equatable, Sendable {
    case invalidMagic(offendingBytes: [UInt8])
    case frameOversized(declaredLength: UInt32)
    case unknownMessageType(id: UInt16)
}
