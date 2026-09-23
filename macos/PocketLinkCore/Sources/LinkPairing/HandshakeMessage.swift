import Foundation

import LinkProtocol

private struct HandshakeBody: Encodable {
    let device: String
    let platform: String
}

public enum HandshakeMessage {
    public static func frame(deviceName: String, streamId: UInt32 = 0) throws -> Frame {
        let body = try JSONEncoder().encode(HandshakeBody(device: deviceName, platform: "macOS"))
        return Frame(messageType: .handshake, streamId: streamId, payload: [UInt8](body))
    }
}
