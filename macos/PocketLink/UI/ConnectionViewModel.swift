import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

import LinkClipboard
import LinkConnection
import LinkDiscovery
import LinkFiles
import LinkNotifications
import LinkPairing
import LinkProtocol
import LinkSecurity

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

    private enum SleepSuspension {
        case session(endpoint: NWEndpoint, peerId: String, display: String)
        case browsing
    }

    private struct PendingPairing: Equatable {
        let token: PairingToken
        let peerId: String
        let display: String
    }

    private(set) var phase: Phase = .idle
    private(set) var sendClipboardOnCopy = false
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginHint = ""
    private(set) var hasUnreadNotifications = false
    private var lastSeenNotificationDate: Date?
    var onUnreadNotificationsChanged: ((Bool) -> Void)?
    private(set) var activeTransferProgress: Double?
    var onTransferProgressChanged: ((Double?) -> Void)?
    var openURLDraft = ""
    private(set) var openURLStatus = ""
    private var openURLStatusClearTask: Task<Void, Never>?
    private var batteryAlertAdvisor = BatteryAlertAdvisor()
    private(set) var clipboardSyncStatus = ""
    var host = ""
    var portText = "52345"
    private(set) var lastRoundTrip = ""
    private(set) var lastDeviceError = ""
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var isBrowsing = false
    private(set) var discoveryError = ""
    private(set) var notifications: [LinkNotification] = []
    private(set) var phoneBattery: PhoneBattery?
    var replyDrafts: [String: String] = [:]
    private(set) var replyStatuses: [String: String] = [:]
    private(set) var fileTransfers: [FileReceiver.Progress] = []
    private(set) var outgoingTransfers: [OutgoingTransfer] = []
    private(set) var transferHistory: [TransferHistoryEntry] = []
    private(set) var trustedPeers: [TrustedPeer] = []

    enum MirrorPhase: Equatable {
        case idle
        case requesting
        case active
    }

    private(set) var mirrorPhase: MirrorPhase = .idle
    private(set) var mirrorStatusText = ""
    private(set) var mirrorVideoSize: CGSize?
    private(set) var isMirrorPoppedOut = false
    private(set) var mirrorTouchView: TouchForwardingView?
    private var mirrorWindowController: MirrorWindowController?
    private var mirrorRecorder: MirrorRecorder?
    private var recordingStartedAt: Date?
    private(set) var isMirrorRecording = false
    private(set) var recordingStatusText = ""
    private var recordingStatusClearTask: Task<Void, Never>?

    struct OutgoingTransfer: Identifiable, Equatable {
        enum State: Equatable {
            case queued
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
    private var heartbeatTask: Task<Void, Never>?
    private var lastPongAt: ContinuousClock.Instant?
    private var heartbeatPending = false
    private var missedHeartbeats = 0
    private var pendingPing: (id: UInt32, sentAt: ContinuousClock.Instant)?
    private var browser: LinkBrowser?
    private var devicesTask: Task<Void, Never>?
    private var discoveryStateTask: Task<Void, Never>?
    private let trustStore: TrustStore
    private let deviceName: String
    private let incomingDirectory: URL
    private let supportDirectory: URL
    private var pendingEndpoint: NWEndpoint?
    private var pendingPeerId: String?
    private var activePairing: PendingPairing?
    private(set) var pairingQRImage: NSImage?
    var pairingQRPayload: String? { activePairing?.token.qrPayload }
    private(set) var macAddress = ""
    private let fileReceiver = FileReceiver()
    private let transferHistoryStore: TransferHistoryStore
    private let notificationStore: NotificationStore
    private var isSendingFile = false
    private var pendingSendURLs: [(id: String, url: URL)] = []
    private var activeSendTask: Task<Void, Never>?
    private var ackTimeoutTask: Task<Void, Never>?
    private var activeOpenPanel: NSOpenPanel?
    private var activeSavePanel: NSSavePanel?
    private let pasteboardMonitor = PasteboardMonitor()
    private var appSettings: AppSettings?
    private var lastClipboardSentText: String?
    private var lastClipboardReceivedText: String?
    private var pendingClipboardAckTimestamp: Int64?
    private var clipboardAckTask: Task<Void, Never>?
    private var replyAckTasks: [String: Task<Void, Never>] = [:]
    private static let replyAckTimeout: Int64 = 5
    private static let ackTimeout: Int64 = 30
    private var mirrorDecoder: VideoDecoder?
    private var mirrorStartTimeoutTask: Task<Void, Never>?
    private var mirrorStatsTask: Task<Void, Never>?
    private var mirrorLastDecodedCount = 0
    private var lastEndpoint: NWEndpoint?
    private var lastPeerId: String?
    private var lastDisplay: String?
    private var isUserDisconnect = false
    private var sleepSuspension: SleepSuspension?
    private var isSystemSleep = false
    private var sleepObserverTokens: [NSObjectProtocol] = []
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

    func refreshTransferHistory() {
        Task { [weak self] in
            guard let self else { return }
            self.transferHistory = await self.transferHistoryStore.all()
        }
    }

    func clearTransferHistory() {
        Task { [weak self] in
            guard let self else { return }
            await self.transferHistoryStore.clear()
            self.transferHistory = []
        }
    }

    init(reconnectPolicy: ReconnectPolicy = ReconnectPolicy()) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PocketLink", isDirectory: true)
        supportDirectory = directory
        trustStore = TrustStore(directory: directory)
        transferHistoryStore = TransferHistoryStore(directory: directory)
        notificationStore = NotificationStore(directory: directory)
        incomingDirectory = directory.appendingPathComponent("Incoming", isDirectory: true)
        deviceName = Host.current().localizedName ?? "Mac"
        self.reconnectPolicy = reconnectPolicy
        macAddress = LocalIPAddress.primaryIPv4() ?? ""
        let settings = AppSettings.load(directory: directory)
        appSettings = settings
        sendClipboardOnCopy = settings.sendClipboardOnCopy
        pasteboardMonitor.onCopy = { [weak self] text in
            self?.sendClipboardText(text)
        }
        if sendClipboardOnCopy {
            pasteboardMonitor.start()
        }
        refreshTrustedPeers()
        refreshTransferHistory()
        refreshNotifications()
        syncLaunchAtLoginState()
        observeSleepWake()
    }

    private func refreshNotifications() {
        Task { [weak self] in
            guard let self else { return }
            self.updateNotifications(await self.notificationStore.all())
        }
    }

    /// Central notifications setter: recomputes the unread flag against the
    /// last-seen threshold so the status item badge stays in sync.
    private func updateNotifications(_ value: [LinkNotification]) {
        notifications = value
        hasUnreadNotifications = value.contains { notification in
            guard let threshold = lastSeenNotificationDate else { return true }
            return notification.postTime > threshold
        }
        onUnreadNotificationsChanged?(hasUnreadNotifications)
    }

    /// Called when the panel becomes visible (and again when it closes, to
    /// catch arrivals shown while it was open). Notification timestamps come
    /// from the phone, so the threshold is the newest known postTime —
    /// never local "now" (device clocks can differ).
    func markNotificationsSeen() {
        lastSeenNotificationDate = notifications.first?.postTime
        guard hasUnreadNotifications else { return }
        hasUnreadNotifications = false
        onUnreadNotificationsChanged?(false)
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserverTokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemSleep() }
        })
        sleepObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWake() }
        })
    }

    private func handleSystemSleep() {
        if let endpoint = lastEndpoint, client != nil {
            sleepSuspension = .session(
                endpoint: endpoint,
                peerId: lastPeerId ?? "last",
                display: lastDisplay ?? "device"
            )
        } else if browser != nil {
            sleepSuspension = .browsing
        } else {
            return
        }
        isSystemSleep = true
        stopSession()
        switch phase {
        case .connected, .connecting, .reconnecting, .pairing:
            phase = .idle
        case .idle, .failed:
            break
        }
    }

    private func handleSystemWake() {
        guard isSystemSleep else { return }
        isSystemSleep = false
        switch sleepSuspension {
        case .session(let endpoint, let peerId, let display):
            sleepSuspension = nil
            if let pairing = activePairing, pairing.token.isExpired {
                activePairing = nil
                pairingQRImage = nil
                pendingEndpoint = nil
                pendingPeerId = nil
            }
            startSession(to: endpoint, peerId: peerId, display: display)
        case .browsing:
            sleepSuspension = nil
            startBrowsing()
        case nil:
            break
        }
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
                self.drainPendingSends()
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
        updateNotifications([])
        replyStatuses = [:]
        replyAckTasks.values.forEach { $0.cancel() }
        replyAckTasks = [:]
        Task { [weak self] in
            await self?.notificationStore.clear()
        }
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
        replyDrafts[notificationId] = ""
        setReplyStatus(notificationId, "Sent…")
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
                self?.scheduleReplyAckTimeout(notificationId: notificationId)
            } catch {
                self?.setReplyStatus(notificationId, "Failed to send")
            }
        }
    }

    private func scheduleReplyAckTimeout(notificationId: String) {
        replyAckTasks[notificationId]?.cancel()
        replyAckTasks[notificationId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.replyAckTimeout))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.replyStatuses[notificationId] == "Sent…" {
                self.setReplyStatus(notificationId, "Sent · no confirmation")
                self.replyAckTasks[notificationId] = nil
            }
        }
    }

    private func setReplyStatus(_ id: String, _ status: String) {
        replyStatuses[id] = status
    }

    func dismissNotification(_ notification: LinkNotification) {
        guard let client, case .connected = phase else { return }
        Task {
            guard let frame = try? NotificationAction.frame(
                id: notification.id,
                action: NotificationAction.dismiss,
                streamId: await client.nextStreamId()
            ) else { return }
            try? await client.send(frame)
        }
    }

    func saveTransfer(_ progress: FileReceiver.Progress) {
        guard case .completed = progress.state else { return }
        guard activeSavePanel == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = progress.metadata.name
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        activeSavePanel = panel
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let panel = self.activeSavePanel
                self.activeSavePanel = nil
                guard response == .OK, let destination = panel?.url else { return }
                self.performSave(progress, to: destination)
            }
        }
    }

    private func performSave(_ progress: FileReceiver.Progress, to destination: URL) {
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

    func setSendClipboardOnCopy(_ enabled: Bool) {
        guard sendClipboardOnCopy != enabled else { return }
        sendClipboardOnCopy = enabled
        appSettings?.sendClipboardOnCopy = enabled
        appSettings?.save(directory: supportDirectory)
        if enabled {
            pasteboardMonitor.start()
        } else {
            pasteboardMonitor.stop()
        }
    }

    func openURLOnPhone() {
        let trimmed = openURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            openURLStatus = "Enter a valid http(s) URL"
            scheduleOpenURLStatusClear()
            return
        }
        guard client != nil, case .connected = phase else { return }
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            try? await client.send(OpenURLMessage.frame(url: trimmed, streamId: client.nextStreamId()))
        }
        openURLDraft = ""
        openURLStatus = "Opening on phone…"
        scheduleOpenURLStatusClear()
    }

    private func scheduleOpenURLStatusClear() {
        openURLStatusClearTask?.cancel()
        openURLStatusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.openURLStatus = ""
        }
    }

    /// Posts a user notification for a phone battery threshold crossing.
    /// Authorization is requested lazily on first use.
    private func postBatteryAlert(_ alert: BatteryAlertLevel, level: Int) {
        let content = UNMutableNotificationContent()
        switch alert {
        case .low:
            content.title = "Phone battery low"
        case .critical:
            content.title = "Phone battery critically low"
        case .none:
            return
        }
        content.body = "\(level)% remaining"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "pocketlink.battery.\(alert == .critical ? "critical" : "low").\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    // MARK: - Launch at Login
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let isRegistered = service.status == .enabled || service.status == .requiresApproval
        guard enabled != isRegistered else {
            syncLaunchAtLoginState()
            return
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginHint = ""
        } catch {
            launchAtLoginHint = "Launch at login failed: \(error.localizedDescription)"
        }
        syncLaunchAtLoginState()
    }

    /// SMAppService itself persists the registration — the system status is
    /// the single source of truth, so the toggle always reflects it.
    private func syncLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginHint = ""
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginHint = "Approve PocketLink in System Settings → Login Items to activate."
        case .notRegistered, .notFound:
            launchAtLogin = false
        @unknown default:
            launchAtLogin = false
        }
    }

    func sendClipboardToPhone() {
        guard client != nil, case .connected = phase else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            lastDeviceError = "Clipboard is empty"
            return
        }
        lastClipboardSentText = nil
        sendClipboardText(text)
    }

    private func sendClipboardText(_ text: String) {
        guard let client, case .connected = phase else { return }
        guard text != lastClipboardSentText, text != lastClipboardReceivedText else { return }
        let date = Date()
        let timestamp = Int64((date.timeIntervalSince1970 * 1000).rounded())
        lastClipboardSentText = text
        pendingClipboardAckTimestamp = timestamp
        clipboardSyncStatus = "Clipboard sent…"
        pasteboardMonitor.markSent(text)
        Task { [weak self] in
            do {
                try await client.send(
                    ClipboardMessage.frame(text: text, streamId: client.nextStreamId(), timestamp: date)
                )
                self?.awaitClipboardAck(timestamp: timestamp)
            } catch {
                self?.pendingClipboardAckTimestamp = nil
                self?.clipboardSyncStatus = ""
                self?.lastDeviceError = "Clipboard send failed"
            }
        }
    }

    private func awaitClipboardAck(timestamp: Int64) {
        clipboardAckTask?.cancel()
        clipboardAckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.pendingClipboardAckTimestamp == timestamp {
                self.pendingClipboardAckTimestamp = nil
                self.clipboardSyncStatus = "Clipboard sent · no confirmation"
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
        let localFingerprint: String?
        do {
            localFingerprint = try LinkIdentity.load().fingerprint
        } catch {
            // Pairing still completes via the token, but the QR carries no `k=`
            // and the phone cannot pin our fingerprint out of band.
            localFingerprint = nil
            lastDeviceError = "Keychain error — pairing without identity pinning (\(error.localizedDescription))"
        }
        let token = PairingToken.generate(identityFingerprint: localFingerprint)
        activePairing = PendingPairing(token: token, peerId: peerId, display: display)
        pendingEndpoint = endpoint
        pendingPeerId = peerId
        startSession(to: endpoint, peerId: peerId, display: display)
    }

    private static let qrContext = CIContext()
    private static let heartbeatInterval: Duration = .seconds(12)
    private static let maxMissedHeartbeats = 2

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

    private func trustPeer(_ peerId: String, name: String, fingerprint: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.trustStore.trust(peerId, name: name, fingerprint: fingerprint)
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
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pendingPing = nil
        endMirroring(sendStop: false, statusText: "")
        if !pendingSendURLs.isEmpty {
            pendingSendURLs.removeAll()
            for transfer in outgoingTransfers where transfer.state == .queued {
                updateOutgoing(fileId: transfer.fileId) { $0.state = .failed("Disconnected") }
            }
        }
        batteryAlertAdvisor = BatteryAlertAdvisor()
        stopBrowsing()
        guard let oldClient = client else { return }
        client = nil
        Task { await oldClient.disconnect() }
    }

    // MARK: - Screen Mirroring

    func toggleMirroring() {
        switch mirrorPhase {
        case .idle:
            startMirroring()
        case .requesting, .active:
            stopMirroring()
        }
    }

    func startMirroring() {
        guard client != nil, case .connected = phase, mirrorPhase == .idle else { return }
        mirrorPhase = .requesting
        mirrorStatusText = "Waiting for phone…"
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            try? await client.send(MirrorMessages.startFrame(streamId: client.nextStreamId()))
        }
        mirrorStartTimeoutTask?.cancel()
        mirrorStartTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.mirrorPhase == .requesting else { return }
            self.endMirroring(sendStop: false, statusText: "Phone didn't respond to mirroring request")
        }
    }

    func stopMirroring() {
        guard mirrorPhase != .idle else { return }
        endMirroring(sendStop: true, statusText: "")
    }

    /// Detaches the live video into a standalone window. The session keeps
    /// running and the panel shows a placeholder while detached.
    func popOutMirror() {
        guard mirrorPhase == .active, let view = mirrorTouchView,
              mirrorWindowController == nil else { return }
        let controller = MirrorWindowController(
            videoView: view,
            dimensions: mirrorVideoSize ?? CGSize(width: 9, height: 19.5)
        )
        controller.onWindowClosed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mirrorWindowController = nil
                self.isMirrorPoppedOut = false
            }
        }
        mirrorWindowController = controller
        isMirrorPoppedOut = true
        controller.showAndActivate()
    }

    /// Closes the pop-out window so the video returns to the menu bar panel.
    func returnMirrorToPanel() {
        guard let controller = mirrorWindowController else { return }
        controller.close()
    }

    // MARK: - Mirror Capture (screenshots & recording, Mac-local)

    func toggleMirrorRecording() {
        guard mirrorPhase == .active, let decoder = mirrorDecoder else { return }
        if mirrorRecorder != nil {
            stopMirrorRecording()
            return
        }
        guard let format = decoder.currentFormatDescription else {
            lastDeviceError = "Recording failed: no video format yet"
            return
        }
        let directory = supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("PocketLink Mirror \(Self.fileTimestamp()).mp4")
            let recorder = MirrorRecorder()
            try recorder.start(url: url, formatDescription: format)
            mirrorRecorder = recorder
            recordingStartedAt = Date()
            isMirrorRecording = true
            recordingStatusText = "Recording…"
        } catch {
            lastDeviceError = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func stopMirrorRecording() {
        guard let recorder = mirrorRecorder else { return }
        mirrorRecorder = nil
        isMirrorRecording = false
        recordingStartedAt = nil
        recordingStatusText = "Finishing recording…"
        recorder.finish { [weak self] url, error in
            Task { @MainActor [weak self] in
                self?.recordingDidFinish(url: url, error: error)
            }
        }
    }

    private func recordingDidFinish(url: URL?, error: Error?) {
        if let url {
            recordingStatusText = "Saved: Recordings/\(url.lastPathComponent)"
        } else if let error {
            recordingStatusText = "Recording failed: \(error.localizedDescription)"
        } else {
            recordingStatusText = ""
        }
        recordingStatusClearTask?.cancel()
        recordingStatusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, !self.isMirrorRecording else { return }
            self.recordingStatusText = ""
        }
    }

    func captureMirrorScreenshot() {
        guard mirrorPhase == .active, let decoder = mirrorDecoder,
              let png = decoder.screenshotPNG() else {
            lastDeviceError = "Screenshot failed — no frame available yet"
            return
        }
        let directory = supportDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("PocketLink Screenshot \(Self.fileTimestamp()).png")
            try png.write(to: url)
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: directory.path)
        } catch {
            lastDeviceError = "Screenshot failed: \(error.localizedDescription)"
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func endMirroring(sendStop: Bool, statusText: String) {
        mirrorStartTimeoutTask?.cancel()
        mirrorStartTimeoutTask = nil
        mirrorStatsTask?.cancel()
        mirrorStatsTask = nil
        mirrorLastDecodedCount = 0
        if let controller = mirrorWindowController {
            controller.window?.delegate = nil
            controller.close()
        }
        mirrorWindowController = nil
        if let recorder = mirrorRecorder {
            mirrorRecorder = nil
            isMirrorRecording = false
            recordingStartedAt = nil
            recordingStatusText = "Finishing recording…"
            recorder.finish { [weak self] url, error in
                Task { @MainActor [weak self] in
                    self?.recordingDidFinish(url: url, error: error)
                }
            }
        }
        mirrorTouchView = nil
        mirrorVideoSize = nil
        isMirrorPoppedOut = false
        mirrorDecoder?.invalidate()
        mirrorDecoder = nil
        let wasActive = mirrorPhase != .idle
        mirrorPhase = .idle
        mirrorStatusText = statusText
        if sendStop, wasActive, client != nil, case .connected = phase {
            Task { [weak self] in
                guard let self, let client = self.client else { return }
                try? await client.send(MirrorMessages.stopFrame(streamId: client.nextStreamId()))
            }
        }
        if !statusText.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.mirrorPhase == .idle, self.mirrorStatusText == statusText else { return }
                self.mirrorStatusText = ""
            }
        }
    }

    private func handleMirrorConfig(_ config: MirrorMessages.Config) {
        guard mirrorPhase == .requesting else { return }
        mirrorStartTimeoutTask?.cancel()
        mirrorStartTimeoutTask = nil

        let decoder = VideoDecoder()
        do {
            try decoder.configure(
                width: config.width,
                height: config.height,
                sps: config.sps,
                pps: config.pps
            )
        } catch {
            mirrorPhase = .idle
            mirrorStatusText = ""
            lastDeviceError = "Mirroring failed: unsupported video parameters"
            Task { [weak self] in
                guard let self, let client = self.client else { return }
                try? await client.send(MirrorMessages.stopFrame(streamId: client.nextStreamId()))
            }
            return
        }

        mirrorDecoder = decoder
        let view = TouchForwardingView()
        view.install(decoder.displayLayer)
        view.updateVideoAspect(width: config.width, height: config.height)
        view.onGesture = { [weak self] action, point in
            Task { @MainActor [weak self] in
                self?.sendRemoteTouch(action: action, x: point.x, y: point.y)
            }
        }
        view.onRemoteText = { [weak self] content in
            Task { @MainActor [weak self] in
                self?.sendRemoteText(content)
            }
        }
        mirrorTouchView = view
        mirrorVideoSize = CGSize(width: config.width, height: config.height)
        isMirrorPoppedOut = false
        decoder.onSampleBuffer = { [weak self] sample in
            self?.mirrorRecorder?.append(sample)
        }

        mirrorPhase = .active
        mirrorStatusText = "Mirroring \(config.width)×\(config.height)"
        startMirrorStatsLoop()
    }

    private func handleMirrorFrame(_ encoded: MirrorMessages.EncodedFrame) {
        guard mirrorPhase == .active, let decoder = mirrorDecoder else { return }
        decoder.decode(
            timestampMs: encoded.timestampMs,
            keyframe: encoded.keyframe,
            accessUnit: encoded.accessUnit
        )
    }

    private func sendRemoteTouch(action: MirrorMessages.TouchAction, x: Double, y: Double) {
        guard mirrorPhase == .active, client != nil, case .connected = phase else { return }
        let point = MirrorMessages.TouchPoint(action: action, x: x, y: y)
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            try? await client.send(MirrorMessages.touchFrame(point, streamId: client.nextStreamId()))
        }
    }

    private func sendRemoteText(_ content: MirrorMessages.TextContent) {
        guard mirrorPhase == .active, client != nil, case .connected = phase else { return }
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            try? await client.send(
                MirrorMessages.remoteTextFrame(content, streamId: client.nextStreamId())
            )
        }
    }

    private func startMirrorStatsLoop() {
        mirrorStatsTask?.cancel()
        mirrorStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.mirrorPhase == .active,
                      let decoder = self.mirrorDecoder else { return }
                let stats = decoder.stats
                let fps = stats.decoded - self.mirrorLastDecodedCount
                self.mirrorLastDecodedCount = stats.decoded
                let size = decoder.dimensions
                if size.width > 0 {
                    self.mirrorStatusText = String(
                        format: "Mirroring %d×%d · %d fps",
                        Int(size.width), Int(size.height), fps
                    )
                }
                if self.isMirrorRecording, let startedAt = self.recordingStartedAt {
                    let elapsed = Int(Date().timeIntervalSince(startedAt))
                    self.recordingStatusText = String(
                        format: "Recording · %02d:%02d",
                        elapsed / 60, elapsed % 60
                    )
                }
            }
        }
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
                await self?.handleFrame(frame)
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
                let peerFingerprint = await client.peerFingerprint
                if let pinned = await trustStore.fingerprint(for: peerId),
                   pinned != peerFingerprint {
                    lastDeviceError = "Device identity changed since pairing — remove the device and pair again"
                    await client.disconnect()
                    outcome = .ended
                    break loop
                }
                trustPeer(peerId, name: display, fingerprint: peerFingerprint)
                lastPongAt = .now
                heartbeatPending = false
                missedHeartbeats = 0
                heartbeatTask?.cancel()
                heartbeatTask = Task { [weak self] in
                    await self?.runHeartbeat(client: client)
                }
            case .failed(let reason):
                phase = pairingAwarePhase(.failed(reason))
                phoneBattery = nil
                if !isUserDisconnect {
                    lastDeviceError = "Connection lost — \(reason)"
                    outcome = .droppedUnexpectedly
                }
                break loop
            case .closed:
                if case .failed = phase {} else if !isUserDisconnect {
                    phase = pairingAwarePhase(.idle)
                    phoneBattery = nil
                    lastDeviceError = "Disconnected"
                    outcome = .droppedUnexpectedly
                }
                break loop
            }
        }
        connectTask.cancel()
        framesTask.cancel()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        return outcome
    }

    private func runHeartbeat(client: LinkClient) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.heartbeatInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if heartbeatPending {
                missedHeartbeats += 1
                if missedHeartbeats >= Self.maxMissedHeartbeats {
                    lastDeviceError = "No response from device"
                    await client.disconnect()
                    return
                }
            } else {
                missedHeartbeats = 0
            }
            do {
                _ = try await client.sendPing()
                heartbeatPending = true
            } catch {
                lastDeviceError = "Heartbeat failed"
                await client.disconnect()
                return
            }
        }
    }

    private func handleFrame(_ frame: Frame) async {
        switch frame.messageType {
        case .pong:
            lastPongAt = .now
            heartbeatPending = false
            guard let pending = pendingPing, pending.id == frame.streamId else { return }
            let elapsed = ContinuousClock.now - pending.sentAt
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e18
            lastRoundTrip = String(format: "%.0f ms", milliseconds)
            pendingPing = nil
        case .error:
            lastDeviceError = deviceErrorDescription(for: frame)
        case .clipboard:
            guard let parsed = ClipboardMessage.parse(frame) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(parsed.text, forType: .string)
            lastClipboardReceivedText = parsed.text
            pasteboardMonitor.markReceived(parsed.text)
            clipboardSyncStatus = "Clipboard received · \(Date().formatted(date: .omitted, time: .shortened))"
            if let client {
                Task {
                    try? await client.send(
                        ClipboardMessage.ackFrame(timestamp: parsed.timestamp, streamId: client.nextStreamId())
                    )
                }
            }
        case .clipboardAck:
            guard let timestamp = ClipboardMessage.parseAck(frame),
                  pendingClipboardAckTimestamp == timestamp else { return }
            pendingClipboardAckTimestamp = nil
            clipboardAckTask?.cancel()
            clipboardAckTask = nil
            clipboardSyncStatus = "Clipboard delivered · \(Date().formatted(date: .omitted, time: .shortened))"
        case .fileHeader:
            guard let metadata = FileMetadata.parse(frame) else { return }
            do {
                let progress = try await fileReceiver.begin(metadata, in: incomingDirectory)
                updateTransfer(progress)
            } catch {
                lastDeviceError = "Cannot receive file"
            }
        case .fileChunk:
            guard let chunk = FileChunk.parse(frame) else { return }
            do {
                guard let outcome = try await fileReceiver.append(chunk) else { return }
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
            cancelAckTimeout()
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
            recordOutgoingHistory(fileId: ack.fileId)
        case .notification:
            guard let notification = NotificationMessage.parse(frame) else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.notificationStore.record(notification)
                self.updateNotifications(await self.notificationStore.all())
            }
        case .notificationReplyAck:
            guard let ack = NotificationReplyAck.parse(frame) else { return }
            replyAckTasks[ack.id]?.cancel()
            replyAckTasks[ack.id] = nil
            setReplyStatus(ack.id, ack.success ? "Delivered ✓" : "Failed — phone reported error")
        case .battery:
            if let battery = BatteryMessage.parse(frame) {
                phoneBattery = battery
                if let alert = batteryAlertAdvisor.alert(for: battery.level, isCharging: battery.isCharging) {
                    postBatteryAlert(alert, level: battery.level)
                }
            }
        case .mirrorConfig:
            guard let config = MirrorMessages.parseConfig(frame) else { return }
            handleMirrorConfig(config)
        case .mirrorFrame:
            guard let encoded = MirrorMessages.parseFrame(frame) else { return }
            handleMirrorFrame(encoded)
        case .mirrorStop:
            guard mirrorPhase != .idle else { return }
            endMirroring(sendStop: false, statusText: "Phone stopped mirroring")
        case .handshake:
            guard let info = HandshakeMessage.parse(frame) else { return }
            handleHandshake(info)
        default:
            break
        }
    }

    private func handleHandshake(_ info: HandshakeInfo) {
        if info.protocolVersion != LinkProtocolConstants.handshakeVersion {
            lastDeviceError = "Protocol version mismatch (phone reports v\(info.protocolVersion), expected v\(LinkProtocolConstants.handshakeVersion))"
            disconnect()
            return
        }
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
        drainPendingSends()
    }

    private func updateTransfer(_ progress: FileReceiver.Progress) {
        fileTransfers.removeAll { $0.id == progress.id }
        fileTransfers.insert(progress, at: 0)
        if fileTransfers.count > 10 {
            fileTransfers.removeLast(fileTransfers.count - 10)
        }
        if progress.state != .receiving {
            recordIncomingHistory(progress)
        }
        syncTransferProgress()
    }

    /// Aggregate fraction (0…1) across all in-flight transfers, nil when
    /// idle — drives the status item progress ring.
    private func syncTransferProgress() {
        var fractions: [Double] = []
        for transfer in outgoingTransfers {
            switch transfer.state {
            case .sending:
                guard transfer.totalBytes > 0 else { continue }
                fractions.append(min(1, Double(transfer.sentBytes) / Double(transfer.totalBytes)))
            case .awaitingAck:
                fractions.append(1)
            case .queued, .delivered, .mismatch, .failed:
                break
            }
        }
        for progress in fileTransfers {
            switch progress.state {
            case .receiving:
                guard progress.metadata.size > 0 else { continue }
                fractions.append(min(1, Double(progress.receivedBytes) / Double(progress.metadata.size)))
            case .completed, .failed:
                break
            }
        }
        activeTransferProgress = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
        onTransferProgressChanged?(activeTransferProgress)
    }

    func pickAndSendFile() {
        guard client != nil, case .connected = phase else { return }
        guard activeOpenPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        activeOpenPanel = panel
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let panel = self.activeOpenPanel
                self.activeOpenPanel = nil
                guard response == .OK, let url = panel?.url else { return }
                self.sendFile(at: url)
            }
        }
    }

    func sendDroppedFiles(_ urls: [URL]) {
        guard isConnected, !urls.isEmpty else {
            if !urls.isEmpty {
                lastDeviceError = "Phone not connected — connect first, then send again"
            }
            return
        }
        // Reversed so the newest-first transfer list ends up in drop order.
        for url in urls.reversed() {
            queueOutgoing(url)
        }
        drainPendingSends()
    }

    private func queueOutgoing(_ url: URL) {
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        let id = UUID().uuidString
        upsertOutgoing(
            OutgoingTransfer(
                fileId: id,
                fileURL: url,
                name: url.lastPathComponent,
                totalBytes: size,
                state: .queued
            )
        )
        pendingSendURLs.append((id: id, url: url))
    }

    private func drainPendingSends() {
        guard !isSendingFile, client != nil, case .connected = phase, !pendingSendURLs.isEmpty else { return }
        let queued = pendingSendURLs.removeFirst()
        // The queued placeholder row is replaced by the live row sendFile creates.
        outgoingTransfers.removeAll { $0.id == queued.id }
        syncTransferProgress()
        sendFile(at: queued.url)
    }

    func cancelOutgoing(_ transfer: OutgoingTransfer) {
        switch transfer.state {
        case .queued:
            pendingSendURLs.removeAll { $0.id == transfer.fileId }
            outgoingTransfers.removeAll { $0.id == transfer.id }
            syncTransferProgress()
        case .sending:
            activeSendTask?.cancel()
        case .awaitingAck:
            cancelAckTimeout()
            activeSendTask = nil
            isSendingFile = false
            sendFileCancel(fileId: transfer.fileId)
            updateOutgoing(fileId: transfer.fileId) { $0.state = .failed("Cancelled") }
            recordOutgoingHistory(fileId: transfer.fileId)
            drainPendingSends()
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

    private func scheduleAckTimeout(fileId: String) {
        cancelAckTimeout()
        ackTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ackTimeout))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.updateOutgoingIfActive(fileId: fileId) { transfer in
                if case .awaitingAck = transfer.state {
                    transfer.state = .failed("No confirmation from receiver")
                }
            }
            self.recordOutgoingHistory(fileId: fileId)
        }
    }

    private func cancelAckTimeout() {
        ackTimeoutTask?.cancel()
        ackTimeoutTask = nil
    }

    private func sendFile(at url: URL) {
        guard let client, case .connected = phase else { return }
        guard !isSendingFile, pendingSendURLs.isEmpty else {
            queueOutgoing(url)
            return
        }
        isSendingFile = true
        activeSendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSendingFile = false
                self.activeSendTask = nil
                self.drainPendingSends()
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
                    self.scheduleAckTimeout(fileId: metadata.fileId)
                } catch is CancellationError {
                    self.updateOutgoing(fileId: metadata.fileId) { $0.state = .failed("Cancelled") }
                    self.recordOutgoingHistory(fileId: metadata.fileId)
                } catch {
                    self.updateOutgoing(fileId: metadata.fileId) { $0.state = .failed("Send failed") }
                    self.recordOutgoingHistory(fileId: metadata.fileId)
                    self.lastDeviceError = "Send failed"
                }
            } catch {
                self.isSendingFile = false
                self.lastDeviceError = "Cannot send that file"
                self.drainPendingSends()
            }
        }
    }

    private func upsertOutgoing(_ transfer: OutgoingTransfer) {
        outgoingTransfers.removeAll { $0.id == transfer.id }
        outgoingTransfers.insert(transfer, at: 0)
        if outgoingTransfers.count > 10 {
            outgoingTransfers.removeLast(outgoingTransfers.count - 10)
        }
        syncTransferProgress()
    }

    private func updateOutgoing(fileId: String, transform: (inout OutgoingTransfer) -> Void) {
        guard let index = outgoingTransfers.firstIndex(where: { $0.id == fileId }) else { return }
        transform(&outgoingTransfers[index])
        syncTransferProgress()
    }

    private func updateOutgoingIfActive(fileId: String, transform: (inout OutgoingTransfer) -> Void) {
        guard let index = outgoingTransfers.firstIndex(where: { $0.id == fileId }),
              outgoingTransfers[index].state == .sending || outgoingTransfers[index].state == .awaitingAck
        else { return }
        transform(&outgoingTransfers[index])
        syncTransferProgress()
    }

    private func recordOutgoingHistory(fileId: String) {
        guard let transfer = outgoingTransfers.first(where: { $0.id == fileId }) else { return }
        let state: TransferHistoryEntry.State
        switch transfer.state {
        case .delivered: state = .delivered
        case .mismatch: state = .mismatch
        case .failed(let message): state = .failed(message)
        case .queued, .sending, .awaitingAck: return
        }
        let entry = TransferHistoryEntry(
            id: transfer.fileId,
            direction: .send,
            fileName: transfer.name,
            totalBytes: transfer.totalBytes,
            state: state
        )
        Task { [weak self] in
            guard let self else { return }
            await self.transferHistoryStore.record(entry)
            self.transferHistory = await self.transferHistoryStore.all()
        }
    }

    private func recordIncomingHistory(_ progress: FileReceiver.Progress) {
        let state: TransferHistoryEntry.State
        switch progress.state {
        case .completed: state = .completed
        case .failed(let reason): state = .failed(reason)
        case .receiving: return
        }
        let entry = TransferHistoryEntry(
            id: progress.metadata.fileId,
            direction: .receive,
            fileName: progress.metadata.name,
            totalBytes: progress.metadata.size,
            state: state
        )
        Task { [weak self] in
            guard let self else { return }
            await self.transferHistoryStore.record(entry)
            self.transferHistory = await self.transferHistoryStore.all()
        }
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
