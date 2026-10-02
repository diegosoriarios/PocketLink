package com.diego.pocketlink.files

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

class FileTransferEngine(
    private val context: Context,
    private val scope: CoroutineScope,
    private val historyStore: TransferHistoryStore? = null,
    private val onSendFrame: (typeId: Int, payload: ByteArray) -> Boolean
) {
    private val _sendProgress = MutableStateFlow<TransferProgress?>(null)
    val sendProgress: StateFlow<TransferProgress?> = _sendProgress.asStateFlow()

    private val _receiveProgress = MutableStateFlow<TransferProgress?>(null)
    val receiveProgress: StateFlow<TransferProgress?> = _receiveProgress.asStateFlow()

    private var activeJob: Job? = null
    private var sendClearJob: Job? = null
    private var receiveClearJob: Job? = null
    private var sendAckTimeoutJob: Job? = null
    @Volatile
    private var isCancelled: Boolean = false

    // State for incoming file
    private var incomingMetadata: FileMetadata? = null
    private var incomingOutputStream: OutputStream? = null
    private var incomingDigest: MessageDigest? = null
    private var incomingBytesReceived: Long = 0L
    private var incomingUri: Uri? = null
    private var incomingFile: File? = null

    private fun flowFor(direction: TransferDirection): MutableStateFlow<TransferProgress?> = when (direction) {
        TransferDirection.SEND -> _sendProgress
        TransferDirection.RECEIVE -> _receiveProgress
    }

    private fun emit(progress: TransferProgress) {
        val flow = flowFor(progress.direction)
        if (progress.state.isTerminal) {
            recordHistory(progress)
        }
        setClearJob(progress.direction, null)
        flow.value = progress
        setClearJob(progress.direction, scheduleAutoClear(progress.direction))
    }

    private fun recordHistory(progress: TransferProgress) {
        historyStore?.record(
            TransferHistoryEntry(
                fileId = progress.fileId,
                direction = progress.direction,
                fileName = progress.fileName,
                totalBytes = progress.totalBytes,
                state = progress.state,
                errorMessage = progress.errorMessage
            )
        )
    }

    private fun update(direction: TransferDirection, transform: (TransferProgress) -> TransferProgress) {
        flowFor(direction).value?.let { emit(transform(it)) }
    }

    private fun setClearJob(direction: TransferDirection, job: Job?) {
        when (direction) {
            TransferDirection.SEND -> sendClearJob = job
            TransferDirection.RECEIVE -> receiveClearJob = job
        }
    }

    private fun scheduleAutoClear(direction: TransferDirection): Job? {
        if (flowFor(direction).value?.state?.isTerminal != true) return null
        return scope.launch {
            delay(AUTO_CLEAR_DELAY_MS)
            val flow = flowFor(direction)
            if (flow.value?.state?.isTerminal == true) {
                flow.value = null
            }
        }
    }

    fun dismissResult(direction: TransferDirection) {
        val flow = flowFor(direction)
        val progress = flow.value ?: return
        if (!progress.state.isTerminal) return
        setClearJob(direction, null)
        flow.value = null
    }

    fun handleFileAck(fileId: String, status: String) {
        val target = TransferState.ackStateFor(status) ?: return
        val progress = _sendProgress.value ?: return
        if (progress.direction != TransferDirection.SEND || progress.fileId != fileId) return
        if (progress.state != TransferState.VERIFYING) return
        sendAckTimeoutJob?.cancel()
        sendAckTimeoutJob = null
        emit(
            progress.copy(
                state = target,
                errorMessage = if (target == TransferState.MISMATCH) "Receiver reported SHA-256 mismatch" else null
            )
        )
        Log.d(TAG, "Send ACK processed for $fileId -> $target")
    }

    fun sendFile(uri: Uri) {
        val sendState = _sendProgress.value?.state
        if (sendState == TransferState.IN_PROGRESS || sendState == TransferState.VERIFYING) {
            Log.w(TAG, "File send already in progress")
            return
        }

        isCancelled = false
        sendAckTimeoutJob?.cancel()
        sendAckTimeoutJob = null
        activeJob = scope.launch(Dispatchers.IO) {
            try {
                val contentResolver = context.contentResolver
                val fileName = getFileNameFromUri(uri) ?: "transfer_${System.currentTimeMillis()}"
                val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"

                emit(
                    TransferProgress(
                        fileId = "",
                        fileName = fileName,
                        bytesTransferred = 0L,
                        totalBytes = 0L,
                        state = TransferState.IN_PROGRESS,
                        direction = TransferDirection.SEND
                    )
                )

                // 1. Calculate file size and SHA-256 (count bytes while hashing; available() is unreliable)
                Log.d(TAG, "Calculating file SHA-256 checksum...")
                val hashBuffer = ByteArray(SIZE_READ_BUFFER_SIZE)
                var countedSize = 0L
                val sha256 = contentResolver.openInputStream(uri)?.use { stream ->
                    val digest = MessageDigest.getInstance("SHA-256")
                    var read: Int
                    while (stream.read(hashBuffer).also { read = it } != -1) {
                        digest.update(hashBuffer, 0, read)
                        countedSize += read
                    }
                    digest.digest().joinToString("") { "%02x".format(it) }
                } ?: ""
                val fileSize = queryFileSize(uri) ?: countedSize

                val fileId = UUID.randomUUID().toString().take(8)
                val metadata = FileMetadata(
                    fileId = fileId,
                    name = fileName,
                    size = fileSize,
                    sha256 = sha256,
                    mimeType = mimeType
                )

                emit(
                    TransferProgress(
                        fileId = fileId,
                        fileName = fileName,
                        bytesTransferred = 0L,
                        totalBytes = fileSize,
                        state = TransferState.IN_PROGRESS,
                        direction = TransferDirection.SEND
                    )
                )

                // 2. Send FILE_HEADER (0x0040)
                val headerJson = org.json.JSONObject().apply {
                    put("fileId", fileId)
                    put("name", fileName)
                    put("size", fileSize)
                    put("sha256", sha256)
                    put("mimeType", mimeType)
                }.toString().toByteArray(Charsets.UTF_8)

                if (!onSendFrame(0x0040, headerJson)) {
                    throw Exception("Failed to send FILE_HEADER frame")
                }

                // 3. Send FILE_CHUNK (0x0041) frames
                val fileIdHash = fileId.hashCode()
                val inputStream: InputStream = contentResolver.openInputStream(uri) ?: throw Exception("Cannot open URI stream")

                var bytesSent = 0L
                val chunkBuffer = ByteArray(ChecksumUtils.DEFAULT_CHUNK_SIZE)
                var bytesRead: Int

                inputStream.use { stream ->
                    while (stream.read(chunkBuffer).also { bytesRead = it } != -1) {
                        if (isCancelled) {
                            sendAck(fileId, bytesSent, "CANCELLED")
                            update(TransferDirection.SEND) { it.copy(state = TransferState.CANCELLED) }
                            Log.d(TAG, "File upload cancelled by user")
                            return@launch
                        }

                        val chunkHeader = ChecksumUtils.createChunkHeader(fileIdHash, bytesSent)
                        val chunkPayload = chunkHeader + chunkBuffer.copyOf(bytesRead)

                        if (!onSendFrame(0x0041, chunkPayload)) {
                            throw Exception("Socket error sending chunk at offset $bytesSent")
                        }

                        bytesSent += bytesRead
                        update(TransferDirection.SEND) { it.copy(bytesTransferred = bytesSent) }
                    }
                }

                if (isCancelled) {
                    update(TransferDirection.SEND) { it.copy(state = TransferState.CANCELLED) }
                    return@launch
                }

                // 4. Chunks delivered; the receiver still has to verify SHA-256 and ACK
                update(TransferDirection.SEND) { it.copy(state = TransferState.VERIFYING, bytesTransferred = bytesSent) }
                scheduleAckTimeout(fileId)
                Log.d(TAG, "File sent ($bytesSent bytes); awaiting receiver ACK")
            } catch (e: Exception) {
                Log.e(TAG, "File transfer failed: ${e.message}")
                update(TransferDirection.SEND) {
                    it.copy(
                        state = TransferState.FAILED,
                        errorMessage = e.message
                    )
                }
            }
        }
    }

    private fun scheduleAckTimeout(fileId: String) {
        sendAckTimeoutJob?.cancel()
        sendAckTimeoutJob = scope.launch {
            delay(ACK_TIMEOUT_MS)
            val current = _sendProgress.value
            if (current?.state == TransferState.VERIFYING && current.fileId == fileId) {
                Log.w(TAG, "No FILE_ACK received for $fileId; marking send as failed")
                emit(
                    current.copy(
                        state = TransferState.FAILED,
                        errorMessage = "No confirmation from receiver"
                    )
                )
            }
        }
    }

    suspend fun handleIncomingHeader(headerJsonStr: String) = withContext(Dispatchers.IO) {
        try {
            val json = org.json.JSONObject(headerJsonStr)
            val metadata = FileMetadata(
                fileId = json.getString("fileId"),
                name = json.getString("name"),
                size = json.getLong("size"),
                sha256 = json.getString("sha256"),
                mimeType = json.getString("mimeType")
            )

            // A new header while a transfer is still active: discard the stale partial
            if (incomingOutputStream != null) {
                Log.w(TAG, "New FILE_HEADER while transfer active; discarding partial ${incomingMetadata?.fileId ?: "unknown"}")
                discardIncomingPartial()
            }

            incomingMetadata = metadata
            incomingBytesReceived = 0L
            incomingDigest = MessageDigest.getInstance("SHA-256")

            // Create target file in MediaStore Downloads
            val outputStream = createMediaStoreOutputStream(metadata.name, metadata.mimeType)
            incomingOutputStream = outputStream

            if (metadata.size == 0L) {
                // Zero-size transfers never receive chunks; complete immediately
                outputStream.flush()
                outputStream.close()
                incomingOutputStream = null
                incomingUri = null
                incomingFile = null

                val calculatedSha = incomingDigest?.digest()?.joinToString("") { "%02x".format(it) } ?: ""
                if (calculatedSha.equals(metadata.sha256, ignoreCase = true)) {
                    Log.d(TAG, "Zero-size file completed and SHA-256 verified successfully!")
                    sendAck(metadata.fileId, 0L, "SUCCESS")
                    emit(
                        TransferProgress(
                            fileId = metadata.fileId,
                            fileName = metadata.name,
                            bytesTransferred = 0L,
                            totalBytes = 0L,
                            state = TransferState.COMPLETED,
                            direction = TransferDirection.RECEIVE
                        )
                    )
                } else {
                    Log.e(TAG, "SHA-256 mismatch! Expected ${metadata.sha256}, calculated $calculatedSha")
                    sendAck(metadata.fileId, 0L, "SHA_MISMATCH")
                    emit(
                        TransferProgress(
                            fileId = metadata.fileId,
                            fileName = metadata.name,
                            bytesTransferred = 0L,
                            totalBytes = 0L,
                            state = TransferState.FAILED,
                            direction = TransferDirection.RECEIVE,
                            errorMessage = "SHA-256 Checksum Verification Failed"
                        )
                    )
                }
                return@withContext
            }

            emit(
                TransferProgress(
                    fileId = metadata.fileId,
                    fileName = metadata.name,
                    bytesTransferred = 0L,
                    totalBytes = metadata.size,
                    state = TransferState.IN_PROGRESS,
                    direction = TransferDirection.RECEIVE
                )
            )
            Log.d(TAG, "Receiving incoming file: ${metadata.name} (${metadata.size} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize incoming file: ${e.message}")
        }
    }

    suspend fun handleIncomingChunk(chunkBytes: ByteArray) = withContext(Dispatchers.IO) {
        val metadata = incomingMetadata ?: return@withContext
        val outputStream = incomingOutputStream ?: return@withContext

        try {
            val (fileIdHash, offset) = ChecksumUtils.parseChunkHeader(chunkBytes)
            val chunkData = chunkBytes.copyOfRange(ChecksumUtils.CHUNK_HEADER_SIZE, chunkBytes.size)

            outputStream.write(chunkData)
            incomingDigest?.update(chunkData)
            incomingBytesReceived += chunkData.size

            update(TransferDirection.RECEIVE) { it.copy(bytesTransferred = incomingBytesReceived) }

            // On completion, verify SHA-256
            if (incomingBytesReceived >= metadata.size) {
                outputStream.flush()
                outputStream.close()
                incomingOutputStream = null
                incomingUri = null
                incomingFile = null

                val calculatedSha = incomingDigest?.digest()?.joinToString("") { "%02x".format(it) } ?: ""
                if (calculatedSha.equals(metadata.sha256, ignoreCase = true)) {
                    Log.d(TAG, "File download completed and SHA-256 verified successfully!")
                    sendAck(metadata.fileId, incomingBytesReceived, "SUCCESS")
                    update(TransferDirection.RECEIVE) { it.copy(state = TransferState.COMPLETED) }
                } else {
                    Log.e(TAG, "SHA-256 mismatch! Expected ${metadata.sha256}, calculated $calculatedSha")
                    sendAck(metadata.fileId, incomingBytesReceived, "SHA_MISMATCH")
                    update(TransferDirection.RECEIVE) {
                        it.copy(
                            state = TransferState.FAILED,
                            errorMessage = "SHA-256 Checksum Verification Failed"
                        )
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error writing incoming chunk: ${e.message}")
            update(TransferDirection.RECEIVE) {
                it.copy(
                    state = TransferState.FAILED,
                    errorMessage = e.message
                )
            }
        }
    }

    suspend fun handleIncomingCancel(json: String) = withContext(Dispatchers.IO) {
        val fileId = try {
            org.json.JSONObject(json).optString("fileId")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse FILE_CANCEL payload: ${e.message}")
            return@withContext
        }
        if (fileId.isEmpty()) {
            Log.w(TAG, "FILE_CANCEL payload missing fileId")
            return@withContext
        }

        val metadata = incomingMetadata
        if (metadata == null || metadata.fileId != fileId) {
            Log.d(TAG, "Ignoring FILE_CANCEL for unknown or mismatched fileId $fileId")
            return@withContext
        }
        if (incomingOutputStream == null) {
            Log.d(TAG, "Ignoring FILE_CANCEL for already finished transfer $fileId")
            return@withContext
        }

        val bytesReceived = incomingBytesReceived
        discardIncomingPartial()
        emit(
            TransferProgress(
                fileId = metadata.fileId,
                fileName = metadata.name,
                bytesTransferred = bytesReceived,
                totalBytes = metadata.size,
                state = TransferState.CANCELLED,
                direction = TransferDirection.RECEIVE
            )
        )
        Log.d(TAG, "Incoming transfer cancelled by sender (fileId=$fileId, received $bytesReceived bytes)")
    }

    fun cancelSendTransfer() {
        val progress = _sendProgress.value ?: return
        if (progress.state != TransferState.IN_PROGRESS) return
        isCancelled = true
        activeJob?.cancel()
        emit(progress.copy(state = TransferState.CANCELLED))
        Log.d(TAG, "Outgoing transfer cancelled by user")
    }

    fun cancelReceiveTransfer() {
        val progress = _receiveProgress.value ?: return
        if (progress.state != TransferState.IN_PROGRESS) return
        val metadata = incomingMetadata
        val bytesReceived = incomingBytesReceived
        discardIncomingPartial()
        emit(
            TransferProgress(
                fileId = metadata?.fileId ?: progress.fileId,
                fileName = metadata?.name ?: progress.fileName,
                bytesTransferred = bytesReceived,
                totalBytes = metadata?.size ?: progress.totalBytes,
                state = TransferState.CANCELLED,
                direction = TransferDirection.RECEIVE
            )
        )
        Log.d(TAG, "Incoming transfer cancelled by user (fileId=${metadata?.fileId ?: "unknown"})")
    }

    private fun discardIncomingPartial() {
        try {
            incomingOutputStream?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close partial stream: ${e.message}")
        }
        incomingOutputStream = null

        val uri = incomingUri
        if (uri != null) {
            val deleted = try {
                context.contentResolver.delete(uri, null, null)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to delete partial MediaStore entry: ${e.message}")
                0
            }
            if (deleted == 0) {
                Log.w(TAG, "Partial MediaStore entry was not deleted")
            }
        }
        incomingUri = null

        val file = incomingFile
        if (file != null && file.exists() && !file.delete()) {
            Log.w(TAG, "Failed to delete partial file ${file.name}")
        }
        incomingFile = null

        incomingMetadata = null
        incomingDigest = null
        incomingBytesReceived = 0L
    }

    private fun sendAck(fileId: String, receivedBytes: Long, status: String) {
        val ackJson = org.json.JSONObject().apply {
            put("fileId", fileId)
            put("receivedBytes", receivedBytes)
            put("status", status)
        }.toString().toByteArray(Charsets.UTF_8)
        onSendFrame(0x0042, ackJson)
    }

    private fun queryFileSize(uri: Uri): Long? {
        return try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex != -1 && cursor.moveToFirst() && !cursor.isNull(sizeIndex)) {
                    val size = cursor.getLong(sizeIndex)
                    if (size >= 0) size else null
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to query file size: ${e.message}")
            null
        }
    }

    private fun createMediaStoreOutputStream(fileName: String, mimeType: String): OutputStream {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/PocketLink")
            }
            val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw Exception("Failed to create MediaStore entry")
            incomingUri = uri
            context.contentResolver.openOutputStream(uri) ?: throw Exception("Failed to open MediaStore output stream")
        } else {
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val targetDir = File(downloadsDir, "PocketLink").apply { mkdirs() }
            val targetFile = File(targetDir, fileName)
            incomingFile = targetFile
            FileOutputStream(targetFile)
        }
    }

    private fun getFileNameFromUri(uri: Uri): String? {
        var name: String? = null
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                    if (nameIndex != -1) {
                        name = cursor.getString(nameIndex)
                    }
                }
            }
        } catch (_: Exception) {}
        return name ?: uri.lastPathSegment
    }

    companion object {
        private const val TAG = "FileTransferEngine"
        private const val AUTO_CLEAR_DELAY_MS = 6_000L
        private const val ACK_TIMEOUT_MS = 30_000L
        private const val SIZE_READ_BUFFER_SIZE = 64 * 1024
    }
}
