import CryptoKit
import Foundation

/// Long-term cryptographic identity: an X25519 static key for the Noise
/// handshake plus an Ed25519 signing key whose public half is the pinned
/// fingerprint. Both private halves persist in the Keychain.
public struct LinkIdentity: Sendable {
    public let staticKey: Curve25519.KeyAgreement.PrivateKey
    public let signingKey: Curve25519.Signing.PrivateKey

    public init(staticKey: Curve25519.KeyAgreement.PrivateKey, signingKey: Curve25519.Signing.PrivateKey) {
        self.staticKey = staticKey
        self.signingKey = signingKey
    }

    /// Loads the persisted identity, creating and storing one if absent.
    public static func load(service: String = "PocketLink") throws -> LinkIdentity {
        let staticKey: Curve25519.KeyAgreement.PrivateKey
        if let data = keychainData(account: "noise-static-x25519", service: service) {
            staticKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            try saveKeychainData(key.rawRepresentation, account: "noise-static-x25519", service: service)
            staticKey = key
        }

        let signingKey: Curve25519.Signing.PrivateKey
        if let data = keychainData(account: "identity-ed25519", service: service) {
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } else {
            let key = Curve25519.Signing.PrivateKey()
            try saveKeychainData(key.rawRepresentation, account: "identity-ed25519", service: service)
            signingKey = key
        }

        return LinkIdentity(staticKey: staticKey, signingKey: signingKey)
    }

    public var signingPublicKeyRaw: Data {
        signingKey.publicKey.rawRepresentation
    }

    public var staticPublicKeyRaw: Data {
        staticKey.publicKey.rawRepresentation
    }

    /// SHA-256 fingerprint of the Ed25519 identity key, lowercase hex.
    public var fingerprint: String {
        Self.fingerprint(for: signingPublicKeyRaw)
    }

    public static func fingerprint(for identityKeyRaw: Data) -> String {
        SecurityHash.hex(identityKeyRaw)
    }

    /// Signs our Noise static public key with the Ed25519 identity key.
    public func sign(staticKeyData: Data) throws -> Data {
        try signingKey.signature(for: staticKeyData)
    }

    /// Verifies an identity/static binding: `signature` over `signedData`
    /// (the peer's static X25519 public key) made by `identityKeyRaw`.
    public static func verify(identityKeyRaw: Data, signature: Data, signedData: Data) -> Bool {
        guard let identityKey = try? Curve25519.Signing.PublicKey(rawRepresentation: identityKeyRaw) else {
            return false
        }
        return (try? identityKey.isValidSignature(signature, for: signedData)) ?? false
    }

    // MARK: - Keychain

    private static func keychainData(account: String, service: String) -> Data? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func saveKeychainData(_ data: Data, account: String, service: String) throws {
        var query = baseQuery(account: account, service: service)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data] as CFDictionary
            SecItemUpdate(baseQuery(account: account, service: service) as CFDictionary, update)
        }
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
