import Foundation

public enum LinkProtocolConstants {
    public static let magicASCII = "LINK"
    public static let magicBytes: [UInt8] = Array(magicASCII.utf8)
    public static let headerSize = 16
    /// Frame header version — unchanged since v1; the framing never changed.
    public static let protocolVersion: UInt16 = 1
    /// HANDSHAKE `protocolVersion` field: 2 = encrypted transport required.
    public static let handshakeVersion = 2
    public static let maxPayloadSize: UInt32 = 8_388_608
}
