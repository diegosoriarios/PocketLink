package com.diego.pocketlink.files

data class FileMetadata(
    val fileId: String,
    val name: String,
    val size: Long,
    val sha256: String,
    val mimeType: String
)

enum class TransferState {
    IDLE,
    IN_PROGRESS,
    COMPLETED,
    CANCELLED,
    FAILED
}

data class TransferProgress(
    val fileId: String,
    val fileName: String,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val state: TransferState,
    val errorMessage: String? = null
) {
    val fraction: Float
        get() = if (totalBytes > 0) (bytesTransferred.toFloat() / totalBytes.toFloat()).coerceIn(0f, 1f) else 0f
}
