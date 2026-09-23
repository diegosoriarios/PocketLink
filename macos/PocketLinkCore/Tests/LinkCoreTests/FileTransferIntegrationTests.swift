import Network
import XCTest

import LinkConnection
import LinkProtocol
import LinkSecurity

@testable import LinkFiles

final class FileServerStub: @unchecked Sendable {
    private let queue = DispatchQueue(label: "file-server-stub")
    private let payload: Data
    private let fileId: String
    private let ackExpectation: XCTestExpectation
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private(set) var receivedAck: (fileId: String, receivedBytes: Int64, status: String)?

    init(payload: Data, fileId: String, ackExpectation: XCTestExpectation) {
        self.payload = payload
        self.fileId = fileId
        self.ackExpectation = ackExpectation
    }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        for _ in 0..<500 {
            if let port = listener.port?.rawValue, port != 0 {
                self.listener = listener
                return port
            }
            usleep(10_000)
        }
        listener.cancel()
        throw NSError(domain: "FileServerStub", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener never bound"])
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.sendTransfer()
            }
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    private func sendTransfer() {
        let header: [String: Any] = [
            "fileId": fileId,
            "name": "integration.txt",
            "size": payload.count,
            "sha256": SecurityHash.hex(payload),
            "mimeType": "text/plain"
        ]
        let headerData = try! JSONSerialization.data(withJSONObject: header)
        send(Frame(messageType: .fileHeader, streamId: 1, payload: [UInt8](headerData)))
        send(Frame(messageType: .fileChunk, streamId: 2, payload: FileChunk.headerBytes(fileIdHash: JavaStringHash.hash(fileId), offset: 0) + [UInt8](payload)))
    }

    private func send(_ frame: Frame) {
        guard let connection else { return }
        let data = Data(try! FrameEncoder.encode(frame))
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                FileHandle.standardError.write(Data("stub send error: \(error)\n".utf8))
            }
        })
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                do {
                    for frame in try self.decoder.feed([UInt8](data)) {
                        if frame.messageType == .fileAck, let ack = FileAck.parse(frame) {
                            receivedAck = (fileId: ack.fileId, receivedBytes: ack.receivedBytes, status: ack.status.rawValue)
                            ackExpectation.fulfill()
                        }
                    }
                } catch {
                    FileHandle.standardError.write(Data("stub decode error: \(error)\n".utf8))
                }
            }
            if error == nil {
                receiveLoop()
            }
        }
    }
}

@MainActor
final class FileTransferIntegrationTests: XCTestCase {
    func testReceiveFileAndAckOverLoopbackTCP() async throws {
        let payload = Data("hello integration world".utf8)
        let ackExpectation = expectation(description: "server received FILE_ACK")
        let server = FileServerStub(payload: payload, fileId: "abc12345", ackExpectation: ackExpectation)
        let port = try server.start()
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
                    _ = try receiver.begin(metadata, in: directory)
                }
            case .fileChunk:
                guard let chunk = FileChunk.parse(frame) else { continue }
                guard case .finished(let progress, let ack) = try XCTUnwrap(receiver.append(chunk)) else { continue }
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
