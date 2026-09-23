import Foundation

import LinkProtocol

public struct FileMetadata: Sendable, Equatable {
    public let fileId: String
    public let name: String
    public let size: Int64
    public let sha256: String
    public let mimeType: String

    public init(fileId: String, name: String, size: Int64, sha256: String, mimeType: String) {
        self.fileId = fileId
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.mimeType = mimeType
    }

    public static func parse(_ frame: Frame) -> FileMetadata? {
        guard frame.messageType == .fileHeader,
              let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let fileId = object["fileId"] as? String, !fileId.isEmpty,
              let name = object["name"] as? String,
              let size = (object["size"] as? NSNumber)?.int64Value,
              let sha256 = object["sha256"] as? String else {
            return nil
        }
        return FileMetadata(
            fileId: fileId,
            name: name,
            size: size,
            sha256: sha256,
            mimeType: object["mimeType"] as? String ?? "application/octet-stream"
        )
    }
}

public enum FileAckStatus: String, Sendable, Equatable {
    case success = "SUCCESS"
    case shaMismatch = "SHA_MISMATCH"
    case cancelled = "CANCELLED"
}

public enum FileAck {
    public static func frame(
        fileId: String,
        receivedBytes: Int64,
        status: FileAckStatus,
        streamId: UInt32
    ) throws -> Frame {
        let object: [String: Any] = [
            "fileId": fileId,
            "receivedBytes": receivedBytes,
            "status": status.rawValue
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return Frame(messageType: .fileAck, streamId: streamId, payload: [UInt8](data))
    }

    public static func parse(_ frame: Frame) -> (fileId: String, receivedBytes: Int64, status: FileAckStatus)? {
        guard frame.messageType == .fileAck,
              let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let fileId = object["fileId"] as? String,
              let receivedBytes = (object["receivedBytes"] as? NSNumber)?.int64Value,
              let statusRaw = object["status"] as? String,
              let status = FileAckStatus(rawValue: statusRaw) else {
            return nil
        }
        return (fileId: fileId, receivedBytes: receivedBytes, status: status)
    }
}
