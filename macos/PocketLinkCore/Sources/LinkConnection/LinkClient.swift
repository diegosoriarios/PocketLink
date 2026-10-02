import Foundation
import Network

import LinkProtocol
import LinkSecurity

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

private extension Frame {
    var isCryptoHandshake: Bool {
        messageType == .cryptoM1 || messageType == .cryptoM2 || messageType == .cryptoM3
    }
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
    private var channel: SecureChannel?
    private var handshake: NoiseHandshake?
    private var pendingCryptoFrames: [Frame] = []
    private var cryptoWaiter: CheckedContinuation<Frame, Error>?

    /// SHA-256 fingerprint (hex) of the peer's Ed25519 identity key; set once
    /// the crypto handshake completes.
    public private(set) var peerFingerprint: String = ""

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
        channel = nil
        handshake = nil
        pendingCryptoFrames = []
        peerFingerprint = ""
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

    /// Sends a frame, encrypting the payload once the secure channel is up.
    public func send(_ frame: Frame) async throws {
        guard let connection else {
            throw LinkClientError.notConnected
        }
        var bytes: [UInt8]
        if var activeChannel = channel, !frame.isCryptoHandshake {
            let header = Self.wireHeader(
                version: frame.version,
                messageType: frame.messageType,
                streamId: frame.streamId,
                payloadLength: frame.payload.count + 16
            )
            let sealed: Data
            do {
                sealed = try activeChannel.seal(header: header, payload: Data(frame.payload))
            } catch {
                channel = nil
                throw LinkClientError.sendFailed(description: "Encryption failed")
            }
            channel = activeChannel
            bytes = header + [UInt8](sealed)
        } else {
            bytes = try FrameEncoder.encode(frame)
        }
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

    private func sendRaw(_ frame: Frame, on connection: NWConnection) async throws {
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

    public func nextStreamId() -> UInt32 {
        streamIdCounter &+= 1
        return streamIdCounter
    }

    private func handleStateChange(_ state: NWConnection.State, connection nwConnection: NWConnection) {
        switch state {
        case .ready:
            guard connection === nwConnection else { return }
            runReceiveLoop(nwConnection)
            Task { await runCryptoHandshake(nwConnection) }
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
                    try routeFrame(frame)
                }
            } catch let decodeError as FrameDecodeError {
                decoder = workingDecoder
                handleDecodeError(decodeError)
                return
            } catch {
                decoder = workingDecoder
                connection.cancel()
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

    /// Routes a decoded frame: crypto handshake frames during the handshake,
    /// decryption + yield afterwards.
    private func routeFrame(_ frame: Frame) throws {
        if handshake != nil {
            guard frame.isCryptoHandshake else {
                sendErrorFrame(code: 409, message: "Encrypted transport required")
                connection?.cancel()
                throw LinkClientError.connectFailed(description: "Peer sent plaintext before crypto handshake completed")
            }
            if let waiter = cryptoWaiter {
                cryptoWaiter = nil
                waiter.resume(returning: frame)
            } else {
                pendingCryptoFrames.append(frame)
            }
            return
        }

        if frame.isCryptoHandshake {
            // Unexpected crypto frame after the handshake: ignore.
            return
        }

        guard var activeChannel = channel else {
            sendErrorFrame(code: 409, message: "Encrypted transport required")
            connection?.cancel()
            throw LinkClientError.connectFailed(description: "Peer sent plaintext without a secure channel")
        }

        let header = Self.wireHeader(
            version: frame.version,
            messageType: frame.messageType,
            streamId: frame.streamId,
            payloadLength: frame.payload.count
        )
        let plaintext: Data
        do {
            plaintext = try activeChannel.open(header: header, payload: Data(frame.payload))
        } catch {
            channel = nil
            sendErrorFrame(code: 401, message: "Decryption failed")
            connection?.cancel()
            throw LinkClientError.connectFailed(description: "Payload decryption failed")
        }
        channel = activeChannel
        let decrypted = Frame(
            version: frame.version,
            messageType: frame.messageType,
            streamId: frame.streamId,
            payload: [UInt8](plaintext)
        )
        handleInbound(decrypted)
        framesContinuation.yield(decrypted)
    }

    private func runCryptoHandshake(_ nwConnection: NWConnection) async {
        let identity: LinkIdentity
        do {
            identity = try LinkIdentity.load()
        } catch {
            failConnect(connection: nwConnection, reason: "Identity unavailable: \(String(describing: error))")
            return
        }

        var noise = NoiseHandshake(staticKey: identity.staticKey)
        handshake = noise
        do {
            let m1 = try noise.writeM1()
            try await sendRaw(Frame(messageType: .cryptoM1, streamId: 0, payload: [UInt8](m1)), on: nwConnection)

            let m2Frame: Frame
            if let pending = pendingCryptoFrames.first, pending.messageType == .cryptoM2 {
                pendingCryptoFrames.removeFirst()
                m2Frame = pending
            } else {
                m2Frame = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Frame, Error>) in
                    self.cryptoWaiter = continuation
                }
            }
            guard m2Frame.messageType == .cryptoM2 else {
                throw LinkClientError.connectFailed(description: "Unexpected crypto message")
            }
            let responderIdentity = try noise.readM2(Data(m2Frame.payload))

            let m3 = try noise.writeM3(identity: identity)
            try await sendRaw(Frame(messageType: .cryptoM3, streamId: 0, payload: [UInt8](m3)), on: nwConnection)

            let (sendState, receiveState, finalHash) = try noise.split()
            channel = SecureChannel(sendState: sendState, receiveState: receiveState, handshakeHash: finalHash)
            handshake = nil
            peerFingerprint = responderIdentity.fingerprint

            guard connection === nwConnection else { return }
            statesContinuation.yield(.connected)
            resumeConnect(nil)
        } catch {
            handshake = nil
            channel = nil
            resumeCryptoWaiter(LinkClientError.connectFailed(description: "Crypto handshake aborted"))
            failConnect(connection: nwConnection, reason: "Crypto handshake failed: \(String(describing: error))")
        }
    }

    private func resumeCryptoWaiter(_ error: Error) {
        if let waiter = cryptoWaiter {
            cryptoWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    private static func wireHeader(
        version: UInt16,
        messageType: MessageType,
        streamId: UInt32,
        payloadLength: Int
    ) -> [UInt8] {
        var header = LinkProtocolConstants.magicBytes
        header.append(UInt8(truncatingIfNeeded: version >> 8))
        header.append(UInt8(truncatingIfNeeded: version))
        header.append(UInt8(truncatingIfNeeded: messageType.rawValue >> 8))
        header.append(UInt8(truncatingIfNeeded: messageType.rawValue))
        header.append(UInt8(truncatingIfNeeded: streamId >> 24))
        header.append(UInt8(truncatingIfNeeded: streamId >> 16))
        header.append(UInt8(truncatingIfNeeded: streamId >> 8))
        header.append(UInt8(truncatingIfNeeded: streamId))
        let length = UInt32(payloadLength)
        header.append(UInt8(truncatingIfNeeded: length >> 24))
        header.append(UInt8(truncatingIfNeeded: length >> 16))
        header.append(UInt8(truncatingIfNeeded: length >> 8))
        header.append(UInt8(truncatingIfNeeded: length))
        return header
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
        case .unsupportedVersion(let received):
            sendErrorFrame(
                code: 409,
                message: "Protocol version mismatch: peer sent \(received), expected \(LinkProtocolConstants.protocolVersion)"
            )
            connection?.cancel()
        }
    }

    private func sendErrorFrame(code: Int, message: String) {
        let json = "{\"code\":\(code),\"message\":\"\(message)\"}"
        sendNow(Frame(messageType: .error, streamId: 0, payloadString: json))
    }

    /// Fire-and-forget send. Seals with the transport channel when one is
    /// active (e.g. auto-pong); otherwise writes plaintext (pre-crypto errors).
    private func sendNow(_ frame: Frame) {
        guard let connection else { return }
        var bytes: [UInt8]
        if var activeChannel = channel, !frame.isCryptoHandshake {
            let header = Self.wireHeader(
                version: frame.version,
                messageType: frame.messageType,
                streamId: frame.streamId,
                payloadLength: frame.payload.count + 16
            )
            guard let sealed = try? activeChannel.seal(header: header, payload: Data(frame.payload)) else { return }
            channel = activeChannel
            bytes = header + [UInt8](sealed)
        } else {
            guard let encoded = try? FrameEncoder.encode(frame) else { return }
            bytes = encoded
        }
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func teardown(_ nwConnection: NWConnection) {
        if connection === nwConnection {
            connection = nil
        }
        channel = nil
        handshake = nil
        pendingCryptoFrames = []
        resumeCryptoWaiter(LinkClientError.connectFailed(description: "Connection closed"))
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
