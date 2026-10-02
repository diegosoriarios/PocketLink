import CryptoKit
import Foundation

/// Noise XX handshake over X25519 / ChaChaPoly / SHA-256.
///
/// Wire (one message per LINK frame, no extra length prefix):
/// - M1 `-> e`            : 32 B
/// - M2 `<- e, ee, s, es` : 80 B + encrypted payload (identity ‖ signature)
/// - M3 `-> s, se`        : 48 B + encrypted payload (identity ‖ signature)
///
/// The encrypted payload carries the sender's Ed25519 identity public key
/// and an Ed25519 signature over the sender's Noise static X25519 public
/// key, binding the two keys together.
public struct NoiseHandshake {
    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"

    private var ck: Data = Data()
    private var h: Data = Data()
    private var k: SymmetricKey?
    private var nonce: UInt64 = 0

    public let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var remoteStatic: Curve25519.KeyAgreement.PublicKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?

    public private(set) var handshakeHash: Data = Data()

    public init(staticKey: Curve25519.KeyAgreement.PrivateKey) {
        self.staticKey = staticKey
        let name = Data(Self.protocolName.utf8)
        if name.count <= 32 {
            h = name + Data(repeating: 0, count: 32 - name.count)
        } else {
            h = Self.sha256(name)
        }
        ck = h
    }

    // MARK: - Initiator

    /// Writes message 1 (`-> e`).
    public mutating func writeM1() throws -> Data {
        let e = Curve25519.KeyAgreement.PrivateKey()
        ephemeralKey = e
        let pub = e.publicKey.rawRepresentation
        h = Self.sha256(h + pub)
        return pub
    }

    /// Reads message 2 (`<- e, ee, s, es`), verifies the responder's
    /// identity signature, and returns its identity public key.
    @discardableResult
    public mutating func readM2(_ message: Data) throws -> ResponderIdentity {
        guard message.count >= 80 else { throw NoiseError.invalidMessageLength }
        let e = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.prefix(32))
        remoteEphemeral = e
        h = Self.sha256(h + message.prefix(32))

        mixKey(try dh(privateKey: requireEphemeral(), publicKey: e))

        let sBytes = try decryptAndHash(message.dropFirst(32).prefix(48))
        let s = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sBytes)
        remoteStatic = s

        mixKey(try dh(privateKey: requireEphemeral(), publicKey: s))

        guard message.count >= 80 + IdentityPayload.encryptedWireSize else {
            throw NoiseError.invalidIdentityPayload
        }
        let payloadBytes = try decryptAndHash(message.dropFirst(80).prefix(IdentityPayload.encryptedWireSize))
        let payload = try IdentityPayload.parse(payloadBytes)
        guard verifyPayload(payload, staticKey: s) else {
            throw NoiseError.signatureVerificationFailed
        }
        return ResponderIdentity(
            identityKey: payload.identityKey,
            staticKey: s.rawRepresentation,
            fingerprint: LinkIdentity.fingerprint(for: payload.identityKey)
        )
    }

    /// Writes message 3 (`-> s, se`) carrying our identity payload.
    public mutating func writeM3(identity: LinkIdentity) throws -> Data {
        let sBytes = try encryptAndHash(staticKey.publicKey.rawRepresentation)

        mixKey(try dh(privateKey: staticKey, publicKey: requireRemoteEphemeral()))

        let payload = IdentityPayload(
            identityKey: identity.signingPublicKeyRaw,
            signature: try identity.sign(staticKeyData: staticKey.publicKey.rawRepresentation)
        )
        let payloadBytes = try encryptAndHash(payload.encoded())
        return sBytes + payloadBytes
    }

    // MARK: - Responder

    /// Reads message 1 (`-> e`).
    public mutating func readM1(_ message: Data) throws {
        guard message.count == 32 else { throw NoiseError.invalidMessageLength }
        let e = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message)
        remoteEphemeral = e
        h = Self.sha256(h + message)
    }

    /// Writes message 2 (`<- e, ee, s, es`) carrying our identity payload.
    public mutating func writeM2(identity: LinkIdentity) throws -> Data {
        let e = Curve25519.KeyAgreement.PrivateKey()
        ephemeralKey = e
        let eBytes = e.publicKey.rawRepresentation
        h = Self.sha256(h + eBytes)

        mixKey(try dh(privateKey: e, publicKey: requireRemoteEphemeral()))

        let sBytes = try encryptAndHash(staticKey.publicKey.rawRepresentation)

        // `es`: shared = responder static × initiator ephemeral.
        mixKey(try dh(privateKey: staticKey, publicKey: requireRemoteEphemeral()))

        let payload = IdentityPayload(
            identityKey: identity.signingPublicKeyRaw,
            signature: try identity.sign(staticKeyData: staticKey.publicKey.rawRepresentation)
        )
        let payloadBytes = try encryptAndHash(payload.encoded())
        return eBytes + sBytes + payloadBytes
    }

    /// Reads message 3 (`-> s, se`), verifies the initiator's identity
    /// signature, and returns its identity public key.
    @discardableResult
    public mutating func readM3(_ message: Data) throws -> InitiatorIdentity {
        guard message.count >= 48 + IdentityPayload.encryptedWireSize else {
            throw NoiseError.invalidIdentityPayload
        }
        let sBytes = try decryptAndHash(message.prefix(48))
        let s = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sBytes)
        remoteStatic = s

        // `se`: shared = responder ephemeral × initiator static.
        mixKey(try dh(privateKey: requireEphemeral(), publicKey: requireRemoteStatic()))

        let payloadBytes = try decryptAndHash(message.dropFirst(48).prefix(IdentityPayload.encryptedWireSize))
        let payload = try IdentityPayload.parse(payloadBytes)
        guard verifyPayload(payload, staticKey: s) else {
            throw NoiseError.signatureVerificationFailed
        }
        return InitiatorIdentity(
            identityKey: payload.identityKey,
            staticKey: s.rawRepresentation,
            fingerprint: LinkIdentity.fingerprint(for: payload.identityKey)
        )
    }

    // MARK: - Split

    /// Splits into transport cipher states: `(initiator → responder, responder → initiator)`.
    public mutating func split() throws -> (send: CipherState, receive: CipherState, handshakeHash: Data) {
        let temp = Self.hkdf(ikm: Data(), salt: ck, outputLength: 64)
        let k1 = Data(temp.prefix(32))
        let k2 = Data(temp.suffix(32))
        let finalHash = Self.sha256(h)
        handshakeHash = finalHash
        var sendState = CipherState()
        sendState.setKey(SymmetricKey(data: k1))
        var receiveState = CipherState()
        receiveState.setKey(SymmetricKey(data: k2))
        return (sendState, receiveState, finalHash)
    }

    // MARK: - Internals

    private struct IdentityPayload {
        let identityKey: Data
        let signature: Data

        static let wireSize = 32 + 64
        /// Wire size once AEAD-encrypted (ciphertext ‖ 16-byte tag).
        static let encryptedWireSize = wireSize + 16

        init(identityKey: Data, signature: Data) {
            self.identityKey = identityKey
            self.signature = signature
        }

        init(_ bytes: Data) throws {
            guard bytes.count == Self.wireSize else { throw NoiseError.invalidIdentityPayload }
            identityKey = bytes.prefix(32)
            signature = bytes.suffix(64)
        }

        func encoded() -> Data { identityKey + signature }

        static func parse(_ bytes: Data) throws -> IdentityPayload {
            try IdentityPayload(bytes)
        }
    }

    public struct ResponderIdentity: Equatable, Sendable {
        public let identityKey: Data
        public let staticKey: Data
        public let fingerprint: String
    }

    public struct InitiatorIdentity: Equatable, Sendable {
        public let identityKey: Data
        public let staticKey: Data
        public let fingerprint: String
    }

    private func verifyPayload(_ payload: IdentityPayload, staticKey: Curve25519.KeyAgreement.PublicKey) -> Bool {
        LinkIdentity.verify(
            identityKeyRaw: payload.identityKey,
            signature: payload.signature,
            signedData: staticKey.rawRepresentation
        )
    }

    private func requireEphemeral() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let e = ephemeralKey else { throw NoiseError.invalidMessageLength }
        return e
    }

    private func requireRemoteEphemeral() throws -> Curve25519.KeyAgreement.PublicKey {
        guard let e = remoteEphemeral else { throw NoiseError.invalidMessageLength }
        return e
    }

    private func requireRemoteStatic() throws -> Curve25519.KeyAgreement.PublicKey {
        guard let s = remoteStatic else { throw NoiseError.invalidMessageLength }
        return s
    }

    private mutating func mixKey(_ input: Data) {
        let output = Self.hkdf(ikm: input, salt: ck, outputLength: 64)
        ck = Data(output.prefix(32))
        k = SymmetricKey(data: Data(output.suffix(32)))
        nonce = 0
        h = Self.sha256(h + Data(output.suffix(32)))
    }

    private mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let key = k else {
            h = Self.sha256(h + plaintext)
            return plaintext
        }
        var cipher = CipherState(key: key)
        // Preserve the running nonce across calls without resetting.
        let ciphertext = try cipher.encryptWith(plaintext, key: key, nonce: nonce, aad: h)
        nonce &+= 1
        h = Self.sha256(h + ciphertext)
        return ciphertext
    }

    private mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let key = k else {
            h = Self.sha256(h + ciphertext)
            return ciphertext
        }
        var cipher = CipherState(key: key)
        let plaintext = try cipher.decryptWith(ciphertext, key: key, nonce: nonce, aad: h)
        nonce &+= 1
        h = Self.sha256(h + ciphertext)
        return plaintext
    }

    private func dh(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.withUnsafeBytes { Data($0) }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// HKDF-SHA256 (RFC 5869) implemented over CryptoKit HMAC for exact
    /// parity with the Android implementation.
    static func hkdf(ikm: Data, salt: Data, outputLength: Int) -> Data {
        let saltKey = SymmetricKey(data: salt.isEmpty ? Data(repeating: 0, count: 32) : salt)
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: saltKey)
        var okm = Data()
        var previousBlock = Data()
        var counter: UInt8 = 1
        while okm.count < outputLength {
            let block = HMAC<SHA256>.authenticationCode(
                for: previousBlock + Data([counter]),
                using: SymmetricKey(data: Data(prk))
            )
            let blockData = Data(block)
            okm.append(blockData)
            previousBlock = blockData
            counter &+= 1
        }
        return okm.prefix(outputLength)
    }
}

private extension CipherState {
    /// One-shot helpers used by the handshake cipher (nonce managed externally).
    mutating func encryptWith(_ plaintext: Data, key: SymmetricKey, nonce: UInt64, aad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
            authenticating: aad
        )
        // Re-wrap: `slice + slice` keeps the slice's non-zero startIndex on
        // this Foundation, and callers index the result absolutely.
        return Data(box.ciphertext + box.tag)
    }

    mutating func decryptWith(_ ciphertextWithTag: Data, key: SymmetricKey, nonce: UInt64, aad: Data) throws -> Data {
        guard ciphertextWithTag.count >= 16 else { throw NoiseError.decryptFailed }
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
            ciphertext: ciphertextWithTag.prefix(ciphertextWithTag.count - 16),
            tag: ciphertextWithTag.suffix(16)
        )
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}
