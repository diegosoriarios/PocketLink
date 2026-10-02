package com.diego.pocketlink.clipboard

import android.content.Context
import org.json.JSONObject
import java.io.File

object ClipboardSettings {
    private const val FILE_NAME = "clipboard-settings.json"
    private const val KEY_AUTO_SEND = "autoSend"

    fun load(context: Context): Boolean {
        return runCatching {
            val file = File(context.applicationContext.filesDir, FILE_NAME)
            if (!file.exists()) return true
            JSONObject(file.readText()).optBoolean(KEY_AUTO_SEND, true)
        }.getOrDefault(true)
    }

    fun save(context: Context, autoSend: Boolean) {
        runCatching {
            val file = File(context.applicationContext.filesDir, FILE_NAME)
            file.writeText(JSONObject().put(KEY_AUTO_SEND, autoSend).toString())
        }
    }
}
