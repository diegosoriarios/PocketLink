import XCTest

@testable import LinkProtocol

final class OpenURLMessageTests: XCTestCase {
    func testFrameCarriesJSONPayload() throws {
        let frame = OpenURLMessage.frame(url: "https://example.com/a?b=1", streamId: 9)
        XCTAssertEqual(frame.messageType, .openURL)
        XCTAssertEqual(frame.streamId, 9)
        let object = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: String]
        )
        XCTAssertEqual(object["url"], "https://example.com/a?b=1")
    }

    func testFullRoundTripThroughWireDecoder() throws {
        let frame = OpenURLMessage.frame(url: "http://example.org", streamId: 2)
        var decoder = FrameDecoder()
        let received = try XCTUnwrap(decoder.feed(try FrameEncoder.encode(frame)).first)
        XCTAssertEqual(received.messageType, .openURL)
        XCTAssertEqual(OpenURLMessage.parse(received), "http://example.org")
    }

    func testParseRejectsForeignTypeAndEmptyURL() {
        let foreign = Frame(messageType: .ping, streamId: 1, payloadString: #"{"url":"https://x"}"#)
        XCTAssertNil(OpenURLMessage.parse(foreign))
        XCTAssertNil(OpenURLMessage.parse(OpenURLMessage.frame(url: "", streamId: 1)))
    }
}
