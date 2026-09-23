package com.diego.pocketlink.ui

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
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.diego.pocketlink.battery.BatteryStatus
import com.diego.pocketlink.connection.ConnectionState
import com.diego.pocketlink.discovery.DiscoveredDevice
import com.diego.pocketlink.files.TransferProgress
import com.diego.pocketlink.files.TransferState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionScreen(
    viewModel: ConnectionViewModel,
    modifier: Modifier = Modifier
) {
    val uiState by viewModel.uiState.collectAsState()
    val discoveredDevices by viewModel.discoveredDevices.collectAsState()
    val batteryStatus by viewModel.batteryStatus.collectAsState()
    val transferProgress by viewModel.fileTransferProgress.collectAsState()
    val isNotificationGranted by viewModel.isNotificationListenerGranted.collectAsState()
    val logs by viewModel.logs.collectAsState()

    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.sendFile(it) }
    }

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
                    progress = transferProgress,
                    onPickFile = { filePickerLauncher.launch("*/*") },
                    onCancel = { viewModel.cancelFileTransfer() }
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
                    onSyncClipboard = { viewModel.syncClipboardNow() }
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
    progress: TransferProgress?,
    onPickFile: () -> Unit,
    onCancel: () -> Unit
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
                text = "Chunked File Transfer (SAF / MediaStore)",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )

            if (progress != null && progress.state != TransferState.IDLE) {
                Text(
                    text = "File: ${progress.fileName}",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold
                )

                if (progress.totalBytes > 0) {
                    LinearProgressIndicator(
                        progress = { progress.fraction },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Text(
                        text = "${(progress.fraction * 100).toInt()}% (${progress.bytesTransferred} / ${progress.totalBytes} bytes)",
                        style = MaterialTheme.typography.bodySmall
                    )
                }

                Text(
                    text = "Status: ${progress.state}" + (progress.errorMessage?.let { " ($it)" } ?: ""),
                    style = MaterialTheme.typography.bodySmall,
                    color = when (progress.state) {
                        TransferState.COMPLETED -> Color(0xFF4CAF50)
                        TransferState.FAILED -> MaterialTheme.colorScheme.error
                        else -> MaterialTheme.colorScheme.primary
                    }
                )

                if (progress.state == TransferState.IN_PROGRESS) {
                    OutlinedButton(
                        onClick = onCancel,
                        modifier = Modifier.align(Alignment.End)
                    ) {
                        Text("Cancel Transfer")
                    }
                }
            } else {
                Text(
                    text = "Select any file to transfer in chunks with SHA-256 integrity verification.",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray
                )
            }

            Button(
                onClick = onPickFile,
                enabled = isConnected && (progress?.state != TransferState.IN_PROGRESS),
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Send File to Mac")
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
    onSyncClipboard: () -> Unit
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

            Text(
                text = "Clipboard sync works bidirectionally. Android 10+ background read restrictions apply when app is in background.",
                style = MaterialTheme.typography.bodySmall,
                color = Color.Gray
            )

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
