import XCTest
import Network

@testable import LinkProtocol
@testable import LinkConnection

final class ProtocolEchoServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.link.echo.server")
    private let listener: NWListener
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var portValue: UInt16 = 0
    private var peerGone = false
    private var inboundPongs: [Frame] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("SERVER failed: \(error)\n".utf8))
            }
            if let port = self.listener.port?.rawValue {
                self.portValue = port
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    var boundPort: UInt16 {
        let deadline = Date().addingTimeInterval(5)
        while portValue == 0 && Date() < deadline {
            usleep(10_000)
        }
        if portValue == 0 {
            FileHandle.standardError.write(Data("SERVER boundPort timeout\n".utf8))
        }
        return portValue
    }

    var peerDisconnected: Bool {
        queue.sync { peerGone }
    }

    var receivedPongs: [Frame] {
        queue.sync { inboundPongs }
    }

    var peerAccepted: Bool {
        queue.sync { connection != nil }
    }

    func inject(_ bytes: [UInt8]) {
        queue.sync {
            connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
        }
    }

    func stop() {
        queue.sync {
            connection?.cancel()
            listener.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async {
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    self?.queue.async { self?.peerGone = true }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
            self.receiveLoop(connection)
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(data, connection: connection)
            }
            if isComplete || error != nil {
                self.queue.async { self.peerGone = true }
                return
            }
            self.receiveLoop(connection)
        }
    }

    private func consume(_ data: Data, connection: NWConnection) {
        do {
            let frames = try decoder.feed([UInt8](data))
            for frame in frames {
                switch frame.messageType {
                case .ping:
                    let pong = Frame(messageType: .pong, streamId: frame.streamId, payload: frame.payload)
                    connection.send(
                        content: Data(try FrameEncoder.encode(pong)),
                        completion: .contentProcessed { _ in }
                    )
                case .pong:
                    inboundPongs.append(frame)
                default:
                    break
                }
            }
        } catch {
            decoder.reset()
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
        let port = server.boundPort
        FileHandle.standardError.write(Data("bound to \(port)\n".utf8))
        XCTAssertGreaterThan(port, 0)
        server.stop()
    }

    func testPingPongRoundTripOverLoopbackTCP() async throws {
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

        try await client.connect(host: "127.0.0.1", port: server.boundPort)
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

        try await client.connect(host: "127.0.0.1", port: server.boundPort)

        let acceptedDeadline = Date().addingTimeInterval(5)
        while !server.peerAccepted && Date() < acceptedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(server.peerAccepted, "echo server never accepted the connection")

        let androidSidePing = Frame(
            messageType: .ping,
            streamId: 99,
            payloadString: "{\"timestamp\":123}"
        )
        server.inject(try FrameEncoder.encode(androidSidePing))

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

    func testInvalidMagicFailsConnectionSafely() async throws {
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

        try await client.connect(host: "127.0.0.1", port: server.boundPort)
        try await Task.sleep(for: .milliseconds(150))

        server.inject(Array("GARBAGEGARBAGE12".utf8))

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
        func mark(_ label: String) {
            FileHandle.standardError.write(Data("STEP \(label)\n".utf8))
        }
        mark("start")
        let server = try ProtocolEchoServer()
        defer { server.stop() }
        mark("server-bound")

        let client = LinkClient()
        try await client.connect(host: "127.0.0.1", port: server.boundPort)
        mark("connected-1")

        do {
            try await client.connect(host: "127.0.0.1", port: server.boundPort)
            XCTFail("second connect must throw")
        } catch let error as LinkClientError {
            XCTAssertEqual(error, .alreadyConnected)
        }
        mark("second-rejected")

        await client.disconnect()
        mark("disconnected")
    }

    func testConnectToRefusedPortThrows() async throws {
        let server = try ProtocolEchoServer()
        let port = server.boundPort
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
