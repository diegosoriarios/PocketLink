import XCTest

@testable import LinkProtocol

final class RemoteTextMessageTests: XCTestCase {
    func testTextFrameCarriesJSONPayload() throws {
        let frame = try MirrorMessages.remoteTextFrame(.text("héllo "), streamId: 7)
        XCTAssertEqual(frame.messageType, .remoteText)
        XCTAssertEqual(frame.streamId, 7)
        let object = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: String]
        )
        XCTAssertEqual(object["text"], "héllo ")
        XCTAssertNil(object["special"])
    }

    func testSpecialFrameCarriesSpecialKey() throws {
        let frame = try MirrorMessages.remoteTextFrame(.special(.backspace), streamId: 8)
        let object = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: String]
        )
        XCTAssertEqual(object["special"], "backspace")
        XCTAssertNil(object["text"])
    }

    func testFullRoundTripThroughWireDecoder() throws {
        let contents: [MirrorMessages.TextContent] = [
            .text("typed text"),
            .special(.backspace),
            .special(.enter)
        ]
        var decoder = FrameDecoder()
        for (index, content) in contents.enumerated() {
            let frame = try MirrorMessages.remoteTextFrame(content, streamId: UInt32(index + 1))
            let received = try XCTUnwrap(decoder.feed(try FrameEncoder.encode(frame)).first)
            XCTAssertEqual(received.messageType, .remoteText)
            XCTAssertEqual(MirrorMessages.parseRemoteText(received), content)
        }
    }

    func testEmptyTextEncodesRejectedPayload() throws {
        let frame = try MirrorMessages.remoteTextFrame(.text(""), streamId: 1)
        XCTAssertNil(MirrorMessages.parseRemoteText(frame))
    }

    func testParseRejectsForeignTypeAndUnknownSpecial() {
        let foreign = Frame(messageType: .ping, streamId: 1, payloadString: #"{"text":"hi"}"#)
        XCTAssertNil(MirrorMessages.parseRemoteText(foreign))
        let unknown = Frame(messageType: .remoteText, streamId: 1, payloadString: #"{"special":"tab"}"#)
        XCTAssertNil(MirrorMessages.parseRemoteText(unknown))
        let empty = Frame(messageType: .remoteText, streamId: 1, payloadString: "{}")
        XCTAssertNil(MirrorMessages.parseRemoteText(empty))
    }
}
