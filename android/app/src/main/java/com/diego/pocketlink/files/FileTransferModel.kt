package com.diego.pocketlink.files

data class FileMetadata(
    val fileId: String,
    val name: String,
    val size: Long,
    val sha256: String,
    val mimeType: String
)

enum class TransferDirection {
    SEND,
    RECEIVE
}

enum class TransferState {
    IDLE,
    IN_PROGRESS,
    VERIFYING,
    DELIVERED,
    COMPLETED,
    CANCELLED,
    MISMATCH,
    FAILED;

    val isTerminal: Boolean
        get() = this == DELIVERED || this == COMPLETED || this == CANCELLED || this == MISMATCH || this == FAILED

    companion object {
        fun ackStateFor(status: String): TransferState? = when (status) {
            "SUCCESS" -> DELIVERED
            "SHA_MISMATCH" -> MISMATCH
            "CANCELLED" -> CANCELLED
            else -> null
        }
    }
}

data class TransferProgress(
    val fileId: String,
    val fileName: String,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val state: TransferState,
    val direction: TransferDirection,
    val errorMessage: String? = null
) {
    val fraction: Float
        get() = if (totalBytes > 0) (bytesTransferred.toFloat() / totalBytes.toFloat()).coerceIn(0f, 1f) else 0f
}
