import Foundation
import Network

import LinkProtocol

public enum LinkClientState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case failed(reason: String)
    case closed
}

public enum LinkClientError: Error, Equatable, Sendable {
    case alreadyConnected
    case invalidPort(UInt16)
    case notConnected
    case connectFailed(description: String)
    case connectTimeout
    case sendFailed(description: String)
}

private final class SendContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelledBeforeStore = false

    func store(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelledBeforeStore { return false }
        self.continuation = continuation
        return true
    }

    func consume(_ body: (CheckedContinuation<Void, Error>) -> Void) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let pending {
            body(pending)
        }
    }

    func cancel() {
        lock.lock()
        if let pending = continuation {
            continuation = nil
            lock.unlock()
            pending.resume(throwing: CancellationError())
            return
        }
        cancelledBeforeStore = true
        lock.unlock()
    }
}

public actor LinkClient {
    nonisolated public let frames: AsyncStream<Frame>

    nonisolated public let states: AsyncStream<LinkClientState>
    private let framesContinuation: AsyncStream<Frame>.Continuation
    private let statesContinuation: AsyncStream<LinkClientState>.Continuation

    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var streamIdCounter: UInt32 = 0
    private var connectContinuation: CheckedContinuation<Void, Error>?

    public init() {
        (frames, framesContinuation) = AsyncStream.makeStream(of: Frame.self)
        (states, statesContinuation) = AsyncStream.makeStream(of: LinkClientState.self)
    }

    public func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LinkClientError.invalidPort(port)
        }
        try await connect(to: NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort), timeout: timeout)
    }

    public func connect(to endpoint: NWEndpoint, timeout: TimeInterval = 10) async throws {
        guard connection == nil else {
            throw LinkClientError.alreadyConnected
        }
        let nwConnection = NWConnection(to: endpoint, using: .tcp)
        connection = nwConnection
        decoder.reset()
        streamIdCounter = 0
        statesContinuation.yield(.connecting)

        nwConnection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateChange(state, connection: nwConnection) }
        }
        nwConnection.start(queue: .global(qos: .userInitiated))

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.failConnect(connection: nwConnection, reason: "Timed out")
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
        }
    }

    private func failConnect(connection nwConnection: NWConnection, reason: String) {
        guard connectContinuation != nil, connection === self.connection else { return }
        statesContinuation.yield(.failed(reason: reason))
        resumeConnect(LinkClientError.connectFailed(description: reason))
        nwConnection.cancel()
    }

    public func disconnect() {
        guard let connection else { return }
        self.connection = nil
        connection.cancel()
        teardown(connection)
    }

    @discardableResult
    public func sendPing() async throws -> UInt32 {
        let streamId = nextStreamId()
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        try await send(
            Frame(
                messageType: .ping,
                streamId: streamId,
                payloadString: "{\"timestamp\":\(milliseconds)}"
            )
        )
        return streamId
    }

    public func send(_ frame: Frame) async throws {
        guard let connection else {
            throw LinkClientError.notConnected
        }
        let bytes = try FrameEncoder.encode(frame)
        let box = SendContinuationBox()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard box.store(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connection.send(content: Data(bytes), completion: .contentProcessed { error in
                    box.consume { pending in
                        if let error {
                            pending.resume(throwing: LinkClientError.sendFailed(description: Self.describe(error)))
                        } else {
                            pending.resume()
                        }
                    }
                })
            }
        }, onCancel: {
            box.cancel()
        })
    }

    public func nextStreamId() -> UInt32 {
        streamIdCounter &+= 1
        return streamIdCounter
    }

    private func handleStateChange(_ state: NWConnection.State, connection nwConnection: NWConnection) {
        switch state {
        case .ready:
            guard connection === nwConnection else { return }
            statesContinuation.yield(.connected)
            resumeConnect(nil)
            runReceiveLoop(nwConnection)
        case .failed(let error):
            guard connection === nwConnection else { return }
            statesContinuation.yield(.failed(reason: Self.describe(error)))
            resumeConnect(LinkClientError.connectFailed(description: Self.describe(error)))
            teardown(nwConnection)
        case .cancelled:
            resumeConnect(LinkClientError.connectFailed(description: "Connection cancelled"))
            if connection === nwConnection {
                statesContinuation.yield(.closed)
                teardown(nwConnection)
            }
        case .waiting:
            break
        default:
            break
        }
    }

    private func resumeConnect(_ error: Error?) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func runReceiveLoop(_ nwConnection: NWConnection) {
        guard connection === nwConnection else { return }
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error, connection: nwConnection) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?, connection: NWConnection) {
        guard self.connection === connection else { return }

        if let data, !data.isEmpty {
            var workingDecoder = decoder
            do {
                let received = try workingDecoder.feed([UInt8](data))
                decoder = workingDecoder
                for frame in received {
                    handleInbound(frame)
                    framesContinuation.yield(frame)
                }
            } catch let decodeError as FrameDecodeError {
                decoder = workingDecoder
                handleDecodeError(decodeError)
                return
            } catch {
                decoder = workingDecoder
                return
            }
        }

        if isComplete || error != nil {
            if let error {
                statesContinuation.yield(.failed(reason: Self.describe(error)))
            } else {
                statesContinuation.yield(.closed)
            }
            teardown(connection)
            return
        }

        runReceiveLoop(connection)
    }

    private func handleInbound(_ frame: Frame) {
        if frame.messageType == .ping {
            sendNow(Frame(messageType: .pong, streamId: frame.streamId, payload: frame.payload))
        }
    }

    private func handleDecodeError(_ error: FrameDecodeError) {
        switch error {
        case .invalidMagic:
            sendErrorFrame(code: 400, message: "Invalid frame header or magic bytes")
            connection?.cancel()
        case .frameOversized:
            sendErrorFrame(code: 413, message: "Frame payload exceeds maximum size")
        case .unknownMessageType:
            sendErrorFrame(code: 400, message: "Unknown message type")
        }
    }

    private func sendErrorFrame(code: Int, message: String) {
        let json = "{\"code\":\(code),\"message\":\"\(message)\"}"
        sendNow(Frame(messageType: .error, streamId: 0, payloadString: json))
    }

    private func sendNow(_ frame: Frame) {
        guard let connection, let bytes = try? FrameEncoder.encode(frame) else { return }
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func teardown(_ nwConnection: NWConnection) {
        if connection === nwConnection {
            connection = nil
        }
        nwConnection.stateUpdateHandler = nil
        nwConnection.cancel()
        resumeConnect(LinkClientError.connectFailed(description: "Connection closed before it was ready"))
        framesContinuation.finish()
        statesContinuation.finish()
    }

    private static func describe(_ error: NWError) -> String {
        "Network error \(error.errorCode)"
    }
}
