package com.diego.pocketlink.mirroring

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.diego.pocketlink.MainActivity
import com.diego.pocketlink.R
import com.diego.pocketlink.connection.ConnectionService

/**
 * Foreground service (type mediaProjection) that owns the capture session.
 *
 * Android 14+ requires the FGS to be running with the mediaProjection type
 * before MediaProjection.createVirtualDisplay() is called, so the consent
 * result is passed in via [start] and the service promotes itself to the
 * foreground before creating the encoder.
 */
class MirroringService : Service() {

    private var encoder: ScreenCaptureEncoder? = null
    private var projection: android.media.projection.MediaProjection? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        stopSession()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                runOnUiThread { stopSession() }
                return START_NOT_STICKY
            }
            else -> startCapture(intent)
        }
        return START_NOT_STICKY
    }

    private fun startCapture(intent: Intent?) {
        if (encoder != null) {
            Log.d(TAG, "Capture already running")
            return
        }
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        val resultData = intent?.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)

        startAsForeground()

        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try {
            manager.getMediaProjection(resultCode, resultData ?: Intent())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to obtain MediaProjection: ${e.message}")
            stopSelf()
            return
        }
        if (projection == null) {
            Log.e(TAG, "MediaProjection was null; invalid consent result")
            stopSelf()
            return
        }
        this.projection = projection

        val metrics = resources.displayMetrics
        val width = (metrics.widthPixels / 2) * 2
        val height = (metrics.heightPixels / 2) * 2

        val encoder = ScreenCaptureEncoder(
            projection = projection,
            width = width,
            height = height,
            dpi = metrics.densityDpi,
            onConfig = { config ->
                ConnectionService.sendMirrorConfig(config)
            },
            onFrame = { timestampMs, keyframe, accessUnit ->
                ConnectionService.sendMirrorFrame(timestampMs, keyframe, accessUnit)
            },
            onEnded = {
                runOnUiThread { stopSession() }
            }
        )
        this.encoder = encoder
        encoder.start()

        isRunning = true
        _isRunningFlow.value = true
        displayWidth = width
        displayHeight = height
        Log.d(TAG, "Mirroring started (${width}x${height})")
    }

    private fun startAsForeground() {
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Screen mirroring active")
            .setContentText("Your screen is being shared with the connected Mac.")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun createChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen mirroring",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shown while the screen is shared with the Mac"
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun stopSession() {
        encoder?.stop()
        encoder = null
        projection = null
        isRunning = false
        _isRunningFlow.value = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    fun stopMirroring() {
        runOnUiThread { stopSession() }
    }

    private fun runOnUiThread(block: () -> Unit) {
        android.os.Handler(mainLooper).post(block)
    }

    companion object {
        private const val TAG = "MirroringService"
        private const val CHANNEL_ID = "link_mirroring_channel"
        const val REQUEST_CHANNEL_ID = "link_mirroring_request_channel"
        private const val NOTIFICATION_ID = 1002
        const val ACTION_STOP = "com.diego.pocketlink.action.STOP_MIRRORING"
        const val EXTRA_RESULT_CODE = "com.diego.pocketlink.extra.MIRROR_RESULT_CODE"
        const val EXTRA_RESULT_DATA = "com.diego.pocketlink.extra.MIRROR_RESULT_DATA"

        @Volatile
        var instance: MirroringService? = null
            private set

        private val _isRunningFlow = kotlinx.coroutines.flow.MutableStateFlow(false)

        val isRunningFlow: kotlinx.coroutines.flow.StateFlow<Boolean> = _isRunningFlow

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var displayWidth: Int = 0
            private set

        @Volatile
        var displayHeight: Int = 0
            private set

        fun start(context: Context, resultCode: Int, resultData: Intent) {
            val intent = Intent(context, MirroringService::class.java).apply {
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, resultData)
            }
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, MirroringService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun onCaptureEnded() {
            // Called from encoder/projection callbacks on background threads.
            instance?.stopMirroring()
        }
    }
}
