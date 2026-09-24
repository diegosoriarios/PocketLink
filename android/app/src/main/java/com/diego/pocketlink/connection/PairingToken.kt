package com.diego.pocketlink.connection

data class PendingPairingToken(
    val value: String,
    val receivedAtMillis: Long = System.currentTimeMillis()
) {
    fun isExpired(nowMs: Long = System.currentTimeMillis()): Boolean {
        return nowMs - receivedAtMillis > EXPIRATION_MS
    }

    companion object {
        const val EXPIRATION_MS = 5 * 60 * 1000L // 5 minutes
    }
}

object QrPairingPayload {
    fun parse(raw: String): String? {
        val trimmed = raw.trim()
        if (!trimmed.startsWith("pocketlink://pair?")) return null
        val queryString = trimmed.substringAfter("pocketlink://pair?")
        val params = queryString.split("&").associate { param ->
            val parts = param.split("=", limit = 2)
            val key = parts.getOrNull(0) ?: ""
            val value = parts.getOrNull(1) ?: ""
            key to value
        }
        if (params["v"] != "1") return null
        val token = params["t"]
        return if (!token.isNullOrBlank()) token else null
    }
}
