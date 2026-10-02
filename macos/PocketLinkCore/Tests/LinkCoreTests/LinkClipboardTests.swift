import XCTest

import LinkProtocol

@testable import LinkClipboard

final class ClipboardMessageTests: XCTestCase {
    func testFrameEncodesAndroidSchema() throws {
        let frame = try ClipboardMessage.frame(
            text: "hello\nworld",
            streamId: 42,
            timestamp: Date(timeIntervalSince1970: 1_690_000_000)
        )
        XCTAssertEqual(frame.messageType, .clipboard)
        XCTAssertEqual(frame.streamId, 42)
        let object = try JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any]
        XCTAssertEqual(object?["text"] as? String, "hello\nworld")
        XCTAssertEqual(object?["timestamp"] as? Int64, 1_690_000_000_000)
    }

    func testWireRoundTrip() throws {
        let frame = try ClipboardMessage.frame(text: "ping 📋 ✂️", streamId: 7)
        var decoder = FrameDecoder()
        let decoded = try decoder.feed(try FrameEncoder.encode(frame))
        let received = try XCTUnwrap(decoded.first)
        XCTAssertEqual(received.messageType, .clipboard)
        let parsed = try XCTUnwrap(ClipboardMessage.parse(received))
        XCTAssertEqual(parsed.text, "ping 📋 ✂️")
    }

    func testParseRejectsWrongTypeEmptyInvalidAndMissing() {
        XCTAssertNil(
            ClipboardMessage.parse(
                Frame(messageType: .ping, streamId: 0, payload: [UInt8](#"{"text":"x"}"#.utf8))
            )
        )
        XCTAssertNil(
            ClipboardMessage.parse(
                Frame(messageType: .clipboard, streamId: 0, payload: [UInt8](#"{"text":""}"#.utf8))
            )
        )
        XCTAssertNil(
            ClipboardMessage.parse(
                Frame(messageType: .clipboard, streamId: 0, payload: [UInt8](#"{"other":1}"#.utf8))
            )
        )
        XCTAssertNil(
            ClipboardMessage.parse(
                Frame(messageType: .clipboard, streamId: 0, payload: [UInt8]("garbage".utf8))
            )
        )
    }

    func testParseIgnoresTimestampField() throws {
        let frame = Frame(
            messageType: .clipboard,
            streamId: 0,
            payload: [UInt8](#"{"text":"kept","timestamp":123}"#.utf8)
        )
        let parsed = try XCTUnwrap(ClipboardMessage.parse(frame))
        XCTAssertEqual(parsed.text, "kept")
    }

    func testAckRoundTrip() throws {
        let frame = try ClipboardMessage.ackFrame(timestamp: 1_690_000_000_123, streamId: 9)
        XCTAssertEqual(frame.messageType, .clipboardAck)
        XCTAssertEqual(frame.streamId, 9)
        var decoder = FrameDecoder()
        let decoded = try decoder.feed(try FrameEncoder.encode(frame))
        let received = try XCTUnwrap(decoded.first)
        XCTAssertEqual(ClipboardMessage.parseAck(received), 1_690_000_000_123)
    }

    func testParseAckRejectsWrongTypeMissingAndGarbage() {
        XCTAssertNil(
            ClipboardMessage.parseAck(
                Frame(messageType: .clipboard, streamId: 0, payload: [UInt8](#"{"timestamp":1}"#.utf8))
            )
        )
        XCTAssertNil(
            ClipboardMessage.parseAck(
                Frame(messageType: .clipboardAck, streamId: 0, payload: [UInt8](#"{"other":1}"#.utf8))
            )
        )
        XCTAssertNil(
            ClipboardMessage.parseAck(
                Frame(messageType: .clipboardAck, streamId: 0, payload: [UInt8]("garbage".utf8))
            )
        )
    }

    func testParseReturnsTimestamp() throws {
        let frame = try ClipboardMessage.frame(
            text: "with time",
            streamId: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.25)
        )
        let parsed = try XCTUnwrap(ClipboardMessage.parse(frame))
        XCTAssertEqual(parsed.text, "with time")
        XCTAssertEqual(parsed.timestamp, 1_700_000_000_250)
    }
}
