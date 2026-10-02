import Foundation
import Network
import XCTest

import LinkProtocol
@testable import LinkConnection
import LinkSecurity
import CryptoKit

/// Base class for loopback TCP servers that speak the full encrypted
/// protocol: Noise XX responder handshake, then payload encryption with the
/// same rules as the Android client. Subclasses implement business logic via
/// `handlePlaintext(_:)` / `onChannelReady()`.
class CryptoLoopbackServer: @unchecked Sendable {
    let queue: DispatchQueue
    let listener: NWListener
    var connection: NWConnection?
    var decoder = FrameDecoder()
    let identity = LinkIdentity(
        staticKey: Curve25519.KeyAgreement.PrivateKey(),
        signingKey: Curve25519.Signing.PrivateKey()
    )
    var handshake: NoiseHandshake?
    var channel: SecureChannel?
    var peerGone = false
    var channelReadyFlag = false

    init(label: String) throws {
        queue = DispatchQueue(label: label)
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }

    func awaitBoundPort(timeout: TimeInterval = 5) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = listener.port?.rawValue, port != 0 { return port }
            usleep(10_000)
        }
        listener.cancel()
        throw NSError(
            domain: "CryptoLoopbackServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "listener never bound"]
        )
    }

    var peerDisconnected: Bool {
        queue.sync { peerGone }
    }

    var peerAccepted: Bool {
        queue.sync { connection != nil }
    }

    var channelReady: Bool {
        queue.sync { channelReadyFlag }
    }

    func stop() {
        queue.sync {
            connection?.cancel()
            listener.cancel()
        }
    }

    /// Injects raw (pre-encryption) bytes onto the wire.
    func injectRaw(_ bytes: [UInt8]) {
        queue.sync {
            connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
        }
    }

    /// Seals and injects a frame as if sent by the phone.
    func inject(_ frame: Frame) {
        queue.sync {
            sealAndSend(frame)
        }
    }

    // MARK: - Subclass hooks

    /// Called once the Noise handshake completes and the channel is usable.
    func onChannelReady() {}

    /// Called for each decrypted inbound frame.
    func handlePlaintext(_ frame: Frame) {}

    // MARK: - Internals (visible to subclasses)

    func accept(_ connection: NWConnection) {
        queue.async {
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .cancelled, .failed:
                    let queue = self.queue
                    queue.async { self.peerGone = true }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
            self.startReceiving(connection)
        }
    }

    /// Override to replace the continuous receive loop with a custom drain
    /// strategy.
    func startReceiving(_ connection: NWConnection) {
        receiveLoop(connection)
    }

    /// Performs a single receive and processes whatever arrives.
    func receiveOnce(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if isComplete || error != nil {
                self.queue.async { self.peerGone = true }
            }
        }
    }

    func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if isComplete || error != nil {
                self.queue.async { self.peerGone = true }
                return
            }
            self.receiveLoop(connection)
        }
    }

    func consume(_ data: Data) {
        do {
            let frames = try decoder.feed([UInt8](data))
            for frame in frames {
                handle(frame)
            }
        } catch {
            decoder.reset()
        }
    }

    func handle(_ frame: Frame) {
        if frame.messageType == .cryptoM1 {
            var noise = NoiseHandshake(staticKey: identity.staticKey)
            do {
                try noise.readM1(Data(frame.payload))
                let m2 = try noise.writeM2(identity: identity)
                handshake = noise
                sendRaw(Frame(messageType: .cryptoM2, streamId: 0, payload: [UInt8](m2)))
            } catch {
                connection?.cancel()
            }
            return
        }
        if frame.messageType == .cryptoM3, handshake != nil {
            var noise = handshake!
            guard (try? noise.readM3(Data(frame.payload))) != nil else {
                connection?.cancel()
                return
            }
            let (initiatorSend, initiatorReceive, hash) = (try? noise.split()) ?? (CipherState(), CipherState(), Data())
            // Responder: sends with k2, receives with k1.
            channel = SecureChannel(sendState: initiatorReceive, receiveState: initiatorSend, handshakeHash: hash)
            handshake = nil
            channelReadyFlag = true
            onChannelReady()
            return
        }
        if handshake != nil {
            connection?.cancel()
            return
        }

        guard var activeChannel = channel else {
            connection?.cancel()
            return
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
            connection?.cancel()
            return
        }
        channel = activeChannel
        handlePlaintext(
            Frame(
                version: frame.version,
                messageType: frame.messageType,
                streamId: frame.streamId,
                payload: [UInt8](plaintext)
            )
        )
    }

    func sendRaw(_ frame: Frame) {
        guard let bytes = try? FrameEncoder.encode(frame) else { return }
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func sealAndSend(_ frame: Frame) {
        guard var activeChannel = channel else { return }
        let header = Self.wireHeader(
            version: frame.version,
            messageType: frame.messageType,
            streamId: frame.streamId,
            payloadLength: frame.payload.count + 16
        )
        guard let sealed = try? activeChannel.seal(header: header, payload: Data(frame.payload)) else { return }
        channel = activeChannel
        connection?.send(content: Data(header + [UInt8](sealed)), completion: .contentProcessed { _ in })
    }

    static func wireHeader(
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
}
