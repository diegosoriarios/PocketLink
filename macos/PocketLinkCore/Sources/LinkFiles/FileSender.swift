import Foundation
import UniformTypeIdentifiers

import LinkConnection
import LinkProtocol
import LinkSecurity

public protocol FrameSending: Sendable {
    func send(_ frame: Frame) async throws
    func nextStreamId() async -> UInt32
}

extension LinkClient: FrameSending {}

public enum FileSenderError: Error, Equatable {
    case notARegularFile
    case unreadable
    case sizeMismatch(declared: Int64, actual: Int64)
}

public enum FileSender {
    public static let chunkSize = 64 * 1024

    public static func prepare(fileURL: URL) throws -> FileMetadata {
        let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resourceValues.isRegularFile != false else {
            throw FileSenderError.notARegularFile
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw FileSenderError.unreadable
        }
        defer { try? handle.close() }
        var hasher = IncrementalHash()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
            total += Int64(chunk.count)
        }
        return FileMetadata(
            fileId: UUID().uuidString.prefix(8).lowercased(),
            name: fileURL.lastPathComponent,
            size: total,
            sha256: hasher.finalizeHex(),
            mimeType: mimeType(for: fileURL)
        )
    }

    public static func mimeType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    public static func send(
        fileURL: URL,
        metadata: FileMetadata,
        to sender: some FrameSending,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        try await sendHeader(metadata, to: sender)

        do {
            guard metadata.size > 0 else {
                onProgress?(0)
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                throw FileSenderError.unreadable
            }
            defer { try? handle.close() }

            var offset: Int64 = 0
            while true {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try await sender.send(
                    FileChunk.chunkFrame(
                        fileId: metadata.fileId,
                        offset: offset,
                        data: chunk,
                        streamId: await sender.nextStreamId()
                    )
                )
                offset += Int64(chunk.count)
                onProgress?(offset)
            }
            guard offset == metadata.size else {
                throw FileSenderError.sizeMismatch(declared: metadata.size, actual: offset)
            }
        } catch {
            await sendCancelBestEffort(fileId: metadata.fileId, to: sender)
            throw error
        }
    }

    public static func cancelFrame(fileId: String, streamId: UInt32) throws -> Frame {
        let data = try JSONSerialization.data(withJSONObject: ["fileId": fileId])
        return Frame(messageType: .fileCancel, streamId: streamId, payload: [UInt8](data))
    }

    private static func sendCancelBestEffort(fileId: String, to sender: some FrameSending) async {
        guard let frame = try? cancelFrame(fileId: fileId, streamId: 0) else { return }
        Task { try? await sender.send(frame) }
    }

    private static func sendHeader(_ metadata: FileMetadata, to sender: some FrameSending) async throws {
        let object: [String: Any] = [
            "fileId": metadata.fileId,
            "name": metadata.name,
            "size": metadata.size,
            "sha256": metadata.sha256,
            "mimeType": metadata.mimeType
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try await sender.send(
            Frame(
                messageType: .fileHeader,
                streamId: await sender.nextStreamId(),
                payload: [UInt8](data)
            )
        )
    }
}
