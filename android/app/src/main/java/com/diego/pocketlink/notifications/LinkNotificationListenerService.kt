package com.diego.pocketlink.notifications

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.os.bundleOf
import com.diego.pocketlink.connection.ConnectionService

class LinkNotificationListenerService : NotificationListenerService() {

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return

        // 1. Filter ongoing notifications (media playback, background services)
        if (sbn.isOngoing) {
            return
        }

        // 2. Filter self-notifications from this app
        val pkgName = sbn.packageName ?: return
        if (pkgName == packageName) {
            return
        }

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""

        // Ignore empty notifications
        if (title.isBlank() && text.isBlank()) {
            return
        }

        val appName = try {
            val appInfo = packageManager.getApplicationInfo(pkgName, 0)
            packageManager.getApplicationLabel(appInfo).toString()
        } catch (_: Exception) {
            pkgName
        }

        val hasQuickReply = checkQuickReplySupport(notification)

        val forwardedNotification = ForwardedNotification(
            id = "${sbn.key}_${sbn.postTime}",
            packageName = pkgName,
            appName = appName,
            title = title,
            text = text,
            postTime = sbn.postTime,
            hasQuickReply = hasQuickReply
        )

        // Metadata log only - never print notification body/title
        Log.d(TAG, "Forwarding notification from $pkgName ($appName) [Title len: ${title.length}, Text len: ${text.length}]")

        ConnectionService.sendNotification(forwardedNotification)
    }

    private fun checkQuickReplySupport(notification: Notification): Boolean {
        val actions = notification.actions ?: return false
        for (action in actions) {
            val remoteInputs = action.remoteInputs ?: continue
            if (remoteInputs.isNotEmpty()) {
                return true
            }
        }
        return false
    }

    fun handleReply(id: String, text: String) {
        val sbn = activeNotifications?.firstOrNull { "${it.key}_${it.postTime}" == id }
        if (sbn == null) {
            Log.w(TAG, "Quick reply: no matching notification for id $id")
            return
        }

        val action = sbn.notification.actions?.firstOrNull { !it.remoteInputs.isNullOrEmpty() }
        if (action == null || action.actionIntent == null) {
            Log.w(TAG, "Quick reply: no reply action on notification ${sbn.id} (${sbn.packageName})")
            return
        }

        val remoteInputs = action.remoteInputs ?: return
        val intent = Intent().apply {
            clipData = ClipData.newPlainText("reply", "reply")
        }
        RemoteInput.addResultsToIntent(
            remoteInputs,
            intent,
            bundleOf(remoteInputs[0].resultKey to text)
        )

        try {
            action.actionIntent.send(applicationContext, 0, intent)
            Log.d(TAG, "Quick reply delivered to ${sbn.packageName} (notification id ${sbn.id})")
        } catch (e: PendingIntent.CanceledException) {
            Log.w(TAG, "Quick reply failed for ${sbn.packageName} (notification id ${sbn.id}): action canceled")
        } catch (e: Exception) {
            Log.w(TAG, "Quick reply failed for ${sbn.packageName} (notification id ${sbn.id}): ${e.message}")
        }
    }

    companion object {
        private const val TAG = "NotificationListener"

        var instance: LinkNotificationListenerService? = null
            private set

        fun isPermissionGranted(context: Context): Boolean {
            val enabledListeners = Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ) ?: return false

            val myComponentName = ComponentName(context, LinkNotificationListenerService::class.java).flattenToString()
            return enabledListeners.contains(myComponentName)
        }
    }
}
