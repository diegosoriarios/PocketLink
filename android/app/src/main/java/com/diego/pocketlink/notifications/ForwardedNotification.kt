package com.diego.pocketlink.notifications

data class ForwardedNotification(
    val id: String,
    val packageName: String,
    val appName: String,
    val title: String,
    val text: String,
    val postTime: Long,
    val hasQuickReply: Boolean
)
