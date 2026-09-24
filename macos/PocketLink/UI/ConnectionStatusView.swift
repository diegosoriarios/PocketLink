import AppKit
import SwiftUI

import LinkDiscovery
import LinkFiles
import LinkNotifications
import LinkPairing

struct ConnectionStatusView: View {
    @State private var model = ConnectionViewModel()

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

            if !model.notifications.isEmpty {
                notificationsSection
            }

            if !model.fileTransfers.isEmpty || !model.outgoingTransfers.isEmpty {
                filesSection
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
            Button("Quit PocketLink") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
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
            ForEach(model.notifications) { notification in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: notification.symbolName)
                        .foregroundStyle(.secondary)
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
                    }
                }
            }
        }
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
            HStack(spacing: 10) {
                Button("Ping") { model.sendPing() }
                Button("Disconnect") { model.disconnect() }
            }
            HStack(spacing: 10) {
                Button("Send clipboard to phone") { model.sendClipboardToPhone() }
            }
            Button("Send file to phone…") { model.pickAndSendFile() }
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
                    case .sending, .awaitingAck:
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
