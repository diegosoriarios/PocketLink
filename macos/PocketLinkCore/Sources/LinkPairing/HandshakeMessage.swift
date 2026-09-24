import Foundation

import LinkProtocol

struct HandshakeBody: Codable {
    let device: String
    let platform: String?
    let pairingToken: String?
}

public struct HandshakeInfo: Sendable, Equatable {
    public let device: String
    public let platform: String
    public let pairingToken: String?
}

public enum HandshakeMessage {
    public static func frame(
        deviceName: String,
        pairingToken: String? = nil,
        streamId: UInt32 = 0
    ) throws -> Frame {
        let body = HandshakeBody(device: deviceName, platform: "macOS", pairingToken: pairingToken)
        let payload = try JSONEncoder().encode(body)
        return Frame(messageType: .handshake, streamId: streamId, payload: [UInt8](payload))
    }

    public static func parse(_ frame: Frame) -> HandshakeInfo? {
        guard frame.messageType == .handshake else { return nil }
        guard let body = try? JSONDecoder().decode(HandshakeBody.self, from: Data(frame.payload)) else {
            return nil
        }
        return HandshakeInfo(device: body.device, platform: body.platform ?? "", pairingToken: body.pairingToken)
    }
}
