package com.diego.pocketlink.files

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
    private val onSendFrame: (typeId: Int, payload: ByteArray) -> Boolean
) {
    private val _transferProgress = MutableStateFlow<TransferProgress?>(null)
    val transferProgress: StateFlow<TransferProgress?> = _transferProgress.asStateFlow()

    private var activeJob: Job? = null
    @Volatile
    private var isCancelled: Boolean = false

    // State for incoming file
    private var incomingMetadata: FileMetadata? = null
    private var incomingOutputStream: OutputStream? = null
    private var incomingDigest: MessageDigest? = null
    private var incomingBytesReceived: Long = 0L
    private var incomingUri: Uri? = null
    private var incomingFile: File? = null

    fun sendFile(uri: Uri) {
        if (_transferProgress.value?.state == TransferState.IN_PROGRESS) {
            Log.w(TAG, "File transfer already in progress")
            return
        }

        isCancelled = false
        activeJob = scope.launch(Dispatchers.IO) {
            try {
                val contentResolver = context.contentResolver
                val fileName = getFileNameFromUri(uri) ?: "transfer_${System.currentTimeMillis()}"
                val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"

                _transferProgress.value = TransferProgress(
                    fileId = "",
                    fileName = fileName,
                    bytesTransferred = 0L,
                    totalBytes = 0L,
                    state = TransferState.IN_PROGRESS
                )

                // 1. Calculate file size and SHA-256
                Log.d(TAG, "Calculating file SHA-256 checksum...")
                val fileSize = contentResolver.openInputStream(uri)?.use { it.available().toLong() } ?: 0L
                val sha256 = contentResolver.openInputStream(uri)?.use { ChecksumUtils.calculateSha256(it) } ?: ""

                val fileId = UUID.randomUUID().toString().take(8)
                val metadata = FileMetadata(
                    fileId = fileId,
                    name = fileName,
                    size = fileSize,
                    sha256 = sha256,
                    mimeType = mimeType
                )

                _transferProgress.value = TransferProgress(
                    fileId = fileId,
                    fileName = fileName,
                    bytesTransferred = 0L,
                    totalBytes = fileSize,
                    state = TransferState.IN_PROGRESS
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
                            _transferProgress.value = _transferProgress.value?.copy(state = TransferState.CANCELLED)
                            Log.d(TAG, "File upload cancelled by user")
                            return@launch
                        }

                        val chunkHeader = ChecksumUtils.createChunkHeader(fileIdHash, bytesSent)
                        val chunkPayload = chunkHeader + chunkBuffer.copyOf(bytesRead)

                        if (!onSendFrame(0x0041, chunkPayload)) {
                            throw Exception("Socket error sending chunk at offset $bytesSent")
                        }

                        bytesSent += bytesRead
                        _transferProgress.value = _transferProgress.value?.copy(bytesTransferred = bytesSent)
                    }
                }

                _transferProgress.value = _transferProgress.value?.copy(state = TransferState.COMPLETED)
                Log.d(TAG, "File sent successfully ($bytesSent bytes)")
            } catch (e: Exception) {
                Log.e(TAG, "File transfer failed: ${e.message}")
                _transferProgress.value = _transferProgress.value?.copy(
                    state = TransferState.FAILED,
                    errorMessage = e.message
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
                    _transferProgress.value = TransferProgress(
                        fileId = metadata.fileId,
                        fileName = metadata.name,
                        bytesTransferred = 0L,
                        totalBytes = 0L,
                        state = TransferState.COMPLETED
                    )
                } else {
                    Log.e(TAG, "SHA-256 mismatch! Expected ${metadata.sha256}, calculated $calculatedSha")
                    sendAck(metadata.fileId, 0L, "SHA_MISMATCH")
                    _transferProgress.value = TransferProgress(
                        fileId = metadata.fileId,
                        fileName = metadata.name,
                        bytesTransferred = 0L,
                        totalBytes = 0L,
                        state = TransferState.FAILED,
                        errorMessage = "SHA-256 Checksum Verification Failed"
                    )
                }
                return@withContext
            }

            _transferProgress.value = TransferProgress(
                fileId = metadata.fileId,
                fileName = metadata.name,
                bytesTransferred = 0L,
                totalBytes = metadata.size,
                state = TransferState.IN_PROGRESS
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

            _transferProgress.value = _transferProgress.value?.copy(bytesTransferred = incomingBytesReceived)

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
                    _transferProgress.value = _transferProgress.value?.copy(state = TransferState.COMPLETED)
                } else {
                    Log.e(TAG, "SHA-256 mismatch! Expected ${metadata.sha256}, calculated $calculatedSha")
                    sendAck(metadata.fileId, incomingBytesReceived, "SHA_MISMATCH")
                    _transferProgress.value = _transferProgress.value?.copy(
                        state = TransferState.FAILED,
                        errorMessage = "SHA-256 Checksum Verification Failed"
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error writing incoming chunk: ${e.message}")
            _transferProgress.value = _transferProgress.value?.copy(
                state = TransferState.FAILED,
                errorMessage = e.message
            )
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
        _transferProgress.value = TransferProgress(
            fileId = metadata.fileId,
            fileName = metadata.name,
            bytesTransferred = bytesReceived,
            totalBytes = metadata.size,
            state = TransferState.CANCELLED
        )
        Log.d(TAG, "Incoming transfer cancelled by sender (fileId=$fileId, received $bytesReceived bytes)")
    }

    fun cancelTransfer() {
        isCancelled = true
        activeJob?.cancel()
        _transferProgress.value = _transferProgress.value?.copy(state = TransferState.CANCELLED)
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
    }
}
