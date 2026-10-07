package com.diego.pocketlink.protocol

enum class MessageType(val id: UShort) {
    HANDSHAKE(0x0001u),
    PING(0x0002u),
    PONG(0x0003u),
    DEVICE_INFO(0x0004u),
    ERROR(0x0005u),
    CLIPBOARD(0x0010u),
    CLIPBOARD_ACK(0x0011u),
    BATTERY(0x0020u),
    NOTIFICATION(0x0030u),
    NOTIFICATION_REPLY(0x0031u),
    NOTIFICATION_ACTION(0x0032u),
    NOTIFICATION_REPLY_ACK(0x0033u),
    FILE_HEADER(0x0040u),
    FILE_CHUNK(0x0041u),
    FILE_ACK(0x0042u),
    FILE_CANCEL(0x0043u),
    MIRROR_START(0x0050u),
    MIRROR_STOP(0x0051u),
    MIRROR_CONFIG(0x0052u),
    MIRROR_FRAME(0x0053u),
    REMOTE_TOUCH(0x0054u),
    REMOTE_TEXT(0x0064u),
    CRYPTO_M1(0x0060u),
    CRYPTO_M2(0x0061u),
    CRYPTO_M3(0x0062u),
    OPEN_URL(0x0065u);

    /** True for Noise handshake frames (CRYPTO_M1/M2/M3). */
    val isCryptoHandshake: Boolean
        get() = this == CRYPTO_M1 || this == CRYPTO_M2 || this == CRYPTO_M3

    companion object {
        fun fromId(id: UShort): MessageType? = entries.find { it.id == id }
    }
}
