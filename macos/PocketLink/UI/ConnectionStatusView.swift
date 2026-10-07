import AppKit
import SwiftUI

import LinkDiscovery
import LinkFiles
import LinkNotifications
import LinkPairing
import LinkProtocol

struct ConnectionStatusView: View {
    @Bindable var model: ConnectionViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            switch model.phase {
            case .connected:
                connectedControls
            case .pairing:
                pairingControls
            default:
                connectControls
            }

            if model.canRetry, case .failed = model.phase {
                Button("Retry connection") { model.retryLast() }
                    .font(.caption)
            }

            if !model.lastRoundTrip.isEmpty {
                Text("Last ping: \(model.lastRoundTrip)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.lastDeviceError.isEmpty {
                Text(model.lastDeviceError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.clipboardSyncStatus.isEmpty {
                Text(model.clipboardSyncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.notifications.isEmpty {
                notificationsSection
            }

            if !model.fileTransfers.isEmpty || !model.outgoingTransfers.isEmpty {
                filesSection
            }

            if !model.transferHistory.isEmpty {
                recentTransfersSection
            }

            if !model.trustedPeers.isEmpty {
                trustedPeersSection
            }

            if !model.macAddress.isEmpty {
                Text("This Mac: \(model.macAddress)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .font(.caption)
            .toggleStyle(.checkbox)
            if !model.launchAtLoginHint.isEmpty {
                Text(model.launchAtLoginHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Quit PocketLink") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: model.mirrorPhase == .active ? 420 : 280, alignment: .leading)
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    Text("Drop to send to phone")
                        .font(.callout.weight(.medium))
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.sendDroppedFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onAppear { model.startBrowsingIfNeeded() }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Notifications")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Clear") { model.clearNotifications() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ForEach(groupedNotifications, id: \.app) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: group.items.first?.symbolName ?? "bell.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(group.app)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(group.items.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.items) { notification in
                        notificationRow(notification)
                    }
                }
            }
        }
    }

    private func notificationRow(_ notification: LinkNotification) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(notification.title.isEmpty ? notification.appName : notification.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(notification.postTime, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !notification.text.isEmpty {
                    Text(notification.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let status = model.replyStatuses[notification.id] {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if notification.hasQuickReply {
                    HStack(spacing: 6) {
                        TextField(
                            "Reply…",
                            text: Binding(
                                get: { model.replyDrafts[notification.id] ?? "" },
                                set: { model.replyDrafts[notification.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { model.sendReply(to: notification) }
                        Button {
                            model.sendReply(to: notification)
                        } label: {
                            Image(systemName: "paperplane.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.isReplyEnabled(for: notification))
                    }
                }
                HStack(spacing: 10) {
                    if !notification.text.isEmpty {
                        Button("Copy text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(notification.text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }
                    Button("Dismiss on phone") { model.dismissNotification(notification) }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .disabled(!model.isConnected)
                }
            }
        }
    }

    private var groupedNotifications: [(app: String, items: [LinkNotification])] {
        let groups = Dictionary(grouping: model.notifications) { notification in
            notification.appName.isEmpty ? notification.packageName : notification.appName
        }
        return groups
            .map { (app: $0.key, items: $0.value.sorted { $0.postTime > $1.postTime }) }
            .sorted { $0.items.first?.postTime ?? .distantPast > $1.items.first?.postTime ?? .distantPast }
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch model.phase {
        case .idle:
            statusLabel(color: .gray, text: "Disconnected")
        case .connecting(let display):
            statusLabel(color: .orange, text: "Connecting to \(display)…")
        case .connected(let display):
            statusLabel(color: .green, text: "Connected · \(display)")
        case .reconnecting(let display):
            statusLabel(color: .orange, text: "Reconnecting to \(display)…")
        case .pairing(let display):
            statusLabel(color: .yellow, text: "Device not found — pairing with \(display)…")
        case .failed(let reason):
            statusLabel(color: .red, text: "Failed — \(reason)")
        }
    }

    private var connectedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let battery = model.phoneBattery {
                HStack(spacing: 6) {
                    Image(systemName: battery.symbolName)
                        .foregroundStyle(.secondary)
                    Text("Phone battery: \(battery.summaryText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button("Ping") { model.sendPing() }
                Button("Disconnect") { model.disconnect() }
            }
            HStack(spacing: 10) {
                Button("Send clipboard to phone") { model.sendClipboardToPhone() }
                Toggle("Send on copy", isOn: Binding(
                    get: { model.sendClipboardOnCopy },
                    set: { model.setSendClipboardOnCopy($0) }
                ))
                .font(.caption)
                .toggleStyle(.checkbox)
            }
            Button("Send file to phone…") { model.pickAndSendFile() }
            HStack(spacing: 8) {
                TextField("https://…", text: $model.openURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { model.openURLOnPhone() }
                Button("Open on phone") { model.openURLOnPhone() }
                    .disabled(model.openURLDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.openURLStatus.isEmpty {
                Text(model.openURLStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 10) {
                Button(mirrorButtonLabel) { model.toggleMirroring() }
                if !model.mirrorStatusText.isEmpty {
                    Text(model.mirrorStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.mirrorPhase == .requesting {
                Text("Approve the prompt on your phone to start mirroring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.mirrorPhase == .active {
                mirrorVideoSection
            }
        }
    }

    @ViewBuilder
    private var mirrorVideoSection: some View {
        if model.isMirrorPoppedOut {
            Label("Mirroring in a separate window", systemImage: "rectangle.on.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let size = model.mirrorVideoSize, let videoView = model.mirrorTouchView {
            MirrorVideoView(videoView: videoView)
                .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                }
                .help("Click or drag on the video to control your phone")
        }
        HStack(spacing: 10) {
            Button(model.isMirrorPoppedOut ? "Return to panel" : "Pop out") {
                if model.isMirrorPoppedOut {
                    model.returnMirrorToPanel()
                } else {
                    model.popOutMirror()
                }
            }
            Spacer()
            Button {
                model.captureMirrorScreenshot()
            } label: {
                Image(systemName: "camera")
            }
            .disabled(model.mirrorTouchView == nil)
            .help("Save a screenshot of the mirrored screen")

            Button {
                model.toggleMirrorRecording()
            } label: {
                Image(systemName: model.isMirrorRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(model.isMirrorRecording ? .red : .primary)
            }
            .disabled(model.mirrorTouchView == nil)
            .help(model.isMirrorRecording ? "Stop recording" : "Record the mirrored screen to an MP4")
        }
        if !model.recordingStatusText.isEmpty {
            Text(model.recordingStatusText)
                .font(.caption)
                .foregroundStyle(model.isMirrorRecording ? .red : .secondary)
        }
    }

    private var mirrorButtonLabel: String {
        switch model.mirrorPhase {
        case .idle: "Mirror phone screen"
        case .requesting: "Cancel mirroring request"
        case .active: "Stop mirroring"
        }
    }

    private var pairingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open PocketLink on your phone and scan this code — connecting in the background…")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let image = model.pairingQRImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Pairing QR code")
            } else {
                Text("Could not render QR code — use manual trust below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Trust manually instead") { model.confirmTrust() }
                Button("Cancel") { model.cancelPairing() }
            }
        }
    }

    private var connectControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Nearby devices")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    model.toggleBrowsing()
                } label: {
                    if model.isBrowsing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderless)
                .help(model.isBrowsing ? "Stop scanning" : "Scan for devices")
            }

            if !model.discoveryError.isEmpty {
                Text(model.discoveryError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.devices.isEmpty {
                Text(
                    model.isBrowsing
                        ? "No devices found yet — make sure PocketLink is running on your phone."
                        : "Tap the magnifying glass to scan for devices."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(model.devices) { device in
                Button {
                    model.connect(to: device)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.gen3")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                                .lineLimit(1)
                            if !device.hostText.isEmpty {
                                Text(device.hostText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            TextField("Android IP, e.g. 192.168.1.42", text: $model.host)
                .textFieldStyle(.roundedBorder)
            TextField("Port", text: $model.portText)
                .textFieldStyle(.roundedBorder)
            Button("Connect manually") { model.connect() }
                .disabled(model.host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var trustedPeersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Trusted devices")
                .font(.subheadline.weight(.medium))
            ForEach(model.trustedPeers, id: \.id) { peer in
                HStack(spacing: 8) {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(peer.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text(peer.addedAt, format: .dateTime.month().day().year())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke") { model.revokePeer(peer) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Files")
                .font(.subheadline.weight(.medium))
            ForEach(model.fileTransfers) { transfer in
                HStack(spacing: 8) {
                    fileIcon(transfer)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transfer.metadata.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text(fileStatusText(transfer))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .completed = transfer.state {
                        Button("Save…") { model.saveTransfer(transfer) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            ForEach(model.outgoingTransfers) { transfer in
                HStack(spacing: 8) {
                    outgoingIcon(transfer)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transfer.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text(outgoingStatusText(transfer))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch transfer.state {
                    case .queued, .sending, .awaitingAck:
                        Button("Cancel") { model.cancelOutgoing(transfer) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    case .failed, .mismatch:
                        Button("Retry") { model.retryOutgoing(transfer) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    case .delivered:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var recentTransfersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("Recent transfers")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Clear") { model.clearTransferHistory() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ForEach(model.transferHistory) { entry in
                HStack(spacing: 8) {
                    historyIcon(entry)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.fileName)
                            .font(.caption)
                            .lineLimit(1)
                        Text(historyStatusText(entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func historyIcon(_ entry: TransferHistoryEntry) -> some View {
        switch entry.state {
        case .delivered, .completed:
            Image(systemName: entry.direction == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(.green)
        case .mismatch, .failed:
            Image(systemName: entry.direction == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: entry.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func historyStatusText(_ entry: TransferHistoryEntry) -> String {
        let size = ByteCountFormatter.string(fromByteCount: entry.totalBytes, countStyle: .file)
        let direction = entry.direction == .send ? "Sent" : "Received"
        let outcome: String
        switch entry.state {
        case .delivered:
            outcome = "\(direction) · \(size)"
        case .completed:
            outcome = "\(direction) · \(size)"
        case .mismatch:
            outcome = "\(direction) · checksum mismatch"
        case .cancelled:
            outcome = "\(direction) · cancelled"
        case .failed(let reason):
            outcome = "\(direction) · failed — \(reason)"
        }
        return "\(outcome) · \(entry.date.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder
    private func fileIcon(_ transfer: FileReceiver.Progress) -> some View {
        switch transfer.state {
        case .receiving:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func fileStatusText(_ transfer: FileReceiver.Progress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: transfer.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: transfer.metadata.size, countStyle: .file)
        switch transfer.state {
        case .receiving:
            return "\(received) of \(total)"
        case .completed:
            return "Received · \(total)"
        case .failed(let reason):
            return "Failed — \(reason)"
        }
    }

    @ViewBuilder
    private func outgoingIcon(_ transfer: ConnectionViewModel.OutgoingTransfer) -> some View {
        switch transfer.state {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .sending, .awaitingAck:
            Image(systemName: "arrow.up.circle")
                .foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .mismatch:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func outgoingStatusText(_ transfer: ConnectionViewModel.OutgoingTransfer) -> String {
        let total = ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)
        switch transfer.state {
        case .queued:
            return "Queued · \(total)"
        case .sending:
            let sent = ByteCountFormatter.string(fromByteCount: transfer.sentBytes, countStyle: .file)
            return "\(sent) of \(total)"
        case .awaitingAck:
            return "Sent · verifying…"
        case .delivered:
            return "Delivered · \(total)"
        case .mismatch:
            return "Phone reports SHA-256 mismatch"
        case .failed(let reason):
            return "Failed — \(reason)"
        }
    }

    private func statusLabel(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }
}
