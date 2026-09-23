public enum MessageType: UInt16, Sendable, CaseIterable {
    case handshake = 0x0001
    case ping = 0x0002
    case pong = 0x0003
    case deviceInfo = 0x0004
    case error = 0x0005
    case clipboard = 0x0010
    case battery = 0x0020
    case notification = 0x0030
    case notificationReply = 0x0031
    case fileHeader = 0x0040
    case fileChunk = 0x0041
    case fileAck = 0x0042
    case fileCancel = 0x0043

    public init?(id: UInt16) {
        self.init(rawValue: id)
    }
}
