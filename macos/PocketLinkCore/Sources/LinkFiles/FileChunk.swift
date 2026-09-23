import Foundation

import LinkProtocol

public struct FileChunk: Sendable, Equatable {
    public static let headerSize = 12

    public let fileIdHash: Int32
    public let offset: Int64
    public let data: Data

    public init(fileIdHash: Int32, offset: Int64, data: Data) {
        self.fileIdHash = fileIdHash
        self.offset = offset
        self.data = data
    }

    public static func parse(_ frame: Frame) -> FileChunk? {
        guard frame.messageType == .fileChunk, frame.payload.count >= headerSize else { return nil }
        let payload = frame.payload
        let hash = Int32(
            bitPattern: UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16
                | UInt32(payload[2]) << 8 | UInt32(payload[3])
        )
        var offsetBits: UInt64 = 0
        for byte in payload[4..<12] {
            offsetBits = offsetBits << 8 | UInt64(byte)
        }
        return FileChunk(
            fileIdHash: hash,
            offset: Int64(bitPattern: offsetBits),
            data: Data(payload[12...])
        )
    }

    public static func headerBytes(fileIdHash: Int32, offset: Int64) -> [UInt8] {
        let hashBits = UInt32(bitPattern: fileIdHash)
        let offsetBits = UInt64(bitPattern: offset)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerSize)
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8((hashBits >> UInt32(shift)) & 0xFF))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((offsetBits >> UInt64(shift)) & 0xFF))
        }
        return bytes
    }

    public static func chunkFrame(fileId: String, offset: Int64, data: Data, streamId: UInt32) -> Frame {
        Frame(
            messageType: .fileChunk,
            streamId: streamId,
            payload: headerBytes(fileIdHash: JavaStringHash.hash(fileId), offset: offset) + [UInt8](data)
        )
    }

    public func matches(fileId: String) -> Bool {
        fileIdHash == JavaStringHash.hash(fileId)
    }
}
