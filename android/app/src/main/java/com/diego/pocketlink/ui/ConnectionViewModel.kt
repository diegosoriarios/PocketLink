package com.diego.pocketlink.ui

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.diego.pocketlink.battery.BatteryStatus
import com.diego.pocketlink.connection.ConnectionEvent
import com.diego.pocketlink.connection.ConnectionService
import com.diego.pocketlink.connection.ConnectionState
import com.diego.pocketlink.connection.QrPairingPayload
import com.diego.pocketlink.discovery.DiscoveredDevice
import com.diego.pocketlink.files.TransferDirection
import com.diego.pocketlink.files.TransferHistoryEntry
import com.diego.pocketlink.files.TransferHistoryStore
import com.diego.pocketlink.files.TransferProgress
import com.diego.pocketlink.files.TransferState
import com.diego.pocketlink.mirroring.MirroringService
import com.diego.pocketlink.notifications.LinkNotificationListenerService
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ConnectionViewModel(application: Application) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val uiState: StateFlow<ConnectionState> = _uiState.asStateFlow()

    private val _discoveredDevices = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val discoveredDevices: StateFlow<List<DiscoveredDevice>> = _discoveredDevices.asStateFlow()

    private val _batteryStatus = MutableStateFlow<BatteryStatus?>(null)
    val batteryStatus: StateFlow<BatteryStatus?> = _batteryStatus.asStateFlow()
    private val _sendTransferProgress = MutableStateFlow<TransferProgress?>(null)
    val sendTransferProgress: StateFlow<TransferProgress?> = _sendTransferProgress.asStateFlow()

    private val _receiveTransferProgress = MutableStateFlow<TransferProgress?>(null)
    val receiveTransferProgress: StateFlow<TransferProgress?> = _receiveTransferProgress.asStateFlow()

    private val historyStore: TransferHistoryStore = TransferHistoryStore.get(application)
    val transferHistory: StateFlow<List<TransferHistoryEntry>> = historyStore.entries

    private val _isNotificationListenerGranted = MutableStateFlow(false)
    val isNotificationListenerGranted: StateFlow<Boolean> = _isNotificationListenerGranted.asStateFlow()

    private val _clipboardAutoSend = MutableStateFlow(
        ConnectionService.isClipboardAutoSendEnabled(application)
    )
    val clipboardAutoSend: StateFlow<Boolean> = _clipboardAutoSend.asStateFlow()

    private val _logs = MutableStateFlow<List<String>>(emptyList())
    val logs: StateFlow<List<String>> = _logs.asStateFlow()

    private val dateFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    // Declared BEFORE init: viewModelScope uses Dispatchers.Main.immediate, so
    // a Connected state flow emission can run processShareQueue synchronously
    // during construction (crashed with an NPE when these were initialized
    // after the init block).
    private val pendingShareUris = ArrayDeque<Uri>()
    private var isSendingShareQueue = false

    init {
        observeServiceState()
        checkNotificationListenerPermission()
    }

    fun checkNotificationListenerPermission() {
        _isNotificationListenerGranted.value = LinkNotificationListenerService.isPermissionGranted(getApplication())
    }

    fun openNotificationListenerSettings() {
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        getApplication<Application>().startActivity(intent)
    }

    private fun observeServiceState() {
        // ConnectionService exposes stable process-level flows that survive
        // service stop/start cycles, so a single collect per flow is enough.
        viewModelScope.launch {
            ConnectionService.connectionStateFlow.collect { state ->
                _uiState.value = state
                if (state is ConnectionState.Connected) {
                    processShareQueue()
                }
            }
        }

        viewModelScope.launch {
            ConnectionService.eventsFlow.collect { event ->
                addLog(event)
            }
        }

        viewModelScope.launch {
            ConnectionService.discoveredDevicesFlow.collect { devices ->
                _discoveredDevices.value = devices
            }
        }

        viewModelScope.launch {
            ConnectionService.sendTransferProgressFlow.collect { progress ->
                _sendTransferProgress.value = progress
                if (progress?.state?.isTerminal == true) {
                    processShareQueue()
                }
            }
        }

        viewModelScope.launch {
            ConnectionService.receiveTransferProgressFlow.collect { progress ->
                _receiveTransferProgress.value = progress
            }
        }

        viewModelScope.launch {
            while (true) {
                _batteryStatus.value = ConnectionService.getBatteryStatus()
                checkNotificationListenerPermission()
                delay(2000)
            }
        }
    }

    fun startService(port: Int = 52345) {
        ConnectionService.start(getApplication(), port)
    }

    fun stopService() {
        ConnectionService.stop(getApplication())
    }

    fun connectToHost(host: String, portStr: String) {
        val port = portStr.toIntOrNull() ?: 52345
        if (host.isBlank()) {
            addLog(ConnectionEvent(message = "Host IP address cannot be empty"))
            return
        }
        addLog(ConnectionEvent(message = "Initiating manual connection to $host:$port"))
        ConnectionService.connectToHost(host, port)
    }

    fun sendFile(uri: Uri) {
        addLog(ConnectionEvent(message = "Initiating file send for selected URI"))
        ConnectionService.sendFile(uri)
    }

    fun sendSharedFiles(uris: List<Uri>) {
        if (uris.isEmpty()) return
        pendingShareUris.addAll(uris)
        startService()
        addLog(ConnectionEvent(message = "Queued ${uris.size} shared file(s) for transfer"))
        processShareQueue()
    }

    private fun processShareQueue() {
        if (isSendingShareQueue || pendingShareUris.isEmpty()) return
        if (_uiState.value !is ConnectionState.Connected) return
        val currentState = _sendTransferProgress.value?.state
        if (currentState == TransferState.IN_PROGRESS || currentState == TransferState.VERIFYING) return

        val next = pendingShareUris.removeFirst()
        isSendingShareQueue = true
        addLog(ConnectionEvent(message = "Sending shared file (${pendingShareUris.size + 1} queued)"))
        sendFile(next)
        viewModelScope.launch {
            _sendTransferProgress
                .filter { it?.state?.isTerminal == true }
                .first()
            isSendingShareQueue = false
            if (pendingShareUris.isEmpty()) {
                addLog(ConnectionEvent(message = "All shared files processed"))
            }
            processShareQueue()
        }
    }

    fun cancelFileTransfer(direction: TransferDirection) {
        ConnectionService.cancelFileTransfer(direction)
        addLog(ConnectionEvent(message = "File transfer (${direction.name.lowercase()}) cancelled by user"))
    }

    fun dismissFileTransfer(direction: TransferDirection) {
        ConnectionService.dismissFileTransfer(direction)
    }

    fun clearTransferHistory() {
        historyStore.clear()
    }

    fun setClipboardAutoSend(enabled: Boolean) {
        _clipboardAutoSend.value = enabled
        ConnectionService.setClipboardAutoSend(getApplication(), enabled)
        addLog(
            ConnectionEvent(
                message = if (enabled) "Clipboard auto-send enabled" else "Clipboard auto-send disabled"
            )
        )
    }

    fun syncClipboardNow() {
        val success = ConnectionService.syncClipboardNow()
        if (success) {
            addLog(ConnectionEvent(message = "Manually triggered clipboard sync to remote peer"))
        } else {
            addLog(ConnectionEvent(message = "Failed to sync clipboard (Not connected or empty clip)"))
        }
    }

    fun startMirroring() {
        addLog(ConnectionEvent(message = "Requesting screen mirroring consent"))
        ConnectionService.requestMirrorConsent(getApplication())
    }

    fun stopMirroring() {
        addLog(ConnectionEvent(message = "Stopping screen mirroring"))
        MirroringService.stop(getApplication())
    }

    fun sendPing() {
        val success = ConnectionService.sendPing()
        if (!success) {
            addLog(ConnectionEvent(message = "Cannot send PING: Not connected"))
        }
    }

    fun isIgnoringBatteryOptimizations(): Boolean {
        return ConnectionService.isIgnoringBatteryOptimizations(getApplication())
    }

    fun requestIgnoreBatteryOptimizations(activity: android.app.Activity) {
        addLog(ConnectionEvent(message = "Requesting exemption from battery optimizations"))
        ConnectionService.requestIgnoreBatteryOptimizations(activity)
    }

    fun onQrScanned(raw: String) {
        val pairing = QrPairingPayload.parse(raw)
        if (pairing != null) {
            ConnectionService.setPendingPairingToken(pairing)
            addLog(ConnectionEvent(message = "Scanned pairing QR code. Waiting for Mac handshake..."))
        } else {
            addLog(ConnectionEvent(message = "Unrecognized QR payload: $raw"))
        }
    }

    fun clearLogs() {
        _logs.value = emptyList()
    }

    private fun addLog(event: ConnectionEvent) {
        val timestampStr = dateFormat.format(Date(event.timestamp))
        val entry = "[$timestampStr] ${event.message}"
        _logs.value = listOf(entry) + _logs.value.take(99)
    }
}
