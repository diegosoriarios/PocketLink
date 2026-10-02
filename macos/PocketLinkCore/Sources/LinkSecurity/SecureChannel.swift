import Foundation

/// Post-handshake transport encryption: seals/opens LINK frame payloads
/// with per-direction `CipherState`s, using the 16-byte on-wire frame
/// header as AEAD additional authenticated data.
public struct SecureChannel {
    private var sendState: CipherState
    private var receiveState: CipherState
    public let handshakeHash: Data

    public init(sendState: CipherState, receiveState: CipherState, handshakeHash: Data) {
        self.sendState = sendState
        self.receiveState = receiveState
        self.handshakeHash = handshakeHash
    }

    /// Encrypts a frame payload; returns ciphertext ‖ tag (16 B longer than
    /// the plaintext, which is what the frame header's length field must say).
    public mutating func seal(header: [UInt8], payload: Data) throws -> Data {
        guard header.count == 16 else { throw NoiseError.decryptFailed }
        return try sendState.encrypt(payload, aad: Data(header))
    }

    /// Decrypts a received payload; `header` is the raw 16-byte header as
    /// received on the wire.
    public mutating func open(header: [UInt8], payload: Data) throws -> Data {
        guard header.count == 16 else { throw NoiseError.decryptFailed }
        return try receiveState.decrypt(payload, aad: Data(header))
    }
}
