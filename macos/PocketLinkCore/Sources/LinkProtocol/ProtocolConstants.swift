import Foundation

public enum LinkProtocolConstants {
    public static let magicASCII = "LINK"
    public static let magicBytes: [UInt8] = Array(magicASCII.utf8)
    public static let headerSize = 16
    public static let protocolVersion: UInt16 = 1
    public static let maxPayloadSize: UInt32 = 8_388_608
}
