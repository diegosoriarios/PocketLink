package com.diego.pocketlink.clipboard

import android.content.Context
import android.content.ClipData
import android.content.ClipboardManager
import android.os.SystemClock
import android.util.Log

class ClipboardSyncManager(
    private val context: Context,
    private val onLocalClipboardChanged: (String) -> Unit
) {
    private val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    // Per-direction markers: prevents sync loops (a remote-applied text must not
    // be re-sent by the local listener, and vice versa). The local marker is
    // time-bounded so legitimately re-copying the same text later still syncs.
    private var lastLocalSentText: String? = null
    private var lastLocalSentAt = 0L
    private var lastRemoteAppliedText: String? = null
    private var lastSetTimestamp: Long = 0L

    @Volatile
    var isAutoSendEnabled: Boolean = ClipboardSettings.load(context)

    var duplicateSuppressWindowMs: Long = DUPLICATE_SUPPRESS_WINDOW_MS

    private val clipChangedListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (!isAutoSendEnabled) {
            return@OnPrimaryClipChangedListener
        }
        // Debounce / suppress self-triggered updates right after a remote write
        if (SystemClock.elapsedRealtime() - lastSetTimestamp < DEBOUNCE_MS) {
            return@OnPrimaryClipChangedListener
        }

        val text = readLocalClipboard() ?: return@OnPrimaryClipChangedListener
        if (text.isBlank()) {
            return@OnPrimaryClipChangedListener
        }
        if (text == lastRemoteAppliedText) {
            return@OnPrimaryClipChangedListener
        }
        if (text == lastLocalSentText &&
            SystemClock.elapsedRealtime() - lastLocalSentAt < duplicateSuppressWindowMs
        ) {
            return@OnPrimaryClipChangedListener
        }

        lastLocalSentText = text
        lastLocalSentAt = SystemClock.elapsedRealtime()
        Log.d(TAG, "Local clipboard updated (${text.length} chars)")
        onLocalClipboardChanged(text)
    }

    fun startListening() {
        try {
            clipboardManager.addPrimaryClipChangedListener(clipChangedListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add primary clip changed listener: ${e.message}")
        }
    }

    fun stopListening() {
        try {
            clipboardManager.removePrimaryClipChangedListener(clipChangedListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to remove primary clip changed listener: ${e.message}")
        }
    }

    fun setRemoteClipboard(text: String): Boolean {
        if (text == lastRemoteAppliedText) {
            Log.d(TAG, "Suppressed duplicate incoming remote clipboard text")
            return false
        }

        lastRemoteAppliedText = text
        lastSetTimestamp = SystemClock.elapsedRealtime()

        return try {
            val clip = ClipData.newPlainText("Link Synced Text", text)
            clipboardManager.setPrimaryClip(clip)
            Log.d(TAG, "Successfully updated system clipboard from remote (${text.length} chars)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set system clipboard: ${e.message}")
            false
        }
    }

    fun readLocalClipboard(): String? {
        return try {
            val clip = clipboardManager.primaryClip ?: return null
            if (clip.itemCount > 0) {
                clip.getItemAt(0).text?.toString()
            } else null
        } catch (e: Exception) {
            Log.e(TAG, "Cannot read clipboard (background restriction): ${e.message}")
            null
        }
    }

    fun markLocallySent(text: String) {
        lastLocalSentText = text
    }

    companion object {
        private const val TAG = "ClipboardSyncManager"
        private const val DEBOUNCE_MS = 1000L
        private const val DUPLICATE_SUPPRESS_WINDOW_MS = 30_000L
    }
}
