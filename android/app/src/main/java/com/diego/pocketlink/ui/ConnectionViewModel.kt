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
import com.diego.pocketlink.discovery.DiscoveredDevice
import com.diego.pocketlink.files.TransferProgress
import com.diego.pocketlink.notifications.LinkNotificationListenerService
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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

    private val _fileTransferProgress = MutableStateFlow<TransferProgress?>(null)
    val fileTransferProgress: StateFlow<TransferProgress?> = _fileTransferProgress.asStateFlow()

    private val _isNotificationListenerGranted = MutableStateFlow(false)
    val isNotificationListenerGranted: StateFlow<Boolean> = _isNotificationListenerGranted.asStateFlow()

    private val _logs = MutableStateFlow<List<String>>(emptyList())
    val logs: StateFlow<List<String>> = _logs.asStateFlow()

    private val dateFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

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
        viewModelScope.launch {
            while (true) {
                ConnectionService.connectionStateFlow?.collect { state ->
                    _uiState.value = state
                }
                delay(500)
            }
        }

        viewModelScope.launch {
            while (true) {
                ConnectionService.eventsFlow?.collect { event ->
                    addLog(event)
                }
                delay(500)
            }
        }

        viewModelScope.launch {
            while (true) {
                ConnectionService.discoveredDevicesFlow?.collect { devices ->
                    _discoveredDevices.value = devices
                }
                delay(500)
            }
        }

        viewModelScope.launch {
            while (true) {
                ConnectionService.transferProgressFlow?.collect { progress ->
                    _fileTransferProgress.value = progress
                }
                delay(200)
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

    fun cancelFileTransfer() {
        ConnectionService.cancelFileTransfer()
        addLog(ConnectionEvent(message = "File transfer cancelled by user"))
    }

    fun syncClipboardNow() {
        val success = ConnectionService.syncClipboardNow()
        if (success) {
            addLog(ConnectionEvent(message = "Manually triggered clipboard sync to remote peer"))
        } else {
            addLog(ConnectionEvent(message = "Failed to sync clipboard (Not connected or empty clip)"))
        }
    }

    fun sendPing() {
        val success = ConnectionService.sendPing()
        if (!success) {
            addLog(ConnectionEvent(message = "Cannot send PING: Not connected"))
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
