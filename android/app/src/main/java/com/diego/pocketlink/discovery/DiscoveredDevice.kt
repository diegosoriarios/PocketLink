package com.diego.pocketlink.discovery

data class DiscoveredDevice(
    val id: String,
    val name: String,
    val host: String,
    val port: Int
)
