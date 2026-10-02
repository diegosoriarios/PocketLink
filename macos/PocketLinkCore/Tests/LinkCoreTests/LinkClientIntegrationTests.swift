import XCTest

@testable import LinkProtocol
@testable import LinkConnection

/// Loopback server with ping→pong echo behavior on top of the encrypted
/// transport.
final class ProtocolEchoServer: CryptoLoopbackServer, @unchecked Sendable {
    private var inboundPongs: [Frame] = []

    init() throws {
        try super.init(label: "test.link.echo.server")
    }

    var receivedPongs: [Frame] {
        queue.sync { inboundPongs }
    }

    override func handlePlaintext(_ frame: Frame) {
        switch frame.messageType {
        case .ping:
            sealAndSend(Frame(messageType: .pong, streamId: frame.streamId, payload: frame.payload))
        case .pong:
            queue.async { self.inboundPongs.append(frame) }
        default:
            break
        }
    }
}

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Frame] = []

    func append(_ frame: Frame) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(frame)
    }

    var snapshot: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LinkClientState?

    func set(_ state: LinkClientState) {
        lock.lock()
        defer { lock.unlock() }
        value = state
    }

    var current: LinkClientState? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class LinkClientIntegrationTests: XCTestCase {
    func testServerBinds() async throws {
        let server = try ProtocolEchoServer()
        let port = try server.awaitBoundPort()
        XCTAssertGreaterThan(port, 0)
        server.stop()
    }

    func testEncryptedPingPongRoundTripOverLoopbackTCP() async throws {
        let server = try ProtocolEchoServer()
        defer { server.stop() }

        let client = LinkClient()
        let collector = FrameCollector()
        let pongReceived = expectation(description: "pong received")

        let framesTask = Task {
            for await frame in client.frames {
                collector.append(frame)
                if frame.messageType == .pong {
                    pongReceived.fulfill()
                }
            }
        }
        defer { framesTask.cancel() }

        try await client.connect(host: "127.0.0.1", port: try server.awaitBoundPort())
        let fingerprint = await client.peerFingerprint
        XCTAssertFalse(fingerprint.isEmpty, "peer fingerprint must be set after the crypto handshake")
        let streamId = try await client.sendPing()

        await fulfillment(of: [pongReceived], timeout: 10)

        let received = collector.snapshot
        XCTAssertEqual(received.count, 1)
        let pong = received[0]
        XCTAssertEqual(pong.messageType, .pong)
        XCTAssertEqual(pong.streamId, streamId)
        XCTAssertTrue(String(decoding: pong.payload, as: UTF8.self).hasPrefix("{\"timestamp\":"))
    }

    func testAutoPongRepliesToInboundPing() async throws {
        let server = try ProtocolEchoServer()
        defer { server.stop() }

        let client = LinkClient()
        let collector = FrameCollector()

        let framesTask = Task {
            for await frame in client.frames {
                collector.append(frame)
            }
        }
        defer { framesTask.cancel() }

        try await client.connect(host: "127.0.0.1", port: try server.awaitBoundPort())

        let channelDeadline = Date().addingTimeInterval(5)
        while !server.channelReady && Date() < channelDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(server.channelReady, "echo server never completed the Noise handshake")

        let androidSidePing = Frame(
            messageType: .ping,
            streamId: 99,
            payloadString: "{\"timestamp\":123}"
        )
        server.inject(androidSidePing)

        let deadline = Date().addingTimeInterval(10)
        while server.receivedPongs.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(collector.snapshot.map(\.messageType), [.ping], "client must receive the injected ping")
        let pongs = server.receivedPongs
        XCTAssertEqual(pongs.count, 1)
        let pong = try XCTUnwrap(pongs.first)
        XCTAssertEqual(pong.messageType, .pong)
        XCTAssertEqual(pong.streamId, 99)
        XCTAssertEqual(pong.payload, androidSidePing.payload)
    }

    func testInvalidMagicAfterHandshakeFailsConnectionSafely() async throws {
        let server = try ProtocolEchoServer()
        defer { server.stop() }

        let client = LinkClient()
        let frameCollector = FrameCollector()
        let stateBox = StateBox()
        let terminal = expectation(description: "terminal state")

        let framesTask = Task {
            for await frame in client.frames {
                frameCollector.append(frame)
            }
        }
        defer { framesTask.cancel() }

        let statesTask = Task {
            for await state in client.states {
                switch state {
                case .failed, .closed:
                    stateBox.set(state)
                    terminal.fulfill()
                    return
                default:
                    break
                }
            }
        }
        defer { statesTask.cancel() }

        try await client.connect(host: "127.0.0.1", port: try server.awaitBoundPort())
        let channelDeadline = Date().addingTimeInterval(5)
        while !server.channelReady && Date() < channelDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        server.injectRaw(Array("GARBAGEGARBAGE12".utf8))

        await fulfillment(of: [terminal], timeout: 10)

        XCTAssertTrue(frameCollector.snapshot.isEmpty, "no frame may be delivered from a malformed stream")
        switch stateBox.current {
        case .failed, .closed:
            break
        default:
            XCTFail("expected failed or closed, got \(String(describing: stateBox.current))")
        }
    }

    func testDoubleConnectRejected() async throws {
        let server = try ProtocolEchoServer()
        defer { server.stop() }

        let client = LinkClient()
        try await client.connect(host: "127.0.0.1", port: try server.awaitBoundPort())

        do {
            try await client.connect(host: "127.0.0.1", port: try server.awaitBoundPort())
            XCTFail("second connect must throw")
        } catch let error as LinkClientError {
            XCTAssertEqual(error, .alreadyConnected)
        }

        await client.disconnect()
    }

    func testConnectToRefusedPortThrows() async throws {
        let server = try ProtocolEchoServer()
        let port = try server.awaitBoundPort()
        server.stop()
        try await Task.sleep(for: .milliseconds(150))

        let client = LinkClient()
        do {
            try await client.connect(host: "127.0.0.1", port: port)
            XCTFail("connect to refused port must throw")
        } catch let error as LinkClientError {
            if case .connectFailed = error {} else {
                XCTFail("expected connectFailed, got \(error)")
            }
        }
    }

    func testConnectTimeoutToUnroutableHostThrows() async throws {
        let client = LinkClient()
        let started = Date()
        do {
            try await client.connect(host: "192.0.2.1", port: 52345, timeout: 1)
            XCTFail("connect to unroutable host must time out")
        } catch let error as LinkClientError {
            XCTAssertEqual(error, .connectFailed(description: "Timed out"))
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 8, "timeout should fire near its deadline, took \(elapsed)s")
    }
}
