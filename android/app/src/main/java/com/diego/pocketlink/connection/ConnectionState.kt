package com.diego.pocketlink.connection

sealed interface ConnectionState {
    data object Disconnected : ConnectionState

    data class Listening(
        val port: Int,
        val localIpAddresses: List<String>
    ) : ConnectionState

    data class Connected(
        val remoteAddress: String,
        val localPort: Int
    ) : ConnectionState

    data class Error(
        val message: String
    ) : ConnectionState
}

data class ConnectionEvent(
    val timestamp: Long = System.currentTimeMillis(),
    val message: String
)
