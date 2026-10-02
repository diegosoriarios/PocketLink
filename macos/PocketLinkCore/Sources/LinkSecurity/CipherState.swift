import CryptoKit
import Foundation

/// A Noise CipherState: symmetric key plus monotonically increasing
/// 96-bit nonces (`32 zero bits || u64 big-endian counter`). Encrypt and
/// decrypt counters are tracked separately so a single state can be used
/// for either direction without cross-talk.
public struct CipherState {
    private var key: SymmetricKey?
    private var encryptNonce: UInt64 = 0
    private var decryptNonce: UInt64 = 0

    public init(key: SymmetricKey? = nil) {
        self.key = key
    }

    public var isInitialized: Bool { key != nil }

    public mutating func setKey(_ newKey: SymmetricKey) {
        key = newKey
        encryptNonce = 0
        decryptNonce = 0
    }

    public static func nonceBytes(_ counter: UInt64) -> Data {
        var data = Data(count: 12)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            bytes[4] = UInt8(truncatingIfNeeded: counter >> 56)
            bytes[5] = UInt8(truncatingIfNeeded: counter >> 48)
            bytes[6] = UInt8(truncatingIfNeeded: counter >> 40)
            bytes[7] = UInt8(truncatingIfNeeded: counter >> 32)
            bytes[8] = UInt8(truncatingIfNeeded: counter >> 24)
            bytes[9] = UInt8(truncatingIfNeeded: counter >> 16)
            bytes[10] = UInt8(truncatingIfNeeded: counter >> 8)
            bytes[11] = UInt8(truncatingIfNeeded: counter)
        }
        return data
    }

    /// Returns ciphertext ‖ 16-byte tag.
    public mutating func encrypt(_ plaintext: Data, aad: Data = Data()) throws -> Data {
        guard let key else { throw NoiseError.cipherNotInitialized }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(encryptNonce)),
            authenticating: aad
        )
        encryptNonce &+= 1
        // Re-wrap: on this Foundation, `slice + slice` preserves the slice's
        // non-zero startIndex, and consumers index the result absolutely.
        return Data(box.ciphertext + box.tag)
    }

    /// Expects ciphertext ‖ 16-byte tag. Index-safe on any `Data` (slices
    /// included): `prefix`/`suffix` use relative positions.
    public mutating func decrypt(_ ciphertextWithTag: Data, aad: Data = Data()) throws -> Data {
        guard let key else { throw NoiseError.cipherNotInitialized }
        guard ciphertextWithTag.count >= 16 else { throw NoiseError.decryptFailed }
        let tag = ciphertextWithTag.suffix(16)
        let ciphertext = ciphertextWithTag.prefix(ciphertextWithTag.count - 16)
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(decryptNonce)),
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try ChaChaPoly.open(box, using: key, authenticating: aad)
        decryptNonce &+= 1
        return plaintext
    }
}

public enum NoiseError: Error, Equatable {
    case cipherNotInitialized
    case decryptFailed
    case invalidMessageLength
    case invalidIdentityPayload
    case signatureVerificationFailed
}
