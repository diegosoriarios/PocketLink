public enum MessageType: UInt16, Sendable, CaseIterable {
    case handshake = 0x0001
    case ping = 0x0002
    case pong = 0x0003
    case deviceInfo = 0x0004
    case error = 0x0005
    case clipboard = 0x0010
    case clipboardAck = 0x0011
    case battery = 0x0020
    case notification = 0x0030
    case notificationReply = 0x0031
    case notificationAction = 0x0032
    case notificationReplyAck = 0x0033
    case fileHeader = 0x0040
    case fileChunk = 0x0041
    case fileAck = 0x0042
    case fileCancel = 0x0043
    case mirrorStart = 0x0050
    case mirrorStop = 0x0051
    case mirrorConfig = 0x0052
    case mirrorFrame = 0x0053
    case remoteTouch = 0x0054
    case cryptoM1 = 0x0060
    case cryptoM2 = 0x0061
    case cryptoM3 = 0x0062

    public init?(id: UInt16) {
        self.init(rawValue: id)
    }
}
