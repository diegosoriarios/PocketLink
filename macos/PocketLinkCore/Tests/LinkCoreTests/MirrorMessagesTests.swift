import XCTest

@testable import LinkProtocol

final class MirrorMessagesTests: XCTestCase {
    func testControlFrames() {
        XCTAssertEqual(MirrorMessages.startFrame(streamId: 3).messageType, .mirrorStart)
        XCTAssertEqual(MirrorMessages.stopFrame(streamId: 4).messageType, .mirrorStop)
    }

    func testConfigRoundTrip() throws {
        let sps = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0])
        let pps = Data([0x00, 0x00, 0x00, 0x01, 0x68, 0xCE])
        let config = MirrorMessages.Config(
            width: 1080, height: 2400, fps: 30, bitrateBps: 4_000_000, sps: sps, pps: pps
        )
        let frame = try MirrorMessages.configFrame(config, streamId: 7)
        XCTAssertEqual(frame.messageType, .mirrorConfig)

        var decoder = FrameDecoder()
        let received = try XCTUnwrap(decoder.feed(try FrameEncoder.encode(frame)).first)
        let parsed = try XCTUnwrap(MirrorMessages.parseConfig(received))
        XCTAssertEqual(parsed, config)
    }

    func testConfigParseToleratesMissingOptionals() throws {
        let frame = Frame(
            messageType: .mirrorConfig,
            streamId: 0,
            payload: [UInt8](#"{"width":720,"height":1600}"#.utf8)
        )
        let config = try XCTUnwrap(MirrorMessages.parseConfig(frame))
        XCTAssertEqual(config.width, 720)
        XCTAssertEqual(config.height, 1600)
        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.bitrateBps, 4_000_000)
        XCTAssertTrue(config.sps.isEmpty)
        XCTAssertTrue(config.pps.isEmpty)
    }

    func testConfigParseRejectsInvalidDimensions() {
        XCTAssertNil(MirrorMessages.parseConfig(
            Frame(messageType: .mirrorConfig, streamId: 0, payload: [UInt8](#"{"width":0,"height":100}"#.utf8))
        ))
        XCTAssertNil(MirrorMessages.parseConfig(
            Frame(messageType: .ping, streamId: 0, payload: [UInt8](#"{"width":1,"height":1}"#.utf8))
        ))
    }

    func testEncodedFrameRoundTrip() throws {
        let accessUnit = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let encoded = MirrorMessages.EncodedFrame(timestampMs: 1_700_000_123_456, keyframe: true, accessUnit: accessUnit)
        let frame = try MirrorMessages.frameFrame(encoded, streamId: 9)
        XCTAssertEqual(frame.messageType, .mirrorFrame)

        var decoder = FrameDecoder()
        let received = try XCTUnwrap(decoder.feed(try FrameEncoder.encode(frame)).first)
        let parsed = try XCTUnwrap(MirrorMessages.parseFrame(received))
        XCTAssertEqual(parsed, encoded)
    }

    func testEncodedFrameRejectsTruncatedAndOverlongLengths() throws {
        let short = try MirrorMessages.frameFrame(
            MirrorMessages.EncodedFrame(timestampMs: 1, keyframe: false, accessUnit: Data(repeating: 0, count: 10)),
            streamId: 1
        )
        var truncatedPayload = short.payload
        truncatedPayload.removeLast(3)
        XCTAssertNil(MirrorMessages.parseFrame(
            Frame(messageType: .mirrorFrame, streamId: 1, payload: truncatedPayload)
        ))

        var badPayload = short.payload
        badPayload[9] = 0xFF
        XCTAssertNil(MirrorMessages.parseFrame(
            Frame(messageType: .mirrorFrame, streamId: 1, payload: badPayload)
        ))
    }

    func testTouchRoundTrip() throws {
        let point = MirrorMessages.TouchPoint(action: .move, x: 0.25, y: 0.75)
        let frame = try MirrorMessages.touchFrame(point, streamId: 2)
        XCTAssertEqual(frame.messageType, .remoteTouch)

        var decoder = FrameDecoder()
        let received = try XCTUnwrap(decoder.feed(try FrameEncoder.encode(frame)).first)
        let parsed = try XCTUnwrap(MirrorMessages.parseTouch(received))
        XCTAssertEqual(parsed, point)
    }

    func testTouchParseRejectsInvalidActionAndType() {
        XCTAssertNil(MirrorMessages.parseTouch(
            Frame(messageType: .remoteTouch, streamId: 0, payload: [UInt8](#"{"action":"swipe","x":0.5,"y":0.5}"#.utf8))
        ))
        XCTAssertNil(MirrorMessages.parseTouch(
            Frame(messageType: .clipboard, streamId: 0, payload: [UInt8](#"{"action":"down","x":0.5,"y":0.5}"#.utf8))
        ))
    }
}
