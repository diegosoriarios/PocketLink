package com.diego.pocketlink.protocol

object ProtocolConstants {
    val MAGIC_BYTES: ByteArray = "LINK".toByteArray(Charsets.US_ASCII)
    const val HEADER_SIZE: Int = 16
    const val PROTOCOL_VERSION: UShort = 1u
    const val MAX_PAYLOAD_SIZE: UInt = 8_388_608u // 8 MB limit
}

data class FrameHeader(
    val version: UShort = ProtocolConstants.PROTOCOL_VERSION,
    val messageType: MessageType,
    val streamId: UInt,
    val payloadLength: UInt
)

data class Frame(
    val header: FrameHeader,
    val payload: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as Frame

        if (header != other.header) return false
        if (!payload.contentEquals(other.payload)) return false

        return true
    }

    override fun hashCode(): Int {
        var result = header.hashCode()
        result = 31 * result + payload.contentHashCode()
        return result
    }
}
