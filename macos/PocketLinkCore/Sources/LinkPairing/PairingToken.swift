import Foundation

public struct PairingToken: Sendable, Equatable {
    public static let defaultLifetime: TimeInterval = 5 * 60
    public static let payloadVersion = 1

    public let value: String
    public let createdAt: Date
    public let lifetime: TimeInterval

    public init(value: String, createdAt: Date = Date(), lifetime: TimeInterval = PairingToken.defaultLifetime) {
        self.value = value
        self.createdAt = createdAt
        self.lifetime = lifetime
    }

    public static func generate(now: Date = Date(), lifetime: TimeInterval = defaultLifetime) -> PairingToken {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PairingToken(value: encode(bytes), createdAt: now, lifetime: lifetime)
    }

    public var isExpired: Bool {
        Date().timeIntervalSince(createdAt) >= lifetime
    }

    public func matches(_ candidate: String) -> Bool {
        !isExpired && candidate == value
    }

    public var qrPayload: String {
        "pocketlink://pair?v=\(Self.payloadVersion)&t=\(value)"
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
