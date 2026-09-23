import XCTest

@testable import LinkProtocol

final class FrameRoundTripTests: XCTestCase {
    func testGoldenPingVectorDecodes() throws {
        let golden: [UInt8] = [
            0x4C, 0x49, 0x4E, 0x4B, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x1B,
            0x7B, 0x22, 0x74, 0x69, 0x6D, 0x65, 0x73, 0x74, 0x61, 0x6D, 0x70, 0x22,
            0x3A, 0x31, 0x37, 0x31, 0x39, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
            0x30, 0x30, 0x7D,
        ]
        var decoder = FrameDecoder()
        let frames = try decoder.feed(golden)
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.version, 1)
        XCTAssertEqual(frame.messageType, .ping)
        XCTAssertEqual(frame.streamId, 1)
        XCTAssertEqual(frame.payloadLength, 27)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "{\"timestamp\":1719000000000}")
    }

    func testGoldenPingVectorReencodes() throws {
        let frame = Frame(messageType: .ping, streamId: 1, payloadString: "{\"timestamp\":1719000000000}")
        let encoded = try FrameEncoder.encode(frame)
        let expected: [UInt8] = [
            0x4C, 0x49, 0x4E, 0x4B, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x1B,
            0x7B, 0x22, 0x74, 0x69, 0x6D, 0x65, 0x73, 0x74, 0x61, 0x6D, 0x70, 0x22,
            0x3A, 0x31, 0x37, 0x31, 0x39, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
            0x30, 0x30, 0x7D,
        ]
        XCTAssertEqual(encoded, expected)
    }

    func testRoundTripAllMessageTypes() throws {
        for messageType in MessageType.allCases {
            let payload = [UInt8]("payload-for-\(messageType)".utf8)
            let frame = Frame(messageType: messageType, streamId: 42, payload: payload)
            var decoder = FrameDecoder()
            let decoded = try decoder.feed(try FrameEncoder.encode(frame))
            XCTAssertEqual(decoded, [frame], "round-trip failed for \(messageType)")
        }
    }

    func testEmptyPayloadRoundTrip() throws {
        let frame = Frame(messageType: .handshake, streamId: 0)
        var decoder = FrameDecoder()
        let decoded = try decoder.feed(try FrameEncoder.encode(frame))
        XCTAssertEqual(decoded, [frame])
    }

    func testByteByByteFeedProducesSingleFrame() throws {
        let encoded = try FrameEncoder.encode(
            Frame(messageType: .clipboard, streamId: 7, payloadString: "{\"text\":\"x\",\"timestamp\":1}")
        )
        var decoder = FrameDecoder()
        var collected: [Frame] = []
        for byte in encoded {
            let frames = try decoder.feed([byte])
            collected.append(contentsOf: frames)
            XCTAssertTrue(frames.count <= 1)
        }
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected.first?.messageType, .clipboard)
        XCTAssertEqual(collected.first?.streamId, 7)
    }

    func testTwoFramesInOneFeed() throws {
        let first = Frame(messageType: .ping, streamId: 1, payloadString: "{\"timestamp\":1}")
        let second = Frame(messageType: .pong, streamId: 1, payloadString: "{\"timestamp\":1}")
        var encoded = try FrameEncoder.encode(first)
        encoded.append(contentsOf: try FrameEncoder.encode(second))
        var decoder = FrameDecoder()
        let decoded = try decoder.feed(encoded)
        XCTAssertEqual(decoded, [first, second])
    }

    func testFramePlusPartialHeaderInOneFeed() throws {
        let first = Frame(messageType: .ping, streamId: 2, payloadString: "{\"timestamp\":5}")
        let second = Frame(messageType: .battery, streamId: 3, payloadString: "{}")
        var encoded = try FrameEncoder.encode(first)
        encoded.append(contentsOf: try FrameEncoder.encode(second).prefix(10))
        var decoder = FrameDecoder()
        let decoded = try decoder.feed(encoded)
        XCTAssertEqual(decoded, [first])
        let rest = try decoder.feed(Array(try FrameEncoder.encode(second).dropFirst(10)))
        XCTAssertEqual(rest, [second])
    }

    func testMaxBoundaryPayloadRoundTrip() throws {
        let frame = Frame(messageType: .fileChunk, streamId: 9, payload: [UInt8](repeating: 0xAB, count: 8_388_608))
        var decoder = FrameDecoder()
        let decoded = try decoder.feed(try FrameEncoder.encode(frame))
        XCTAssertEqual(decoded, [frame])
    }
}
