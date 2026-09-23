import Foundation

import CryptoKit

public enum SecurityHash {
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct IncrementalHash {
    private var hasher = SHA256()

    public init() {}

    public mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    public mutating func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
