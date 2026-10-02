import Foundation

import LinkSecurity

public enum FileReceiverError: Error, Equatable {
    case cannotCreateFile
    case noActiveTransfer
}

/// Serial background writer owning the file handle, hash and byte count so
/// chunk writes never block the main actor. Created and observed from
/// `FileReceiver`, which funnels all access through a single sequential
/// await chain (frames are processed one at a time, preserving byte order).
private actor FileWriteWorker {
    private let handle: FileHandle
    private var hasher = IncrementalHash()
    private var receivedBytes: Int64 = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        hasher.update(data)
        receivedBytes += Int64(data.count)
    }

    func finish() -> (digest: String, receivedBytes: Int64) {
        try? handle.close()
        return (hasher.finalizeHex(), receivedBytes)
    }

    func close() {
        try? handle.close()
    }
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
    private var worker: FileWriteWorker?
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

    public func begin(_ metadata: FileMetadata, in directory: URL) async throws -> Progress {
        await abandon()
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
        worker = FileWriteWorker(handle: newHandle)
        receivedBytes = 0
        finishedAck = .success

        if metadata.size <= 0 {
            return try await finalize()
        }
        return Progress(metadata: metadata, receivedBytes: 0, state: .receiving)
    }

    public func append(_ chunk: FileChunk) async throws -> AppendOutcome? {
        guard let active = metadata, let writeWorker = worker else { return nil }
        let data = chunk.data
        try await writeWorker.append(data)
        receivedBytes += Int64(data.count)

        if receivedBytes >= active.size {
            return .finished(try await finalize(), ack: finishedAck)
        }
        return .receiving(Progress(metadata: active, receivedBytes: receivedBytes, state: .receiving))
    }

    public func abandon() async {
        if let writeWorker = worker {
            await writeWorker.close()
        }
        worker = nil
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
        metadata = nil
    }

    private func finalize() async throws -> Progress {
        guard let active = metadata, let url = fileURL, let writeWorker = worker else {
            throw FileReceiverError.noActiveTransfer
        }
        let result = await writeWorker.finish()
        worker = nil

        metadata = nil
        fileURL = nil
        receivedBytes = result.receivedBytes

        if result.digest.caseInsensitiveCompare(active.sha256) == .orderedSame {
            finishedAck = .success
            return Progress(metadata: active, receivedBytes: result.receivedBytes, state: .completed)
        }
        try? FileManager.default.removeItem(at: url)
        finishedAck = .shaMismatch
        return Progress(metadata: active, receivedBytes: result.receivedBytes, state: .failed("SHA-256 mismatch"))
    }
}
