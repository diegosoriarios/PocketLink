import XCTest

@testable import LinkProtocol

final class FrameDecoderErrorTests: XCTestCase {
    private func header(magic: String = "LINK", typeId: UInt16, payloadLength: UInt32) -> [UInt8] {
        var bytes = Array(magic.utf8)
        bytes.append(UInt8(truncatingIfNeeded: 1 >> 8))
        bytes.append(UInt8(truncatingIfNeeded: 1))
        bytes.append(UInt8(truncatingIfNeeded: typeId >> 8))
        bytes.append(UInt8(truncatingIfNeeded: typeId))
        bytes.append(0); bytes.append(0); bytes.append(0); bytes.append(7)
        bytes.append(UInt8(truncatingIfNeeded: payloadLength >> 24))
        bytes.append(UInt8(truncatingIfNeeded: payloadLength >> 16))
        bytes.append(UInt8(truncatingIfNeeded: payloadLength >> 8))
        bytes.append(UInt8(truncatingIfNeeded: payloadLength))
        return bytes
    }

    func testPartialHeaderFeedDoesNotThrow() throws {
        var decoder = FrameDecoder()
        let frames = try decoder.feed([0x4C, 0x49])
        XCTAssertTrue(frames.isEmpty)
    }

    func testInvalidMagicThrowsAfterHeaderCompleteAndResetsBuffer() throws {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.feed(header(magic: "XXXX", typeId: 0x0002, payloadLength: 0))) { error in
            XCTAssertEqual(error as? FrameDecodeError, .invalidMagic(offendingBytes: Array("XXXX".utf8)))
        }
        let good = try FrameEncoder.encode(Frame(messageType: .ping, streamId: 1, payloadString: "{}"))
        let frames = try decoder.feed(good)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.messageType, .ping)
    }

    func testGarbageThenValidInSameFeedThrowsAndConsumesAll() throws {
        var decoder = FrameDecoder()
        var bytes = header(magic: "ZZZZ", typeId: 0x0002, payloadLength: 0)
        bytes.append(contentsOf: try FrameEncoder.encode(Frame(messageType: .ping, streamId: 1, payloadString: "{}")))
        XCTAssertThrowsError(try decoder.feed(bytes)) { error in
            XCTAssertEqual(error as? FrameDecodeError, .invalidMagic(offendingBytes: Array("ZZZZ".utf8)))
        }
        XCTAssertTrue(try decoder.feed([]).isEmpty)
    }

    func testOversizedDeclaredLengthThrowsBeforeBodyArrives() throws {
        var decoder = FrameDecoder()
        let oversize = LinkProtocolConstants.maxPayloadSize + 1
        XCTAssertThrowsError(try decoder.feed(header(typeId: 0x0041, payloadLength: oversize))) { error in
            XCTAssertEqual(error as? FrameDecodeError, .frameOversized(declaredLength: oversize))
        }
        let good = try FrameEncoder.encode(Frame(messageType: .ping, streamId: 1, payloadString: "{}"))
        let frames = try decoder.feed(good)
        XCTAssertEqual(frames.count, 1)
    }

    func testMaxBoundaryDeclaredLengthWaitsForBody() throws {
        var decoder = FrameDecoder()
        let frames = try decoder.feed(header(typeId: 0x0041, payloadLength: LinkProtocolConstants.maxPayloadSize))
        XCTAssertTrue(frames.isEmpty)
    }

    func testUnknownMessageTypeThrowsAfterFullBodyAndResetsBuffer() throws {
        var decoder = FrameDecoder()
        var bytes = header(typeId: 0x7FFF, payloadLength: 2)
        bytes.append(contentsOf: [0x01, 0x02])
        XCTAssertThrowsError(try decoder.feed(bytes)) { error in
            XCTAssertEqual(error as? FrameDecodeError, .unknownMessageType(id: 0x7FFF))
        }
        let good = try FrameEncoder.encode(Frame(messageType: .ping, streamId: 1, payloadString: "{}"))
        let frames = try decoder.feed(good)
        XCTAssertEqual(frames.count, 1)
    }

    func testEncoderRejectsOversizedPayload() {
        let frame = Frame(messageType: .fileChunk, streamId: 1, payload: [UInt8](repeating: 0, count: 8_388_609))
        XCTAssertThrowsError(try FrameEncoder.encode(frame)) { error in
            XCTAssertEqual(error as? FrameEncodeError, .payloadTooLarge(declared: 8_388_609))
        }
    }

    func testVersionMismatchIsNotRejected() throws {
        var decoder = FrameDecoder()
        let frame = Frame(version: 99, messageType: .ping, streamId: 1, payloadString: "{}")
        let frames = try decoder.feed(try FrameEncoder.encode(frame))
        XCTAssertEqual(frames, [frame])
    }
}
