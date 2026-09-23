package com.diego.pocketlink.connection

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.diego.pocketlink.MainActivity
import com.diego.pocketlink.R
import com.diego.pocketlink.battery.BatteryStatus
import com.diego.pocketlink.battery.BatterySyncManager
import com.diego.pocketlink.clipboard.ClipboardSyncManager
import com.diego.pocketlink.discovery.DiscoveredDevice
import com.diego.pocketlink.discovery.NsdAdvertiser
import com.diego.pocketlink.discovery.NsdBrowser
import com.diego.pocketlink.files.FileTransferEngine
import com.diego.pocketlink.files.TransferProgress
import com.diego.pocketlink.notifications.ForwardedNotification
import com.diego.pocketlink.notifications.LinkNotificationListenerService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

class ConnectionService : Service() {

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var connectionManager: ConnectionManager? = null
    private var nsdAdvertiser: NsdAdvertiser? = null
    private var nsdBrowser: NsdBrowser? = null
    private var clipboardSyncManager: ClipboardSyncManager? = null
    private var batterySyncManager: BatterySyncManager? = null
    private var fileTransferEngine: FileTransferEngine? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val manager = ConnectionManager(serviceScope)
        connectionManager = manager
        _connectionStateFlow = manager.connectionState
        _eventsFlow = manager.events

        val advertiser = NsdAdvertiser(this)
        nsdAdvertiser = advertiser

        val browser = NsdBrowser(this, serviceScope)
        nsdBrowser = browser
        _discoveredDevicesFlow = browser.discoveredDevices

        val fileEngine = FileTransferEngine(this, serviceScope) { typeId, payload ->
            manager.sendRawFrame(typeId, payload)
        }
        fileTransferEngine = fileEngine
        manager.fileTransferEngine = fileEngine
        _transferProgressFlow = fileEngine.transferProgress

        // Initialize ClipboardSyncManager
        val clipboardMgr = ClipboardSyncManager(this) { localText ->
            manager.sendClipboard(localText)
        }
        clipboardSyncManager = clipboardMgr
        clipboardMgr.startListening()

        manager.onRemoteClipboardReceived = { remoteText ->
            clipboardMgr.setRemoteClipboard(remoteText)
        }

        manager.onNotificationReplyReceived = { id, text ->
            LinkNotificationListenerService.instance?.handleReply(id, text)
        }

        // Initialize BatterySyncManager
        val batteryMgr = BatterySyncManager(this) { status ->
            manager.sendBatteryStatus(status)
        }
        batterySyncManager = batteryMgr
        batteryMgr.startListening()

        manager.connectionState.onEach { state ->
            updateNotification(state)
            if (state is ConnectionState.Listening) {
                advertiser.registerService(state.port)
                browser.startDiscovery()
            } else if (state is ConnectionState.Connected) {
                batteryMgr.getBatteryStatus()?.let { status ->
                    manager.sendBatteryStatus(status)
                }
            }
        }.launchIn(serviceScope)

        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                startForegroundServiceWithNotification()
                val port = intent.getIntExtra(EXTRA_PORT, ConnectionManager.DEFAULT_PORT)
                connectionManager?.startServer(port)
            }
            else -> {
                startForegroundServiceWithNotification()
                connectionManager?.startServer(ConnectionManager.DEFAULT_PORT)
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        clipboardSyncManager?.stopListening()
        batterySyncManager?.stopListening()
        nsdAdvertiser?.unregisterService()
        nsdBrowser?.stopDiscovery()
        connectionManager?.stopServer()
        serviceScope.cancel()
        instance = null
        _connectionStateFlow = null
        _eventsFlow = null
        _discoveredDevicesFlow = null
        _transferProgressFlow = null
        super.onDestroy()
    }

    private fun startForegroundServiceWithNotification() {
        val notification = buildNotification(ConnectionState.Disconnected)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val serviceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, notification, serviceType)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(state: ConnectionState) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, buildNotification(state))
    }

    private fun buildNotification(state: ConnectionState): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ConnectionService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = "Link Connection Service"
        val statusText = when (state) {
            is ConnectionState.Disconnected -> "Status: Disconnected"
            is ConnectionState.Listening -> "Listening on port ${state.port} (${state.localIpAddresses.firstOrNull() ?: "all interfaces"})"
            is ConnectionState.Connected -> "Connected to ${state.remoteAddress}"
            is ConnectionState.Error -> "Error: ${state.message}"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(statusText)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .addAction(0, "Stop", stopIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Link Connection Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Foreground service maintaining background connection listener for Link"
            }
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "link_connection_channel"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.diego.pocketlink.action.START_SERVICE"
        const val ACTION_STOP = "com.diego.pocketlink.action.STOP_SERVICE"
        const val EXTRA_PORT = "com.diego.pocketlink.extra.PORT"

        private var _connectionStateFlow: StateFlow<ConnectionState>? = null
        val connectionStateFlow: StateFlow<ConnectionState>? get() = _connectionStateFlow

        private var _eventsFlow: SharedFlow<ConnectionEvent>? = null
        val eventsFlow: SharedFlow<ConnectionEvent>? get() = _eventsFlow

        private var _discoveredDevicesFlow: StateFlow<List<DiscoveredDevice>>? = null
        val discoveredDevicesFlow: StateFlow<List<DiscoveredDevice>>? get() = _discoveredDevicesFlow

        private var _transferProgressFlow: StateFlow<TransferProgress?>? = null
        val transferProgressFlow: StateFlow<TransferProgress?>? get() = _transferProgressFlow

        var instance: ConnectionService? = null
            private set

        fun start(context: Context, port: Int = ConnectionManager.DEFAULT_PORT) {
            val intent = Intent(context, ConnectionService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_PORT, port)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, ConnectionService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun connectToHost(host: String, port: Int) {
            instance?.connectionManager?.connectToHost(host, port)
        }

        fun sendFile(uri: Uri) {
            instance?.fileTransferEngine?.sendFile(uri)
        }

        fun cancelFileTransfer() {
            instance?.fileTransferEngine?.cancelTransfer()
        }

        fun sendNotification(notification: ForwardedNotification): Boolean {
            return instance?.connectionManager?.sendNotification(notification) ?: false
        }

        fun syncClipboardNow(): Boolean {
            val inst = instance ?: return false
            val text = inst.clipboardSyncManager?.readLocalClipboard() ?: return false
            return inst.connectionManager?.sendClipboard(text) ?: false
        }

        fun getBatteryStatus(): BatteryStatus? {
            return instance?.batterySyncManager?.getBatteryStatus()
        }

        fun sendPing(): Boolean {
            return instance?.connectionManager?.sendPing() ?: false
        }
    }
}
