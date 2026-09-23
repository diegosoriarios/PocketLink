package com.diego.pocketlink.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.SystemClock
import android.util.Log

class ClipboardSyncManager(
    private val context: Context,
    private val onLocalClipboardChanged: (String) -> Unit
) {
    private val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    
    // Suppression threshold to avoid infinite sync loops
    private var lastSentOrReceivedText: String? = null
    private var lastSetTimestamp: Long = 0L

    private val clipChangedListener = ClipboardManager.OnPrimaryClipChangedListener {
        // Debounce / suppress self-triggered updates
        if (SystemClock.elapsedRealtime() - lastSetTimestamp < DEBOUNCE_MS) {
            return@OnPrimaryClipChangedListener
        }

        val text = readLocalClipboard() ?: return@OnPrimaryClipChangedListener
        if (text == lastSentOrReceivedText || text.isBlank()) {
            return@OnPrimaryClipChangedListener
        }

        lastSentOrReceivedText = text
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
        if (text == lastSentOrReceivedText) {
            Log.d(TAG, "Suppressed duplicate incoming remote clipboard text")
            return false
        }

        lastSentOrReceivedText = text
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

    companion object {
        private const val TAG = "ClipboardSyncManager"
        private const val DEBOUNCE_MS = 1000L
    }
}
