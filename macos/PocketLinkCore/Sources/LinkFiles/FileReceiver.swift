import Foundation

import LinkSecurity

public enum FileReceiverError: Error, Equatable {
    case cannotCreateFile
    case noActiveTransfer
}

@MainActor
public final class FileReceiver {
    public struct Progress: Identifiable, Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case receiving
            case completed
            case failed(String)
        }

        public var id: String { metadata.fileId }
        public let metadata: FileMetadata
        public let receivedBytes: Int64
        public let state: State
    }

    public enum AppendOutcome: Sendable, Equatable {
        case receiving(Progress)
        case finished(Progress, ack: FileAckStatus)
    }

    private var metadata: FileMetadata?
    private var fileURL: URL?
    private var handle: FileHandle?
    private var hasher = IncrementalHash()
    private var receivedBytes: Int64 = 0
    private var finishedAck: FileAckStatus = .success

    public init() {}

    public static func sanitizedFileName(for metadata: FileMetadata) -> String {
        var name = metadata.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        if name.isEmpty { name = "file" }
        return "\(metadata.fileId)_\(name)"
    }

    public static func fileURL(for metadata: FileMetadata, in directory: URL) -> URL {
        directory.appendingPathComponent(sanitizedFileName(for: metadata))
    }

    public func begin(_ metadata: FileMetadata, in directory: URL) throws -> Progress {
        abandon()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = Self.fileURL(for: metadata, in: directory)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FileReceiverError.cannotCreateFile
        }
        guard let newHandle = try? FileHandle(forWritingTo: url) else {
            try? FileManager.default.removeItem(at: url)
            throw FileReceiverError.cannotCreateFile
        }

        self.metadata = metadata
        fileURL = url
        handle = newHandle
        hasher = IncrementalHash()
        receivedBytes = 0
        finishedAck = .success

        if metadata.size <= 0 {
            return try finalize()
        }
        return Progress(metadata: metadata, receivedBytes: 0, state: .receiving)
    }

    public func append(_ chunk: FileChunk) throws -> AppendOutcome? {
        guard let active = metadata, let openHandle = handle else { return nil }
        let data = chunk.data
        if !data.isEmpty {
            try openHandle.write(contentsOf: data)
            hasher.update(data)
        }
        receivedBytes += Int64(data.count)

        if receivedBytes >= active.size {
            return .finished(try finalize(), ack: finishedAck)
        }
        return .receiving(Progress(metadata: active, receivedBytes: receivedBytes, state: .receiving))
    }

    public func abandon() {
        if let openHandle = handle {
            try? openHandle.close()
        }
        handle = nil
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
        metadata = nil
    }

    private func finalize() throws -> Progress {
        guard let active = metadata, let url = fileURL else {
            throw FileReceiverError.noActiveTransfer
        }
        if let openHandle = handle {
            try? openHandle.close()
        }
        handle = nil
        let digest = hasher.finalizeHex()

        metadata = nil
        fileURL = nil

        if digest.caseInsensitiveCompare(active.sha256) == .orderedSame {
            finishedAck = .success
            return Progress(metadata: active, receivedBytes: receivedBytes, state: .completed)
        }
        try? FileManager.default.removeItem(at: url)
        finishedAck = .shaMismatch
        return Progress(metadata: active, receivedBytes: receivedBytes, state: .failed("SHA-256 mismatch"))
    }
}
