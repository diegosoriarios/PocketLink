package com.diego.pocketlink.files

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class TransferHistoryEntry(
    val fileId: String,
    val direction: TransferDirection,
    val fileName: String,
    val totalBytes: Long,
    val state: TransferState,
    val errorMessage: String? = null,
    val timestamp: Long = System.currentTimeMillis()
)

class TransferHistoryStore private constructor(context: Context) {
    private val file = File(context.applicationContext.filesDir, FILE_NAME)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()

    private val _entries = MutableStateFlow<List<TransferHistoryEntry>>(emptyList())
    val entries: StateFlow<List<TransferHistoryEntry>> = _entries.asStateFlow()

    init {
        reload()
    }

    fun record(entry: TransferHistoryEntry) {
        scope.launch {
            synchronized(lock) {
                val updated = (listOf(entry) + _entries.value)
                    .distinctBy { it.fileId }
                    .take(MAX_ENTRIES)
                _entries.value = updated
                persist(updated)
            }
        }
    }

    fun clear() {
        scope.launch {
            synchronized(lock) {
                _entries.value = emptyList()
                file.delete()
            }
        }
    }

    private fun reload() {
        _entries.value = runCatching {
            if (!file.exists()) return
            val array = JSONArray(file.readText())
            (0 until array.length()).mapNotNull { i ->
                val obj = array.getJSONObject(i)
                TransferHistoryEntry(
                    fileId = obj.getString("fileId"),
                    direction = TransferDirection.valueOf(obj.getString("direction")),
                    fileName = obj.getString("fileName"),
                    totalBytes = obj.getLong("totalBytes"),
                    state = TransferState.valueOf(obj.getString("state")),
                    errorMessage = if (obj.has("errorMessage") && !obj.isNull("errorMessage")) {
                        obj.getString("errorMessage")
                    } else {
                        null
                    },
                    timestamp = obj.getLong("timestamp")
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun persist(entries: List<TransferHistoryEntry>) {
        runCatching {
            val array = JSONArray()
            entries.forEach { entry ->
                array.put(
                    JSONObject().apply {
                        put("fileId", entry.fileId)
                        put("direction", entry.direction.name)
                        put("fileName", entry.fileName)
                        put("totalBytes", entry.totalBytes)
                        put("state", entry.state.name)
                        entry.errorMessage?.let { put("errorMessage", it) }
                        put("timestamp", entry.timestamp)
                    }
                )
            }
            file.writeText(array.toString())
        }
    }

    companion object {
        private const val FILE_NAME = "transfer-history.json"
        private const val MAX_ENTRIES = 50

        @Volatile
        private var instance: TransferHistoryStore? = null

        fun get(context: Context): TransferHistoryStore =
            instance ?: synchronized(this) {
                instance ?: TransferHistoryStore(context.applicationContext).also { instance = it }
            }
    }
}
