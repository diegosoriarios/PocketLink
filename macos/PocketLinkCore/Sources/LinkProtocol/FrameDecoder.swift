public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var head = 0

    private var availableBytes: Int { buffer.count - head }

    public init() {}

    public mutating func feed(_ data: [UInt8]) throws -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []

        while availableBytes >= LinkProtocolConstants.headerSize {
            let base = head
            let magic = Array(buffer[base..<(base + 4)])
            guard magic == LinkProtocolConstants.magicBytes else {
                reset()
                throw FrameDecodeError.invalidMagic(offendingBytes: magic)
            }

            let declaredLength = Self.readUInt32BE(buffer, offset: base + 12)
            guard declaredLength <= LinkProtocolConstants.maxPayloadSize else {
                reset()
                throw FrameDecodeError.frameOversized(declaredLength: declaredLength)
            }

            let totalFrameSize = LinkProtocolConstants.headerSize + Int(declaredLength)
            guard availableBytes >= totalFrameSize else { break }

            let typeId = Self.readUInt16BE(buffer, offset: base + 6)
            guard let messageType = MessageType(id: typeId) else {
                reset()
                throw FrameDecodeError.unknownMessageType(id: typeId)
            }

            let version = Self.readUInt16BE(buffer, offset: base + 4)
            let streamId = Self.readUInt32BE(buffer, offset: base + 8)
            let payload = Array(buffer[(base + LinkProtocolConstants.headerSize)..<(base + totalFrameSize)])

            frames.append(
                Frame(
                    version: version,
                    messageType: messageType,
                    streamId: streamId,
                    payload: payload
                )
            )
            head += totalFrameSize
        }

        if head > 0 {
            buffer.removeFirst(head)
            head = 0
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        head = 0
    }

    private static func readUInt16BE(_ bytes: [UInt8], offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
