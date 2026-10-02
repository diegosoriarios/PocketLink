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
import android.net.wifi.WifiManager
import android.net.wifi.WifiManager.WifiLock
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import com.diego.pocketlink.MainActivity
import com.diego.pocketlink.R
import com.diego.pocketlink.battery.BatteryStatus
import com.diego.pocketlink.clipboard.ClipboardSettings
import com.diego.pocketlink.security.LinkIdentity
import com.diego.pocketlink.battery.BatterySyncManager
import com.diego.pocketlink.clipboard.ClipboardSyncManager
import com.diego.pocketlink.discovery.DiscoveredDevice
import com.diego.pocketlink.discovery.NsdAdvertiser
import com.diego.pocketlink.discovery.NsdBrowser
import com.diego.pocketlink.files.FileTransferEngine
import com.diego.pocketlink.files.TransferDirection
import com.diego.pocketlink.files.TransferHistoryStore
import com.diego.pocketlink.files.TransferProgress
import com.diego.pocketlink.mirroring.MirrorConsentRouter
import com.diego.pocketlink.mirroring.MirroringAccessibilityService
import com.diego.pocketlink.mirroring.MirroringService
import com.diego.pocketlink.notifications.ForwardedNotification
import com.diego.pocketlink.notifications.LinkNotificationListenerService
import com.diego.pocketlink.protocol.MirrorProtocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
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
    private var wifiLock: WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireWifiLock()
        val manager = ConnectionManager(serviceScope, LinkIdentity.load(applicationContext))
        connectionManager = manager

        // Bridge per-instance flows into the stable companion flows so UI
        // collectors survive service stop/start cycles.
        manager.connectionState.onEach { _connectionStateFlow.value = it }.launchIn(serviceScope)
        manager.events.onEach { _eventsFlow.tryEmit(it) }.launchIn(serviceScope)

        val advertiser = NsdAdvertiser(this)
        nsdAdvertiser = advertiser

        val browser = NsdBrowser(this, serviceScope)
        nsdBrowser = browser
        browser.discoveredDevices.onEach { _discoveredDevicesFlow.value = it }.launchIn(serviceScope)

        val fileEngine = FileTransferEngine(this, serviceScope, TransferHistoryStore.get(applicationContext)) { typeId, payload ->
            manager.sendRawFrame(typeId, payload)
        }
        fileTransferEngine = fileEngine
        manager.fileTransferEngine = fileEngine
        fileEngine.sendProgress.onEach { _sendTransferProgressFlow.value = it }.launchIn(serviceScope)
        fileEngine.receiveProgress.onEach { _receiveTransferProgressFlow.value = it }.launchIn(serviceScope)

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
            val success = LinkNotificationListenerService.instance?.handleReply(id, text) ?: false
            instance?.connectionManager?.sendNotificationReplyAck(id, success)
        }

        manager.onNotificationActionReceived = { id, action ->
            when (action) {
                "dismiss" -> LinkNotificationListenerService.instance?.handleDismiss(id)
            }
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
            if (state !is ConnectionState.Connected && MirroringService.isRunning) {
                MirroringService.stop(this)
            }
        }.launchIn(serviceScope)

        manager.onMirrorStartRequested = {
            MirrorConsentRouter.requestConsent(this)
        }
        manager.onMirrorStopRequested = {
            MirroringService.stop(this)
        }
        manager.onRemoteTouchReceived = { action, x, y ->
            MirroringAccessibilityService.dispatchTouch(action, x, y)
        }

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
        releaseWifiLock()
        serviceScope.cancel()
        // The companion flows are intentionally left as-is: they are stable
        // process-level bridges and the UI keeps collecting them across
        // service restarts. Reset the externally visible state so a stopped
        // service does not appear connected.
        _connectionStateFlow.value = ConnectionState.Disconnected
        _discoveredDevicesFlow.value = emptyList()
        instance = null
        super.onDestroy()
    }

    private fun acquireWifiLock() {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val lock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "PocketLink:WifiLock")
        lock.setReferenceCounted(false)
        lock.acquire()
        wifiLock = lock
    }

    private fun releaseWifiLock() {
        wifiLock?.let { lock ->
            if (lock.isHeld) {
                lock.release()
            }
        }
        wifiLock = null
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

        // Stable process-level flow bridges. The service instance (and with it
        // every ConnectionManager/NsdBrowser/FileTransferEngine) is destroyed and
        // recreated on stop/start, so observers must never hold a reference to a
        // per-instance flow — those would go dead the moment the service stops.
        // Instead each service instance writes into these shared flows, which
        // survive restarts and keep UI collectors attached.
        private val _connectionStateFlow = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
        val connectionStateFlow: StateFlow<ConnectionState> = _connectionStateFlow

        private val _eventsFlow = MutableSharedFlow<ConnectionEvent>(extraBufferCapacity = 64)
        val eventsFlow: SharedFlow<ConnectionEvent> = _eventsFlow

        private val _discoveredDevicesFlow = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
        val discoveredDevicesFlow: StateFlow<List<DiscoveredDevice>> = _discoveredDevicesFlow

        private val _sendTransferProgressFlow = MutableStateFlow<TransferProgress?>(null)
        val sendTransferProgressFlow: StateFlow<TransferProgress?> = _sendTransferProgressFlow

        private val _receiveTransferProgressFlow = MutableStateFlow<TransferProgress?>(null)
        val receiveTransferProgressFlow: StateFlow<TransferProgress?> = _receiveTransferProgressFlow

        @Volatile
        var pendingPairingToken: PendingPairingToken? = null
            private set

        fun setPendingPairingToken(pairing: QrPairing) {
            pendingPairingToken = PendingPairingToken(
                value = pairing.token,
                identityFingerprint = pairing.identityFingerprint
            )
        }

        fun clearPendingPairingToken() {
            pendingPairingToken = null
        }

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

        fun cancelFileTransfer(direction: TransferDirection) {
            instance?.fileTransferEngine?.let { engine ->
                when (direction) {
                    TransferDirection.SEND -> engine.cancelSendTransfer()
                    TransferDirection.RECEIVE -> engine.cancelReceiveTransfer()
                }
            }
        }

        fun dismissFileTransfer(direction: TransferDirection) {
            instance?.fileTransferEngine?.dismissResult(direction)
        }

        fun isIgnoringBatteryOptimizations(context: Context): Boolean {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            return powerManager.isIgnoringBatteryOptimizations(context.packageName)
        }

        fun requestIgnoreBatteryOptimizations(activity: android.app.Activity) {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:${activity.packageName}"))
            activity.startActivity(intent)
        }

        fun sendNotification(notification: ForwardedNotification): Boolean {
            return instance?.connectionManager?.sendNotification(notification) ?: false
        }

        fun sendMirrorConfig(config: MirrorProtocol.MirrorConfig): Boolean {
            return instance?.connectionManager?.sendMirrorConfig(config) ?: false
        }

        fun sendMirrorFrame(timestampMs: Long, keyframe: Boolean, accessUnit: ByteArray): Boolean {
            return instance?.connectionManager?.sendMirrorFrame(timestampMs, keyframe, accessUnit) ?: false
        }

        fun sendMirrorStop(): Boolean {
            return instance?.connectionManager?.sendMirrorStop() ?: false
        }

        fun requestMirrorConsent(context: Context) {
            MirrorConsentRouter.requestConsent(context.applicationContext)
        }

        fun syncClipboardNow(): Boolean {
            val inst = instance ?: return false
            val text = inst.clipboardSyncManager?.readLocalClipboard() ?: return false
            return inst.connectionManager?.sendClipboard(text) ?: false
        }

        fun isClipboardAutoSendEnabled(context: Context): Boolean =
            ClipboardSettings.load(context.applicationContext)

        fun setClipboardAutoSend(context: Context, enabled: Boolean) {
            ClipboardSettings.save(context.applicationContext, enabled)
            instance?.clipboardSyncManager?.isAutoSendEnabled = enabled
        }

        fun getBatteryStatus(): BatteryStatus? {
            return instance?.batterySyncManager?.getBatteryStatus()
        }

        fun sendPing(): Boolean {
            return instance?.connectionManager?.sendPing() ?: false
        }
    }
}
