package com.diego.pocketlink.ui

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.diego.pocketlink.battery.BatteryStatus
import com.diego.pocketlink.connection.ConnectionState
import com.diego.pocketlink.discovery.DiscoveredDevice
import com.diego.pocketlink.files.TransferDirection
import com.diego.pocketlink.files.TransferHistoryEntry
import com.diego.pocketlink.files.TransferProgress
import com.diego.pocketlink.files.TransferState
import com.diego.pocketlink.qr.QrScannerScreen

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionScreen(
    viewModel: ConnectionViewModel,
    modifier: Modifier = Modifier
) {
    val uiState by viewModel.uiState.collectAsState()
    val discoveredDevices by viewModel.discoveredDevices.collectAsState()
    val batteryStatus by viewModel.batteryStatus.collectAsState()
    val sendTransferProgress by viewModel.sendTransferProgress.collectAsState()
    val receiveTransferProgress by viewModel.receiveTransferProgress.collectAsState()
    val transferHistory by viewModel.transferHistory.collectAsState()
    val clipboardAutoSend by viewModel.clipboardAutoSend.collectAsState()
    val isNotificationGranted by viewModel.isNotificationListenerGranted.collectAsState()
    val logs by viewModel.logs.collectAsState()

    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.sendFile(it) }
    }

    val context = LocalContext.current
    var showQrScanner by remember { mutableStateOf(false) }

    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            showQrScanner = true
        }
    }

    val onScanClick = {
        val hasPermission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
        if (hasPermission) {
            showQrScanner = true
        } else {
            cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    if (showQrScanner) {
        QrScannerScreen(
            onDismiss = { showQrScanner = false },
            onResult = { raw ->
                viewModel.onQrScanned(raw)
                showQrScanner = false
            }
        )
    } else {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Link Companion") }
                )
            },
            modifier = modifier
        ) { innerPadding ->
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                item {
                    ConnectionStatusCard(
                        state = uiState,
                        onStart = { viewModel.startService() },
                        onStop = { viewModel.stopService() },
                        onSendPing = { viewModel.sendPing() }
                    )
                }

                item {
                    FileTransferCard(
                        isConnected = uiState is ConnectionState.Connected,
                        sendProgress = sendTransferProgress,
                        receiveProgress = receiveTransferProgress,
                        onPickFile = { filePickerLauncher.launch("*/*") },
                        onCancel = { viewModel.cancelFileTransfer(it) },
                        onDismiss = { viewModel.dismissFileTransfer(it) }
                    )
                }

                item {
                    RecentTransfersCard(
                        history = transferHistory,
                        onClear = { viewModel.clearTransferHistory() }
                    )
                }

                item {
                    NotificationForwardingCard(
                        isGranted = isNotificationGranted,
                        onOpenSettings = { viewModel.openNotificationListenerSettings() }
                    )
                }

                item {
                    BatteryAndClipboardCard(
                        batteryStatus = batteryStatus,
                        isConnected = uiState is ConnectionState.Connected,
                        isIgnoringBatteryOptimizations = remember(batteryStatus) {
                            viewModel.isIgnoringBatteryOptimizations()
                        },
                        clipboardAutoSend = clipboardAutoSend,
                        onRequestBatteryExemption = {
                            (context as? Activity)?.let { viewModel.requestIgnoreBatteryOptimizations(it) }
                        },
                        onSyncClipboard = { viewModel.syncClipboardNow() },
                        onClipboardAutoSendChange = { viewModel.setClipboardAutoSend(it) }
                    )
                }

                item {
                    MirroringCard(
                        isConnected = uiState is ConnectionState.Connected,
                        onStart = { viewModel.startMirroring() },
                        onStop = { viewModel.stopMirroring() }
                    )
                }

                item {
                    QrPairingCard(
                        onScanClick = onScanClick
                    )
                }

                item {
                    DiscoveredDevicesCard(
                        devices = discoveredDevices,
                        onConnect = { device ->
                            viewModel.connectToHost(device.host, device.port.toString())
                        }
                    )
                }

            item {
                ManualConnectionCard(
                    onConnect = { host, port ->
                        viewModel.connectToHost(host, port)
                    }
                )
            }

            item {
                LogSection(
                    logs = logs,
                    onClearLogs = { viewModel.clearLogs() },
                    modifier = Modifier.height(260.dp)
                )
            }
        }
    }
}
}

@Composable
private fun MirroringCard(
    isConnected: Boolean,
    onStart: () -> Unit,
    onStop: () -> Unit
) {
    val isMirroring by com.diego.pocketlink.mirroring.MirroringService.isRunningFlow.collectAsState()
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "Screen Mirroring",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = if (isMirroring) {
                    "Your screen is being shared with the connected Mac."
                } else {
                    "Share your phone screen with the Mac. You will be asked to confirm before capture starts."
                },
                style = MaterialTheme.typography.bodySmall,
                color = Color.Gray
            )
            if (isMirroring) {
                Button(
                    onClick = onStop,
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB3261E))
                ) {
                    Text("Stop Mirroring")
                }
            } else {
                Button(
                    onClick = onStart,
                    enabled = isConnected
                ) {
                    Text("Start Mirroring")
                }
            }
        }
    }
}

@Composable
private fun QrPairingCard(
    onScanClick: () -> Unit
) {    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "QR Code Pairing",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = "Scan the pairing QR code displayed on your Mac to automatically pair and trust this phone.",
                style = MaterialTheme.typography.bodySmall,
                color = Color.Gray
            )
            Button(
                onClick = onScanClick,
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Scan Pairing Code")
            }
        }
    }
}

@Composable
private fun ConnectionStatusCard(
    state: ConnectionState,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onSendPing: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = "Connection Engine",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
                StatusBadge(state = state)
            }

            when (state) {
                is ConnectionState.Disconnected -> {
                    Text(
                        text = "Service is currently stopped.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                is ConnectionState.Listening -> {
                    Text(
                        text = "Listening & Advertising (mDNS) on network...",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = "Port: ${state.port}",
                        style = MaterialTheme.typography.bodySmall
                    )
                    if (state.localIpAddresses.isNotEmpty()) {
                        Text(
                            text = "IP Addresses: ${state.localIpAddresses.joinToString(", ")}",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace
                        )
                    }
                }
                is ConnectionState.Connected -> {
                    Text(
                        text = "Active TCP Connection",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = "Remote: ${state.remoteAddress}",
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace
                    )
                }
                is ConnectionState.Error -> {
                    Text(
                        text = "Error: ${state.message}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (state is ConnectionState.Disconnected) {
                    Button(
                        onClick = onStart,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Start Service")
                    }
                } else {
                    OutlinedButton(
                        onClick = onStop,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Stop Service")
                    }
                }

                if (state is ConnectionState.Connected) {
                    Button(
                        onClick = onSendPing,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Send PING")
                    }
                }
            }
        }
    }
}

@Composable
private fun FileTransferCard(
    isConnected: Boolean,
    sendProgress: TransferProgress?,
    receiveProgress: TransferProgress?,
    onPickFile: () -> Unit,
    onCancel: (TransferDirection) -> Unit,
    onDismiss: (TransferDirection) -> Unit
) {
    val context = LocalContext.current

    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "File Transfer",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )

            val sendRow = sendProgress?.takeIf { it.state != TransferState.IDLE }
            val receiveRow = receiveProgress?.takeIf { it.state != TransferState.IDLE }

            if (sendRow == null && receiveRow == null) {
                Text(
                    text = "Select any file to transfer in chunks with SHA-256 integrity verification.",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray
                )
            } else {
                sendRow?.let { progress ->
                    TransferRow(
                        progress = progress,
                        context = context,
                        onCancel = { onCancel(TransferDirection.SEND) },
                        onDismiss = { onDismiss(TransferDirection.SEND) }
                    )
                }
                receiveRow?.let { progress ->
                    TransferRow(
                        progress = progress,
                        context = context,
                        onCancel = { onCancel(TransferDirection.RECEIVE) },
                        onDismiss = { onDismiss(TransferDirection.RECEIVE) }
                    )
                }
            }

            Button(
                onClick = onPickFile,
                enabled = isConnected &&
                    sendProgress?.state != TransferState.IN_PROGRESS &&
                    sendProgress?.state != TransferState.VERIFYING,
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Send File to Mac")
            }
        }
    }
}

@Composable
private fun TransferRow(
    progress: TransferProgress,
    context: android.content.Context,
    onCancel: () -> Unit,
    onDismiss: () -> Unit
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = when (progress.direction) {
                    TransferDirection.SEND -> "↑ Sending to Mac"
                    TransferDirection.RECEIVE -> "↓ Receiving from Mac"
                },
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
            if (progress.state.isTerminal) {
                TextButton(onClick = onDismiss) {
                    Text("Dismiss")
                }
            }
        }

        Text(
            text = progress.fileName,
            style = MaterialTheme.typography.bodySmall,
            color = Color.Gray
        )

        if (progress.state == TransferState.IN_PROGRESS) {
            if (progress.totalBytes > 0) {
                LinearProgressIndicator(
                    progress = { progress.fraction },
                    modifier = Modifier.fillMaxWidth()
                )
                Text(
                    text = "${(progress.fraction * 100).toInt()}% · " +
                        "${Formatter.formatFileSize(context, progress.bytesTransferred)} of " +
                        Formatter.formatFileSize(context, progress.totalBytes),
                    style = MaterialTheme.typography.bodySmall
                )
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
        }

        Text(
            text = transferStatusText(progress),
            style = MaterialTheme.typography.bodySmall,
            color = transferStatusColor(progress)
        )

        if (progress.state == TransferState.IN_PROGRESS) {
            OutlinedButton(
                onClick = onCancel,
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Cancel Transfer")
            }
        }
    }
}

private fun transferStatusText(progress: TransferProgress): String {
    return transferStatusText(progress.state, progress.errorMessage)
}

private fun transferStatusText(state: TransferState, errorMessage: String?): String {
    return when (state) {
        TransferState.IN_PROGRESS -> "Transferring…"
        TransferState.VERIFYING -> "Sent · verifying checksum…"
        TransferState.DELIVERED -> "Delivered ✓"
        TransferState.COMPLETED -> "Received · Saved to Downloads/PocketLink"
        TransferState.CANCELLED -> "Transfer cancelled"
        TransferState.MISMATCH -> "Receiver reported checksum mismatch"
        TransferState.FAILED -> errorMessage?.let { "Failed — $it" } ?: "Failed"
        TransferState.IDLE -> ""
    }
}

@Composable
private fun transferStatusColor(progress: TransferProgress): Color {
    return transferStatusColor(progress.state)
}

@Composable
private fun transferStatusColor(state: TransferState): Color {
    return when (state) {
        TransferState.DELIVERED, TransferState.COMPLETED -> Color(0xFF4CAF50)
        TransferState.FAILED, TransferState.MISMATCH -> MaterialTheme.colorScheme.error
        TransferState.CANCELLED -> Color.Gray
        else -> MaterialTheme.colorScheme.primary
    }
}

@Composable
private fun RecentTransfersCard(
    history: List<TransferHistoryEntry>,
    onClear: () -> Unit
) {
    val context = LocalContext.current
    val dateFormat = remember { java.text.SimpleDateFormat("MMM d, HH:mm", java.util.Locale.getDefault()) }

    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Recent transfers",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f)
                )
                TextButton(onClick = onClear) {
                    Text("Clear")
                }
            }

            history.forEach { entry ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        text = when (entry.direction) {
                            TransferDirection.SEND -> "↑"
                            TransferDirection.RECEIVE -> "↓"
                        },
                        style = MaterialTheme.typography.titleMedium,
                        color = transferStatusColor(entry.state)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = entry.fileName,
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1
                        )
                        Text(
                            text = "${transferStatusText(entry.state, entry.errorMessage)} · " +
                                "${Formatter.formatFileSize(context, entry.totalBytes)} · " +
                                dateFormat.format(java.util.Date(entry.timestamp)),
                            style = MaterialTheme.typography.bodySmall,
                            color = transferStatusColor(entry.state)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NotificationForwardingCard(
    isGranted: Boolean,
    onOpenSettings: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Notification Forwarding",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold
                )

                Surface(
                    color = (if (isGranted) Color(0xFF4CAF50) else Color.Gray).copy(alpha = 0.15f),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text(
                        text = if (isGranted) "ENABLED" else "DISABLED",
                        color = if (isGranted) Color(0xFF4CAF50) else Color.Gray,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                }
            }

            Text(
                text = if (isGranted) {
                    "Android notifications will automatically forward to your connected Mac."
                } else {
                    "Notification Access is required to mirror Android notifications to your Mac."
                },
                style = MaterialTheme.typography.bodySmall,
                color = Color.DarkGray
            )

            if (!isGranted) {
                Button(
                    onClick = onOpenSettings,
                    modifier = Modifier.align(Alignment.End)
                ) {
                    Text("Enable Notification Access")
                }
            }
        }
    }
}

@Composable
private fun BatteryAndClipboardCard(
    batteryStatus: BatteryStatus?,
    isConnected: Boolean,
    isIgnoringBatteryOptimizations: Boolean,
    clipboardAutoSend: Boolean,
    onRequestBatteryExemption: () -> Unit,
    onSyncClipboard: () -> Unit,
    onClipboardAutoSendChange: (Boolean) -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "Clipboard & Battery Synchronization",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )

            val batteryText = if (batteryStatus != null) {
                val chargingStr = if (batteryStatus.isCharging) " (Charging)" else ""
                val powerSaveStr = if (batteryStatus.powerSaveMode) " [Power Save]" else ""
                "${batteryStatus.level}%$chargingStr$powerSaveStr"
            } else {
                "Fetching battery state..."
            }

            Text(
                text = "Device Battery: $batteryText",
                style = MaterialTheme.typography.bodyMedium
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Background keep-alive",
                    style = MaterialTheme.typography.bodySmall
                )
                if (isIgnoringBatteryOptimizations) {
                    Text(
                        text = "Enabled",
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF4CAF50)
                    )
                } else {
                    OutlinedButton(onClick = onRequestBatteryExemption) {
                        Text("Whitelist app", fontSize = 12.sp)
                    }
                }
            }

            Text(
                text = "Clipboard sync works bidirectionally. Android 10+ background read restrictions apply when app is in background.",
                style = MaterialTheme.typography.bodySmall,
                color = Color.Gray
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Auto-send clipboard to Mac",
                    style = MaterialTheme.typography.bodySmall
                )
                Switch(
                    checked = clipboardAutoSend,
                    onCheckedChange = onClipboardAutoSendChange
                )
            }

            Button(
                onClick = onSyncClipboard,
                enabled = isConnected,
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Sync Clipboard Now")
            }
        }
    }
}

@Composable
private fun DiscoveredDevicesCard(
    devices: List<DiscoveredDevice>,
    onConnect: (DiscoveredDevice) -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "Discovered Local Devices (mDNS)",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )

            if (devices.isEmpty()) {
                Text(
                    text = "No other Link devices discovered on Wi-Fi yet.",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray
                )
            } else {
                devices.forEach { device ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column {
                            Text(
                                text = device.name,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                text = "${device.host}:${device.port}",
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace
                            )
                        }
                        Button(
                            onClick = { onConnect(device) }
                        ) {
                            Text("Connect", fontSize = 12.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ManualConnectionCard(
    onConnect: (String, String) -> Unit
) {
    var hostText by remember { mutableStateOf("") }
    var portText by remember { mutableStateOf("52345") }

    Card(
        modifier = Modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "Manual Connection Fallback",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = hostText,
                    onValueChange = { hostText = it },
                    label = { Text("IP Address") },
                    placeholder = { Text("192.168.1.100") },
                    singleLine = true,
                    modifier = Modifier.weight(2f)
                )

                OutlinedTextField(
                    value = portText,
                    onValueChange = { portText = it },
                    label = { Text("Port") },
                    singleLine = true,
                    modifier = Modifier.weight(1f)
                )
            }

            Button(
                onClick = { onConnect(hostText, portText) },
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Connect Directly")
            }
        }
    }
}

@Composable
private fun StatusBadge(state: ConnectionState) {
    val (statusText, statusColor) = when (state) {
        is ConnectionState.Disconnected -> "OFFLINE" to Color.Gray
        is ConnectionState.Listening -> "LISTENING" to Color(0xFF2196F3)
        is ConnectionState.Connected -> "CONNECTED" to Color(0xFF4CAF50)
        is ConnectionState.Error -> "ERROR" to Color(0xFFF44336)
    }

    Surface(
        color = statusColor.copy(alpha = 0.15f),
        shape = RoundedCornerShape(16.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(statusColor, shape = CircleShape)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = statusText,
                color = statusColor,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

@Composable
private fun LogSection(
    logs: List<String>,
    onClearLogs: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Event Log",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold
                )
                OutlinedButton(onClick = onClearLogs) {
                    Text("Clear", fontSize = 11.sp)
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            if (logs.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "No events logged yet.",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Gray
                    )
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    items(logs) { log ->
                        Text(
                            text = log,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp
                        )
                    }
                }
            }
        }
    }
}
