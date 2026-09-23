import XCTest

import LinkProtocol
import LinkSecurity

@testable import LinkFiles

final class SecurityHashTests: XCTestCase {
    func testKnownVectorForAbc() {
        XCTAssertEqual(
            SecurityHash.hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testIncrementalMatchesOneShot() {
        let parts = ["hello ", "world", " 📋"].map { Data($0.utf8) }
        var incremental = IncrementalHash()
        for part in parts {
            incremental.update(part)
        }
        let expected = SecurityHash.hex(Data("hello world 📋".utf8))
        XCTAssertEqual(incremental.finalizeHex(), expected)
    }
}

final class FileMetadataTests: XCTestCase {
    private let json = #"{"fileId":"abc12345","name":"report.pdf","size":9007199254740993,"sha256":"DEADBEEF","mimeType":"application/pdf"}"#

    func testParseFullHeader() throws {
        let frame = Frame(messageType: .fileHeader, streamId: 3, payload: [UInt8](json.utf8))
        let metadata = try XCTUnwrap(FileMetadata.parse(frame))
        XCTAssertEqual(metadata.fileId, "abc12345")
        XCTAssertEqual(metadata.name, "report.pdf")
        XCTAssertEqual(metadata.size, 9_007_199_254_740_993)
        XCTAssertEqual(metadata.sha256, "DEADBEEF")
        XCTAssertEqual(metadata.mimeType, "application/pdf")
    }

    func testParseDefaultsMimeType() throws {
        let frame = Frame(
            messageType: .fileHeader,
            streamId: 0,
            payload: [UInt8](#"{"fileId":"x1","name":"a.bin","size":1,"sha256":"ff"}"#.utf8)
        )
        let metadata = try XCTUnwrap(FileMetadata.parse(frame))
        XCTAssertEqual(metadata.mimeType, "application/octet-stream")
    }

    func testParseRejectsMissingOrInvalidFields() {
        XCTAssertNil(FileMetadata.parse(Frame(messageType: .fileHeader, streamId: 0, payload: [])))
        XCTAssertNil(
            FileMetadata.parse(
                Frame(messageType: .fileHeader, streamId: 0, payload: [UInt8](#"{"name":"a","size":1,"sha256":"ff"}"#.utf8))
            )
        )
        XCTAssertNil(
            FileMetadata.parse(
                Frame(messageType: .fileHeader, streamId: 0, payload: [UInt8](#"{"fileId":"","name":"a","size":1,"sha256":"ff"}"#.utf8))
            )
        )
        XCTAssertNil(
            FileMetadata.parse(
                Frame(messageType: .clipboard, streamId: 0, payload: [UInt8](json.utf8))
            )
        )
    }
}

final class FileChunkTests: XCTestCase {
    func testHeaderBytesBigEndianLayout() {
        let bytes = FileChunk.headerBytes(fileIdHash: 0x01020304, offset: 0x0102030405060708)
        XCTAssertEqual(bytes, [0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }

    func testParseSplitsHeaderAndData() throws {
        let data = Data("hello".utf8)
        let frame = Frame(
            messageType: .fileChunk,
            streamId: 9,
            payload: FileChunk.headerBytes(fileIdHash: JavaStringHash.hash("abc12345"), offset: 64) + [UInt8](data)
        )
        let chunk = try XCTUnwrap(FileChunk.parse(frame))
        XCTAssertEqual(chunk.fileIdHash, JavaStringHash.hash("abc12345"))
        XCTAssertEqual(chunk.offset, 64)
        XCTAssertEqual(chunk.data, data)
        XCTAssertTrue(chunk.matches(fileId: "abc12345"))
        XCTAssertFalse(chunk.matches(fileId: "other"))
    }

    func testNegativeHashAndLargeOffsetRoundTrip() throws {
        let frame = FileChunk.chunkFrame(fileId: "abc12345", offset: 4_294_967_296, data: Data([0x01, 0x02]), streamId: 1)
        let chunk = try XCTUnwrap(FileChunk.parse(frame))
        XCTAssertTrue(chunk.matches(fileId: "abc12345"))
        XCTAssertEqual(chunk.offset, 4_294_967_296)
        XCTAssertEqual(chunk.data, Data([0x01, 0x02]))
    }

    func testParseRejectsShortWrongTypeAndEmpty() {
        XCTAssertNil(FileChunk.parse(Frame(messageType: .fileChunk, streamId: 0, payload: [0, 1, 2])))
        XCTAssertNil(
            FileChunk.parse(
                Frame(messageType: .ping, streamId: 0, payload: FileChunk.headerBytes(fileIdHash: 1, offset: 0))
            )
        )
        XCTAssertNil(FileChunk.parse(Frame(messageType: .fileChunk, streamId: 0, payload: [])))
    }
}

final class FileAckTests: XCTestCase {
    func testFrameMatchesAndroidSchema() throws {
        let frame = try FileAck.frame(fileId: "abc12345", receivedBytes: 4096, status: .success, streamId: 5)
        XCTAssertEqual(frame.messageType, .fileAck)
        XCTAssertEqual(frame.streamId, 5)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any]
        )
        XCTAssertEqual(object["fileId"] as? String, "abc12345")
        XCTAssertEqual((object["receivedBytes"] as? NSNumber)?.int64Value, 4096)
        XCTAssertEqual(object["status"] as? String, "SUCCESS")
    }

    func testParseRoundTripsAllStatuses() {
        for status in [FileAckStatus.success, .shaMismatch, .cancelled] {
            let frame = try! FileAck.frame(fileId: "f1", receivedBytes: 7, status: status, streamId: 0)
            let parsed = FileAck.parse(frame)
            XCTAssertEqual(parsed?.fileId, "f1")
            XCTAssertEqual(parsed?.receivedBytes, 7)
            XCTAssertEqual(parsed?.status, status)
        }
    }

    func testParseRejectsUnknownStatusAndWrongType() {
        let frame = Frame(
            messageType: .fileAck,
            streamId: 0,
            payload: [UInt8](#"{"fileId":"f1","receivedBytes":1,"status":"WHAT"}"#.utf8)
        )
        XCTAssertNil(FileAck.parse(frame))
        XCTAssertNil(
            FileAck.parse(Frame(messageType: .ping, streamId: 0, payload: frame.payload))
        )
    }
}

@MainActor
final class FileReceiverTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("receiver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func metadata(size: Int64, sha256: String, name: String = "notes.txt", fileId: String = "abc12345") -> FileMetadata {
        FileMetadata(fileId: fileId, name: name, size: size, sha256: sha256, mimeType: "text/plain")
    }

    func testHappyPathCompletesWithSuccessAndCorrectContent() throws {
        let directory = try tempDirectory()
        let payload = Data("hello world".utf8)
        let receiver = FileReceiver()
        let started = try receiver.begin(metadata(size: Int64(payload.count), sha256: SecurityHash.hex(payload)), in: directory)
        XCTAssertEqual(started.state, .receiving)
        XCTAssertEqual(started.receivedBytes, 0)

        let outcome = try XCTUnwrap(receiver.append(FileChunk(fileIdHash: JavaStringHash.hash("abc12345"), offset: 0, data: payload)))
        guard case .finished(let progress, let ack) = outcome else {
            return XCTFail("Expected finished outcome")
        }
        XCTAssertEqual(ack, .success)
        XCTAssertEqual(progress.state, .completed)
        XCTAssertEqual(progress.receivedBytes, Int64(payload.count))

        let fileURL = FileReceiver.fileURL(for: started.metadata, in: directory)
        XCTAssertEqual(try Data(contentsOf: fileURL), payload)
    }

    func testShaMismatchFailsAndDeletesFile() throws {
        let directory = try tempDirectory()
        let receiver = FileReceiver()
        let started = try receiver.begin(metadata(size: 3, sha256: "00"), in: directory)
        let outcome = try XCTUnwrap(receiver.append(FileChunk(fileIdHash: JavaStringHash.hash("abc12345"), offset: 0, data: Data("abc".utf8))))
        guard case .finished(let progress, let ack) = outcome else {
            return XCTFail("Expected finished outcome")
        }
        XCTAssertEqual(ack, .shaMismatch)
        guard case .failed(let reason) = progress.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(reason, "SHA-256 mismatch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileReceiver.fileURL(for: started.metadata, in: directory).path))
    }

    func testEmptyFileCompletesOnBegin() throws {
        let directory = try tempDirectory()
        let receiver = FileReceiver()
        let progress = try receiver.begin(metadata(size: 0, sha256: SecurityHash.hex(Data())), in: directory)
        XCTAssertEqual(progress.state, .completed)
        let fileURL = FileReceiver.fileURL(for: progress.metadata, in: directory)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data())
    }

    func testNewHeaderAbandonsPreviousTransfer() throws {
        let directory = try tempDirectory()
        let receiver = FileReceiver()
        let first = try receiver.begin(metadata(size: 10, sha256: "00"), in: directory)
        _ = try receiver.append(FileChunk(fileIdHash: JavaStringHash.hash("abc12345"), offset: 0, data: Data("abc".utf8)))

        let second = try receiver.begin(metadata(size: 3, sha256: SecurityHash.hex(Data("xyz".utf8)), fileId: "def67890"), in: directory)
        XCTAssertEqual(second.state, .receiving)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: FileReceiver.fileURL(for: first.metadata, in: directory).path),
            "First transfer's partial file should be deleted"
        )

        let outcome = try XCTUnwrap(receiver.append(FileChunk(fileIdHash: JavaStringHash.hash("def67890"), offset: 0, data: Data("xyz".utf8))))
        guard case .finished(let progress, let ack) = outcome else {
            return XCTFail("Expected finished outcome")
        }
        XCTAssertEqual(progress.metadata.fileId, "def67890")
        XCTAssertEqual(ack, .success)
    }

    func testAppendWithoutActiveTransferIsIgnored() throws {
        let receiver = FileReceiver()
        let outcome = try receiver.append(FileChunk(fileIdHash: JavaStringHash.hash("abc12345"), offset: 0, data: Data("abc".utf8)))
        XCTAssertNil(outcome)
    }

    func testSanitizedFileNameBlocksPathTraversal() {
        let traversal = FileMetadata(fileId: "id1", name: "../../etc/passwd", size: 0, sha256: "", mimeType: "")
        let sanitized = FileReceiver.sanitizedFileName(for: traversal)
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.hasPrefix("."))
        XCTAssertTrue(sanitized.hasPrefix("id1_"))

        let hidden = FileMetadata(fileId: "id1", name: ".zshrc", size: 0, sha256: "", mimeType: "")
        let hiddenSanitized = FileReceiver.sanitizedFileName(for: hidden)
        XCTAssertFalse(hiddenSanitized.contains("/"))
        XCTAssertFalse(hiddenSanitized.hasPrefix("."))
        XCTAssertTrue(hiddenSanitized.hasPrefix("id1_"))

        let empty = FileMetadata(fileId: "id1", name: "", size: 0, sha256: "", mimeType: "")
        XCTAssertEqual(FileReceiver.sanitizedFileName(for: empty), "id1_file")
    }
}
