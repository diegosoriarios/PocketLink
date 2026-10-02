import Network
import XCTest

import LinkConnection
import LinkProtocol
import LinkSecurity

@testable import LinkFiles

final class FileSenderTests: XCTestCase {
    private func tempFile(name: String, content: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sender-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try content.write(to: url)
        return url
    }

    func testPrepareComputesMetadataFromContent() throws {
        let content = Data("hello world".utf8)
        let url = try tempFile(name: "notes.txt", content: content)
        let metadata = try FileSender.prepare(fileURL: url)
        XCTAssertEqual(metadata.name, "notes.txt")
        XCTAssertEqual(metadata.size, 11)
        XCTAssertEqual(metadata.sha256, SecurityHash.hex(content))
        XCTAssertEqual(metadata.mimeType, "text/plain")
        XCTAssertEqual(metadata.fileId.count, 8)
        XCTAssertEqual(metadata.fileId, metadata.fileId.lowercased())
    }

    func testPrepareHashesWithoutLoadingWholeFile() throws {
        let chunk = Data(repeating: 0xAB, count: 1_000_000)
        var hasher = IncrementalHash()
        for _ in 0..<3 { hasher.update(chunk) }
        let url = try tempFile(name: "big.bin", content: chunk + chunk + chunk)
        let metadata = try FileSender.prepare(fileURL: url)
        XCTAssertEqual(metadata.size, 3_000_000)
        XCTAssertEqual(metadata.sha256, hasher.finalizeHex())
    }

    func testUnknownExtensionFallsBackToOctetStream() throws {
        let url = try tempFile(name: "archive.xqzunknown", content: Data([0x00]))
        XCTAssertEqual(try FileSender.prepare(fileURL: url).mimeType, "application/octet-stream")
    }

    func testPrepareRejectsMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).txt")
        XCTAssertThrowsError(try FileSender.prepare(fileURL: missing))
    }

    func testMimeTypesForCommonExtensions() {
        XCTAssertEqual(FileSender.mimeType(for: URL(fileURLWithPath: "/tmp/a.png")), "image/png")
        XCTAssertEqual(FileSender.mimeType(for: URL(fileURLWithPath: "/tmp/a.pdf")), "application/pdf")
        XCTAssertEqual(FileSender.mimeType(for: URL(fileURLWithPath: "/tmp/a.unknownext")), "application/octet-stream")
    }
}

final class FileReceiverStub: CryptoLoopbackServer, @unchecked Sendable {
    private let ackExpectation: XCTestExpectation
    private var received = Data()
    private var metadata: (fileId: String, size: Int64, sha256: String)?
    private var sentAckStatusValue: String?
    private var sentAckBytesValue: Int64 = -1

    init(ackExpectation: XCTestExpectation) {
        self.ackExpectation = ackExpectation
        try! super.init(label: "file-receiver-stub")
    }

    var sentAckStatus: String? {
        queue.sync { sentAckStatusValue }
    }

    var sentAckBytes: Int64 {
        queue.sync { sentAckBytesValue }
    }

    override func handlePlaintext(_ frame: Frame) {
        switch frame.messageType {
        case .fileHeader:
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
                let fileId = object["fileId"] as? String,
                let size = (object["size"] as? NSNumber)?.int64Value,
                let sha256 = object["sha256"] as? String
            else { return }
            metadata = (fileId: fileId, size: size, sha256: sha256)
        case .fileChunk:
            guard let chunk = FileChunk.parse(frame), let active = metadata else { return }
            received.append(chunk.data)
            if Int64(received.count) >= active.size {
                finish(fileId: active.fileId, sha256: active.sha256)
            }
        default:
            break
        }
    }

    private func finish(fileId: String, sha256: String) {
        let digest = SecurityHash.hex(received)
        let status: FileAckStatus = digest.caseInsensitiveCompare(sha256) == .orderedSame ? .success : .shaMismatch
        sentAckStatusValue = status.rawValue
        sentAckBytesValue = Int64(received.count)
        guard let ackFrame = try? FileAck.frame(fileId: fileId, receivedBytes: sentAckBytesValue, status: status, streamId: 99) else {
            return
        }
        sealAndSend(ackFrame)
        ackExpectation.fulfill()
    }
}

@MainActor
final class FileSendIntegrationTests: XCTestCase {
    func testSendFileOverLoopbackAndReceiveAck() async throws {
        let content = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-it-\(UUID().uuidString)-sample.bin")
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let ackExpectation = expectation(description: "stub sent FILE_ACK")
        let server = FileReceiverStub(ackExpectation: ackExpectation)
        let port = try server.awaitBoundPort()
        defer { server.stop() }

        let client = LinkClient()
        try await client.connect(host: "127.0.0.1", port: port)
        defer { Task { await client.disconnect() } }

        let metadata = try FileSender.prepare(fileURL: url)
        let progress = ProgressBox()
        try await FileSender.send(fileURL: url, metadata: metadata, to: client) { sent in
            progress.set(sent)
        }

        await fulfillment(of: [ackExpectation], timeout: 20)
        XCTAssertEqual(server.sentAckStatus, "SUCCESS")
        XCTAssertEqual(server.sentAckBytes, Int64(content.count))
        XCTAssertEqual(progress.get(), Int64(content.count))
    }
}

final class SlowDrainStub: CryptoLoopbackServer, @unchecked Sendable {
    private var bytesDrained = 0
    private var timer: DispatchSourceTimer?
    private var inboundFrames: [Frame] = []

    init() throws {
        try! super.init(label: "slow-drain-stub")
    }

    var drainedBytes: Int {
        queue.sync { bytesDrained }
    }

    var receivedFrames: [Frame] {
        queue.sync { inboundFrames }
    }

    override func stop() {
        queue.sync {
            timer?.cancel()
            connection?.cancel()
            listener.cancel()
        }
    }

    override func startReceiving(_ connection: NWConnection) {
        scheduleDrain(connection)
    }

    override func consume(_ data: Data) {
        bytesDrained += data.count
        super.consume(data)
    }

    override func handlePlaintext(_ frame: Frame) {
        inboundFrames.append(frame)
    }

    private func scheduleDrain(_ connection: NWConnection) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + DispatchTimeInterval.milliseconds(50), repeating: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self, let connection = self.connection else { return }
            self.receiveOnce(connection)
            self.scheduleDrain(connection)
        }
        source.resume()
        timer = source
    }
}

@MainActor
final class FileSendCancellationTests: XCTestCase {
    func testCancelMidSendStopsTransferAndThrowsCancellationError() async throws {
        let content = Data(repeating: 0x5A, count: 12 * 1024 * 1024)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-me-\(UUID().uuidString).bin")
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let stub = try SlowDrainStub()
        let port = try stub.awaitBoundPort()
        defer { stub.stop() }

        let client = LinkClient()
        try await client.connect(host: "127.0.0.1", port: port)
        defer { Task { await client.disconnect() } }

        let metadata = try FileSender.prepare(fileURL: url)
        let sendTask = Task {
            try await FileSender.send(fileURL: url, metadata: metadata, to: client)
        }

        try await Task.sleep(for: .seconds(1))
        sendTask.cancel()

        do {
            _ = try await sendTask.value
            XCTFail("cancelled send must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(
            Int64(stub.drainedBytes),
            metadata.size,
            "stub cannot have received the whole file"
        )

        var received: Frame?
        let deadline = Date().addingTimeInterval(10)
        while received == nil && Date() < deadline {
            received = stub.receivedFrames.first { $0.messageType == .fileCancel }
            if received == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let cancelFrame = try XCTUnwrap(received, "cancelled send must deliver a FILE_CANCEL frame")
        XCTAssertEqual(cancelFrame.streamId, 0)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(cancelFrame.payload))) as? [String: Any],
            "FILE_CANCEL payload must be a JSON object"
        )
        let fileId = try XCTUnwrap(object["fileId"] as? String)
        XCTAssertEqual(fileId, metadata.fileId)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func set(_ newValue: Int64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
