import XCTest

import LinkConnection
import LinkProtocol
import LinkSecurity

@testable import LinkFiles

/// Loopback server that pushes a small file transfer (FILE_HEADER +
/// FILE_CHUNK) as soon as the encrypted channel is up, then records the
/// FILE_ACK it receives.
final class FileServerStub: CryptoLoopbackServer, @unchecked Sendable {
    private let payload: Data
    private let fileId: String
    private let ackExpectation: XCTestExpectation
    private var receivedAckValue: (fileId: String, receivedBytes: Int64, status: String)?

    init(payload: Data, fileId: String, ackExpectation: XCTestExpectation) {
        self.payload = payload
        self.fileId = fileId
        self.ackExpectation = ackExpectation
        try! super.init(label: "file-server-stub")
    }

    var receivedAck: (fileId: String, receivedBytes: Int64, status: String)? {
        queue.sync { receivedAckValue }
    }

    override func onChannelReady() {
        let header: [String: Any] = [
            "fileId": fileId,
            "name": "integration.txt",
            "size": payload.count,
            "sha256": SecurityHash.hex(payload),
            "mimeType": "text/plain"
        ]
        let headerData = try! JSONSerialization.data(withJSONObject: header)
        sealAndSend(Frame(messageType: .fileHeader, streamId: 1, payload: [UInt8](headerData)))
        sealAndSend(
            Frame(
                messageType: .fileChunk,
                streamId: 2,
                payload: FileChunk.headerBytes(fileIdHash: JavaStringHash.hash(fileId), offset: 0) + [UInt8](payload)
            )
        )
    }

    override func handlePlaintext(_ frame: Frame) {
        guard frame.messageType == .fileAck, let ack = FileAck.parse(frame) else { return }
        receivedAckValue = (fileId: ack.fileId, receivedBytes: ack.receivedBytes, status: ack.status.rawValue)
        ackExpectation.fulfill()
    }
}

@MainActor
final class FileTransferIntegrationTests: XCTestCase {
    func testReceiveFileAndAckOverLoopbackTCP() async throws {
        let payload = Data("hello integration world".utf8)
        let ackExpectation = expectation(description: "server received FILE_ACK")
        let server = FileServerStub(payload: payload, fileId: "abc12345", ackExpectation: ackExpectation)
        let port = try server.awaitBoundPort()
        defer { server.stop() }

        let client = LinkClient()
        try await client.connect(host: "127.0.0.1", port: port)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-it-\(UUID().uuidString)", isDirectory: true)
        let receiver = FileReceiver()
        var sentAck = false

        for await frame in client.frames {
            switch frame.messageType {
            case .fileHeader:
                if let metadata = FileMetadata.parse(frame) {
                    _ = try await receiver.begin(metadata, in: directory)
                }
            case .fileChunk:
                guard let chunk = FileChunk.parse(frame) else { continue }
                let appended = try await receiver.append(chunk)
                guard case .finished(let progress, let ack) = try XCTUnwrap(appended) else { continue }
                try await client.send(
                    FileAck.frame(
                        fileId: progress.metadata.fileId,
                        receivedBytes: progress.receivedBytes,
                        status: ack,
                        streamId: client.nextStreamId()
                    )
                )
                sentAck = true
            default:
                break
            }
            if sentAck { break }
        }

        XCTAssertTrue(sentAck)
        await fulfillment(of: [ackExpectation], timeout: 20)
        XCTAssertEqual(server.receivedAck?.fileId, "abc12345")
        XCTAssertEqual(server.receivedAck?.receivedBytes, Int64(payload.count))
        XCTAssertEqual(server.receivedAck?.status, "SUCCESS")

        let fileURL = FileReceiver.fileURL(
            for: FileMetadata(fileId: "abc12345", name: "integration.txt", size: Int64(payload.count), sha256: "", mimeType: "text/plain"),
            in: directory
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), payload)
        try? FileManager.default.removeItem(at: directory)
        await client.disconnect()
    }
}
