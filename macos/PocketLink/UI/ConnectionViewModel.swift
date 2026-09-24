import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import Observation

import LinkClipboard
import LinkConnection
import LinkDiscovery
import LinkFiles
import LinkNotifications
import LinkPairing
import LinkProtocol

@MainActor
@Observable
final class ConnectionViewModel {
    enum Phase: Equatable {
        case idle
        case connecting(display: String)
        case connected(display: String)
        case reconnecting(display: String)
        case failed(String)
        case pairing(display: String)
    }

    private enum SessionOutcome {
        case ended
        case droppedUnexpectedly
    }

    private struct PendingPairing: Equatable {
        let token: PairingToken
        let peerId: String
        let display: String
    }

    private(set) var phase: Phase = .idle
    var host = ""
    var portText = "52345"
    private(set) var lastRoundTrip = ""
    private(set) var lastDeviceError = ""
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var isBrowsing = false
    private(set) var discoveryError = ""
    private(set) var notifications: [LinkNotification] = []
    var replyDrafts: [String: String] = [:]
    private(set) var fileTransfers: [FileReceiver.Progress] = []
    private(set) var outgoingTransfers: [OutgoingTransfer] = []
    private(set) var trustedPeers: [TrustedPeer] = []

    struct OutgoingTransfer: Identifiable, Equatable {
        enum State: Equatable {
            case sending
            case awaitingAck
            case delivered
            case mismatch
            case failed(String)
        }

        var id: String { fileId }
        let fileId: String
        let fileURL: URL
        let name: String
        let totalBytes: Int64
        var sentBytes: Int64 = 0
        var state: State = .sending
    }

    private var client: LinkClient?
    private var sessionTask: Task<Void, Never>?
    private var pendingPing: (id: UInt32, sentAt: ContinuousClock.Instant)?
    private var browser: LinkBrowser?
    private var devicesTask: Task<Void, Never>?
    private var discoveryStateTask: Task<Void, Never>?
    private let trustStore: TrustStore
    private let deviceName: String
    private let incomingDirectory: URL
    private var pendingEndpoint: NWEndpoint?
    private var pendingPeerId: String?
    private var activePairing: PendingPairing?
    private(set) var pairingQRImage: NSImage?
    var pairingQRPayload: String? { activePairing?.token.qrPayload }
    private(set) var macAddress = ""
    private let fileReceiver = FileReceiver()
    private var isSendingFile = false
    private var activeSendTask: Task<Void, Never>?
    private var lastEndpoint: NWEndpoint?
    private var lastPeerId: String?
    private var lastDisplay: String?
    private var isUserDisconnect = false
    private let reconnectPolicy: ReconnectPolicy

    var canRetry: Bool { lastEndpoint != nil }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    func retryLast() {
        guard let endpoint = lastEndpoint else { return }
        gate(endpoint: endpoint, peerId: lastPeerId ?? "last", display: lastDisplay ?? "device")
    }

    func revokePeer(_ peer: TrustedPeer) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.trustStore.revoke(peer.id)
            self.trustedPeers = await self.trustStore.trustedPeers()
        }
    }

    func refreshTrustedPeers() {
        Task { [weak self] in
            guard let self else { return }
            self.trustedPeers = await self.trustStore.trustedPeers()
        }
    }

    init(reconnectPolicy: ReconnectPolicy = ReconnectPolicy()) {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PocketLink", isDirectory: true)
        trustStore = TrustStore(directory: supportDirectory)
        incomingDirectory = supportDirectory.appendingPathComponent("Incoming", isDirectory: true)
        deviceName = Host.current().localizedName ?? "Mac"
        self.reconnectPolicy = reconnectPolicy
        macAddress = LocalIPAddress.primaryIPv4() ?? ""
        refreshTrustedPeers()
    }

    func connect() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, let port = UInt16(trimmedPort),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            phase = .failed("Enter a valid address and port")
            return
        }
        gate(
            endpoint: NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: nwPort),
            peerId: trimmedHost,
            display: trimmedHost
        )
    }

    func connect(to device: DiscoveredDevice) {
        gate(endpoint: device.endpoint, peerId: device.name, display: device.name)
    }

    func confirmTrust() {
        guard case .pairing(let display) = phase, let endpoint = pendingEndpoint else { return }
        let peerId = pendingPeerId ?? display
        pendingEndpoint = nil
        pendingPeerId = nil
        activePairing = nil
        pairingQRImage = nil
        Task { [weak self] in
            guard let self else { return }
            try? await self.trustStore.trust(peerId, name: display)
            self.trustedPeers = await self.trustStore.trustedPeers()
            if self.client != nil {
                self.phase = .connected(display: display)
            } else {
                self.startSession(to: endpoint, peerId: peerId, display: display)
            }
        }
    }

    func cancelPairing() {
        guard activePairing != nil else { return }
        activePairing = nil
        pairingQRImage = nil
        pendingEndpoint = nil
        pendingPeerId = nil
        isUserDisconnect = true
        stopSession()
        phase = .idle
    }

    func startBrowsingIfNeeded() {
        guard browser == nil, client == nil else { return }
        startBrowsing()
    }

    func clearNotifications() {
        notifications = []
    }

    func isReplyEnabled(for notification: LinkNotification) -> Bool {
        guard isConnected else { return false }
        return !(replyDrafts[notification.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sendReply(to notification: LinkNotification) {
        guard let client, case .connected = phase else { return }
        let text = (replyDrafts[notification.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let notificationId = notification.id
        replyDrafts[notification.id] = ""
        Task { [weak self] in
            guard
                let frame = try? NotificationReply.frame(
                    id: notificationId,
                    text: text,
                    streamId: await client.nextStreamId()
                )
            else { return }
            do {
                try await client.send(frame)
            } catch {
                self?.lastDeviceError = "Reply failed"
            }
        }
    }

    func saveTransfer(_ progress: FileReceiver.Progress) {
        guard case .completed = progress.state else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = progress.metadata.name
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            let source = FileReceiver.fileURL(for: progress.metadata, in: incomingDirectory)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            lastDeviceError = "Save failed"
        }
    }

    func sendClipboardToPhone() {
        guard let client, case .connected = phase else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            lastDeviceError = "Clipboard is empty"
            return
        }
        Task { [weak self] in
            do {
                try await client.send(ClipboardMessage.frame(text: text, streamId: client.nextStreamId()))
            } catch {
                self?.lastDeviceError = "Clipboard send failed"
            }
        }
    }

    private func gate(endpoint: NWEndpoint, peerId: String, display: String) {
        isUserDisconnect = true
        stopSession()
        Task { [weak self] in
            guard let self else { return }
            let trusted = await self.trustStore.isTrusted(peerId)
            if trusted {
                self.startSession(to: endpoint, peerId: peerId, display: display)
            } else {
                self.preparePairing(to: endpoint, peerId: peerId, display: display)
            }
        }
    }

    private func preparePairing(to endpoint: NWEndpoint, peerId: String, display: String) {
        let token = PairingToken.generate()
        activePairing = PendingPairing(token: token, peerId: peerId, display: display)
        pendingEndpoint = endpoint
        pendingPeerId = peerId
        startSession(to: endpoint, peerId: peerId, display: display)
    }

    private static let qrContext = CIContext()

    private func makeQRImage(for payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (240 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = Self.qrContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    private func pairingAwarePhase(_ base: Phase) -> Phase {
        guard let pairing = activePairing, pairingQRImage != nil else { return base }
        return .pairing(display: pairing.display)
    }

    private func trustPeer(_ peerId: String, name: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.trustStore.trust(peerId, name: name)
            self.trustedPeers = await self.trustStore.trustedPeers()
        }
    }

    func sendPing() {
        guard let client, case .connected = phase else { return }
        Task { [weak self] in
            do {
                let id = try await client.sendPing()
                self?.pendingPing = (id, .now)
            } catch {
                self?.phase = .failed("Ping failed")
            }
        }
    }

    func disconnect() {
        isUserDisconnect = true
        activePairing = nil
        pairingQRImage = nil
        stopSession()
        phase = .idle
    }

    func toggleBrowsing() {
        if browser == nil {
            startBrowsing()
        } else {
            stopBrowsing()
        }
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let newBrowser = LinkBrowser()
        browser = newBrowser
        isBrowsing = true
        discoveryError = ""
        devicesTask = Task { [weak self] in
            for await devices in newBrowser.devices {
                self?.devices = devices
            }
        }
        discoveryStateTask = Task { [weak self] in
            for await state in newBrowser.states {
                guard let self else { return }
                switch state {
                case .browsing:
                    self.isBrowsing = true
                case .failed(let reason):
                    self.isBrowsing = false
                    self.discoveryError = reason
                case .idle:
                    self.isBrowsing = false
                }
            }
        }
        Task { await newBrowser.start() }
    }

    private func stopBrowsing() {
        guard let oldBrowser = browser else { return }
        browser = nil
        isBrowsing = false
        devicesTask?.cancel()
        devicesTask = nil
        discoveryStateTask?.cancel()
        discoveryStateTask = nil
        devices = []
        Task { await oldBrowser.stop() }
    }

    private func stopSession() {
        sessionTask?.cancel()
        sessionTask = nil
        pendingPing = nil
        stopBrowsing()
        guard let oldClient = client else { return }
        client = nil
        Task { await oldClient.disconnect() }
    }

    private func startSession(to endpoint: NWEndpoint, peerId: String, display: String) {
        stopSession()
        stopBrowsing()
        isUserDisconnect = false
        let newClient = LinkClient()
        client = newClient
        lastEndpoint = endpoint
        lastPeerId = peerId
        lastDisplay = display
        phase = pairingAwarePhase(.connecting(display: display))
        lastRoundTrip = ""
        lastDeviceError = ""
        sessionTask = Task { [weak self] in
            await self?.runWithReconnect(
                client: newClient,
                endpoint: endpoint,
                peerId: peerId,
                display: display
            )
        }
    }

    private func runWithReconnect(client: LinkClient, endpoint: NWEndpoint, peerId: String, display: String) async {
        var outcome = await runSession(client: client, endpoint: endpoint, peerId: peerId, display: display)
        guard outcome == .droppedUnexpectedly else { return }
        var attempt = 0
        while !Task.isCancelled, !isUserDisconnect {
            guard let delay = reconnectPolicy.delay(forAttempt: attempt) else {
                guard let pairing = activePairing else {
                    phase = .failed("Could not reconnect")
                    lastDeviceError = "Could not reconnect — scan and connect again"
                    startBrowsing()
                    return
                }
                if pairingQRImage == nil {
                    pairingQRImage = makeQRImage(for: pairing.token.qrPayload)
                    phase = .pairing(display: pairing.display)
                }
                attempt = 0
                continue
            }
            phase = pairingAwarePhase(.reconnecting(display: display))
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !isUserDisconnect else { return }
            let next = LinkClient()
            self.client = next
            pendingPing = nil
            phase = pairingAwarePhase(.connecting(display: display))
            outcome = await runSession(client: next, endpoint: endpoint, peerId: peerId, display: display)
            guard outcome == .droppedUnexpectedly else { return }
            attempt += 1
        }
    }

    private func runSession(client: LinkClient, endpoint: NWEndpoint, peerId: String, display: String) async -> SessionOutcome {
        let framesTask = Task { [weak self] in
            for await frame in client.frames {
                self?.handleFrame(frame)
            }
        }
        let connectTask = Task {
            try? await client.connect(to: endpoint)
        }
        var outcome = SessionOutcome.ended
        loop: for await state in client.states {
            switch state {
            case .idle, .connecting:
                break
            case .connected:
                phase = pairingAwarePhase(.connected(display: display))
                if let handshake = try? HandshakeMessage.frame(
                    deviceName: deviceName,
                    pairingToken: activePairing?.token.value
                ) {
                    try? await client.send(handshake)
                }
                trustPeer(peerId, name: display)
            case .failed(let reason):
                phase = pairingAwarePhase(.failed(reason))
                if !isUserDisconnect {
                    lastDeviceError = "Connection lost — \(reason)"
                    outcome = .droppedUnexpectedly
                }
                break loop
            case .closed:
                if case .failed = phase {} else if !isUserDisconnect {
                    phase = pairingAwarePhase(.idle)
                    lastDeviceError = "Disconnected"
                    outcome = .droppedUnexpectedly
                }
                break loop
            }
        }
        connectTask.cancel()
        framesTask.cancel()
        return outcome
    }

    private func handleFrame(_ frame: Frame) {
        switch frame.messageType {
        case .pong:
            guard let pending = pendingPing, pending.id == frame.streamId else { return }
            let elapsed = ContinuousClock.now - pending.sentAt
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e18
            lastRoundTrip = String(format: "%.0f ms", milliseconds)
            pendingPing = nil
        case .error:
            lastDeviceError = deviceErrorDescription(for: frame)
        case .clipboard:
            guard let text = ClipboardMessage.parse(frame) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .fileHeader:
            guard let metadata = FileMetadata.parse(frame) else { return }
            do {
                let progress = try fileReceiver.begin(metadata, in: incomingDirectory)
                updateTransfer(progress)
            } catch {
                lastDeviceError = "Cannot receive file"
            }
        case .fileChunk:
            guard let chunk = FileChunk.parse(frame) else { return }
            do {
                guard let outcome = try fileReceiver.append(chunk) else { return }
                switch outcome {
                case .receiving(let progress):
                    updateTransfer(progress)
                case .finished(let progress, let ack):
                    updateTransfer(progress)
                    sendFileAck(fileId: progress.metadata.fileId, receivedBytes: progress.receivedBytes, status: ack)
                }
            } catch {
                lastDeviceError = "File write failed"
            }
        case .fileAck:
            guard let ack = FileAck.parse(frame) else { return }
            updateOutgoingIfActive(fileId: ack.fileId) { transfer in
                switch ack.status {
                case .success:
                    transfer.state = .delivered
                case .shaMismatch:
                    transfer.state = .mismatch
                case .cancelled:
                    transfer.state = .failed("Cancelled")
                }
            }
        case .notification:
            guard let notification = NotificationMessage.parse(frame) else { return }
            notifications.removeAll { $0.id == notification.id }
            notifications.insert(notification, at: 0)
            if notifications.count > 20 {
                notifications.removeLast(notifications.count - 20)
            }
        case .handshake:
            guard let info = HandshakeMessage.parse(frame) else { return }
            handleHandshake(info)
        default:
            break
        }
    }

    private func handleHandshake(_ info: HandshakeInfo) {
        guard let pairing = activePairing, let candidate = info.pairingToken,
              pairing.token.matches(candidate) else { return }
        let peerId = pairing.peerId
        let display = pairing.display
        activePairing = nil
        pairingQRImage = nil
        pendingEndpoint = nil
        pendingPeerId = nil
        Task { [weak self] in
            guard let self else { return }
            try? await self.trustStore.trust(peerId, name: display)
            self.trustedPeers = await self.trustStore.trustedPeers()
        }
        phase = .connected(display: display)
    }

    private func updateTransfer(_ progress: FileReceiver.Progress) {
        fileTransfers.removeAll { $0.id == progress.id }
        fileTransfers.insert(progress, at: 0)
        if fileTransfers.count > 10 {
            fileTransfers.removeLast(fileTransfers.count - 10)
        }
    }

    func pickAndSendFile() {
        guard let client, case .connected = phase else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sendFile(at: url)
    }

    func cancelOutgoing(_ transfer: OutgoingTransfer) {
        switch transfer.state {
        case .sending:
            activeSendTask?.cancel()
        case .awaitingAck:
            activeSendTask = nil
            isSendingFile = false
            sendFileCancel(fileId: transfer.fileId)
            updateOutgoing(fileId: transfer.fileId) { $0.state = .failed("Cancelled") }
        default:
            break
        }
    }

    func retryOutgoing(_ transfer: OutgoingTransfer) {
        switch transfer.state {
        case .failed, .mismatch:
            guard FileManager.default.fileExists(atPath: transfer.fileURL.path) else {
                lastDeviceError = "File no longer exists"
                return
            }
            sendFile(at: transfer.fileURL)
        default:
            break
        }
    }

    private func sendFileCancel(fileId: String) {
        guard let client, case .connected = phase else { return }
        guard let frame = try? FileSender.cancelFrame(fileId: fileId, streamId: 0) else { return }
        Task { try? await client.send(frame) }
    }

    private func sendFile(at url: URL) {
        guard let client, case .connected = phase else { return }
        guard !isSendingFile else {
            lastDeviceError = "A file transfer is already in progress"
            return
        }
        isSendingFile = true
        activeSendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSendingFile = false
                self.activeSendTask = nil
            }
            do {
                let metadata = try FileSender.prepare(fileURL: url)
                self.upsertOutgoing(
                    OutgoingTransfer(fileId: metadata.fileId, fileURL: url, name: metadata.name, totalBytes: metadata.size)
                )
                do {
                    try await FileSender.send(fileURL: url, metadata: metadata, to: client) { [weak self] sent in
                        Task { @MainActor [weak self] in
                            self?.updateOutgoing(fileId: metadata.fileId) { $0.sentBytes = sent }
                        }
                    }
                    self.updateOutgoing(fileId: metadata.fileId) { $0.state = .awaitingAck }
                } catch is CancellationError {
                    self.updateOutgoing(fileId: metadata.fileId) { $0.state = .failed("Cancelled") }
                } catch {
                    self.updateOutgoing(fileId: metadata.fileId) { $0.state = .failed("Send failed") }
                    self.lastDeviceError = "Send failed"
                }
            } catch {
                self.isSendingFile = false
                self.lastDeviceError = "Cannot send that file"
            }
        }
    }

    private func upsertOutgoing(_ transfer: OutgoingTransfer) {
        outgoingTransfers.removeAll { $0.id == transfer.id }
        outgoingTransfers.insert(transfer, at: 0)
        if outgoingTransfers.count > 10 {
            outgoingTransfers.removeLast(outgoingTransfers.count - 10)
        }
    }

    private func updateOutgoing(fileId: String, transform: (inout OutgoingTransfer) -> Void) {
        guard let index = outgoingTransfers.firstIndex(where: { $0.id == fileId }) else { return }
        transform(&outgoingTransfers[index])
    }

    private func updateOutgoingIfActive(fileId: String, transform: (inout OutgoingTransfer) -> Void) {
        guard let index = outgoingTransfers.firstIndex(where: { $0.id == fileId }),
              outgoingTransfers[index].state == .sending || outgoingTransfers[index].state == .awaitingAck
        else { return }
        transform(&outgoingTransfers[index])
    }

    private func sendFileAck(fileId: String, receivedBytes: Int64, status: FileAckStatus) {
        guard let client else { return }
        Task { [weak self] in
            do {
                let frame = try FileAck.frame(
                    fileId: fileId,
                    receivedBytes: receivedBytes,
                    status: status,
                    streamId: await client.nextStreamId()
                )
                try await client.send(frame)
            } catch {
                self?.lastDeviceError = "ACK send failed"
            }
        }
    }

    private func deviceErrorDescription(for frame: Frame) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)),
              let dictionary = object as? [String: Any],
              let code = dictionary["code"] as? Int else {
            return "Device reported an error"
        }
        return "Device error \(code)"
    }
}
