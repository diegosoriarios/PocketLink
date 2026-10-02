import Foundation

import LinkProtocol

struct HandshakeBody: Codable {
    let device: String
    let platform: String?
    let pairingToken: String?
    let protocolVersion: Int?
}

public struct HandshakeInfo: Sendable, Equatable {
    public let device: String
    public let platform: String
    public let pairingToken: String?
    /// Protocol version advertised by the peer; 1 when the peer predates
    /// version negotiation (field absent from its HANDSHAKE payload).
    public let protocolVersion: Int

    public init(device: String, platform: String, pairingToken: String?, protocolVersion: Int) {
        self.device = device
        self.platform = platform
        self.pairingToken = pairingToken
        self.protocolVersion = protocolVersion
    }
}

public enum HandshakeMessage {
    public static func frame(
        deviceName: String,
        pairingToken: String? = nil,
        streamId: UInt32 = 0
    ) throws -> Frame {
        let body = HandshakeBody(
            device: deviceName,
            platform: "macOS",
            pairingToken: pairingToken,
            protocolVersion: LinkProtocolConstants.handshakeVersion
        )
        let payload = try JSONEncoder().encode(body)
        return Frame(messageType: .handshake, streamId: streamId, payload: [UInt8](payload))
    }

    public static func parse(_ frame: Frame) -> HandshakeInfo? {
        guard frame.messageType == .handshake else { return nil }
        guard let body = try? JSONDecoder().decode(HandshakeBody.self, from: Data(frame.payload)) else {
            return nil
        }
        return HandshakeInfo(
            device: body.device,
            platform: body.platform ?? "",
            pairingToken: body.pairingToken,
            protocolVersion: body.protocolVersion ?? 1
        )
    }
}
