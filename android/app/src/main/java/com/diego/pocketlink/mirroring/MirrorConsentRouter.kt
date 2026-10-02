package com.diego.pocketlink.mirroring

import android.app.Activity
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.util.Log
import com.diego.pocketlink.MainActivity
import com.diego.pocketlink.connection.ConnectionService

/**
 * Routes mirroring consent requests to the activity when it is in the
 * foreground, or posts a notification that deep-links back into the app
 * when it is not.
 */
object MirrorConsentRouter {

    const val EXTRA_REQUEST_MIRROR_CONSENT = "com.diego.pocketlink.extra.REQUEST_MIRROR_CONSENT"
    private const val TAG = "MirrorConsentRouter"
    private const val REQUEST_NOTIFICATION_ID = 1003

    @Volatile
    private var resumedActivity: MainActivity? = null

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var pendingRequest = false

    fun onActivityResumed(activity: MainActivity) {
        resumedActivity = activity
        appContext = activity.applicationContext
        if (pendingRequest) {
            pendingRequest = false
            activity.launchMirrorConsent()
        }
    }

    fun onActivityPaused() {
        resumedActivity = null
    }

    fun handleDeepLinkIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_REQUEST_MIRROR_CONSENT, false) == true) {
            pendingRequest = false
            resumedActivity?.launchMirrorConsent()
        }
    }

    fun requestConsent(context: Context) {
        if (MirroringService.isRunning) {
            Log.d(TAG, "Mirroring already running; ignoring duplicate request")
            return
        }
        val activity = resumedActivity
        if (activity != null) {
            activity.launchMirrorConsent()
        } else {
            pendingRequest = true
            postRequestNotification(context.applicationContext)
        }
    }

    fun onConsentResult(resultCode: Int, data: Intent?) {
        val context = appContext ?: return
        if (resultCode == Activity.RESULT_OK && data != null) {
            MirroringService.start(context, resultCode, data)
        } else {
            // Tell the Mac the request was declined so its UI clears.
            ConnectionService.sendMirrorStop()
        }
    }

    private fun postRequestNotification(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(MirroringService.REQUEST_CHANNEL_ID) == null
        ) {
            manager.createNotificationChannel(
                android.app.NotificationChannel(
                    MirroringService.REQUEST_CHANNEL_ID,
                    "Screen mirroring requests",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Prompts to approve screen sharing with the Mac"
                }
            )
        }

        val contentIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).apply {
                putExtra(EXTRA_REQUEST_MIRROR_CONSENT, true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = android.app.Notification.Builder(context, MirroringService.REQUEST_CHANNEL_ID)
            .setContentTitle("Screen mirroring request")
            .setContentText("The connected Mac wants to mirror your screen. Tap to review.")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        manager.notify(REQUEST_NOTIFICATION_ID, notification)
    }
}
