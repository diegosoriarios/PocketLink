import XCTest

import LinkProtocol

@testable import LinkPairing

final class TrustStoreTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTrustPersistsAcrossInstances() async throws {
        let directory = try tempDirectory()
        let first = TrustStore(directory: directory)
        let initiallyTrusted = await first.isTrusted("192.168.1.42")
        XCTAssertFalse(initiallyTrusted)
        try await first.trust("192.168.1.42", name: "Pixel 8")

        let second = TrustStore(directory: directory)
        let trusted = await second.isTrusted("192.168.1.42")
        XCTAssertTrue(trusted)
        let peers = await second.trustedPeers()
        XCTAssertEqual(peers.map(\.name), ["Pixel 8"])
    }

    func testRevokeRemovesPeerAndPersists() async throws {
        let directory = try tempDirectory()
        let store = TrustStore(directory: directory)
        try await store.trust("pixel", name: "Pixel 8")
        try await store.revoke("pixel")
        let trusted = await store.isTrusted("pixel")
        XCTAssertFalse(trusted)

        let reloaded = TrustStore(directory: directory)
        let stillTrusted = await reloaded.isTrusted("pixel")
        XCTAssertFalse(stillTrusted)
    }

    func testCorruptFileRecoversToEmpty() async throws {
        let directory = try tempDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("trusted-peers.json"))

        let store = TrustStore(directory: directory)
        let peers = await store.trustedPeers()
        XCTAssertTrue(peers.isEmpty)

        try await store.trust("pixel", name: "Pixel 8")
        let reloaded = TrustStore(directory: directory)
        let trusted = await reloaded.isTrusted("pixel")
        XCTAssertTrue(trusted)
    }

    func testTrustIsIdempotentForSameName() async throws {
        let store = TrustStore(directory: try tempDirectory())
        try await store.trust("pixel", name: "Pixel 8")
        let firstAdded = await store.trustedPeers().first?.addedAt
        try await Task.sleep(for: .milliseconds(10))
        try await store.trust("pixel", name: "Pixel 8")
        let peers = await store.trustedPeers()
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.addedAt, firstAdded)
    }
}

final class HandshakeMessageTests: XCTestCase {
    func testFrameRoundTripAndPayloadKeys() throws {
        let frame = try HandshakeMessage.frame(deviceName: "Diego's MacBook")
        XCTAssertEqual(frame.messageType, .handshake)
        XCTAssertEqual(frame.streamId, 0)

        var decoder = FrameDecoder()
        let decoded = try decoder.feed(try FrameEncoder.encode(frame))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].messageType, .handshake)
        XCTAssertEqual(decoded[0].streamId, 0)

        let object = try JSONSerialization.jsonObject(with: Data(decoded[0].payload))
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let device = dictionary["device"] as? String
        XCTAssertEqual(device, "Diego's MacBook")
        let platform = dictionary["platform"] as? String
        XCTAssertEqual(platform, "macOS")
    }

    func testEscapesSpecialCharactersInDeviceName() throws {
        let frame = try HandshakeMessage.frame(deviceName: "quote\"back\\slash")
        let object = try JSONSerialization.jsonObject(with: Data(frame.payload))
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let device = dictionary["device"] as? String
        XCTAssertEqual(device, "quote\"back\\slash")
    }
}
