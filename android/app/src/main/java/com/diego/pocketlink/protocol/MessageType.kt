package com.diego.pocketlink.protocol

enum class MessageType(val id: UShort) {
    HANDSHAKE(0x0001u),
    PING(0x0002u),
    PONG(0x0003u),
    DEVICE_INFO(0x0004u),
    ERROR(0x0005u),
    CLIPBOARD(0x0010u),
    BATTERY(0x0020u),
    NOTIFICATION(0x0030u),
    NOTIFICATION_REPLY(0x0031u),
    FILE_HEADER(0x0040u),
    FILE_CHUNK(0x0041u),
    FILE_ACK(0x0042u),
    FILE_CANCEL(0x0043u);

    companion object {
        fun fromId(id: UShort): MessageType? = entries.find { it.id == id }
    }
}
