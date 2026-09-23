package com.diego.pocketlink.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

object ProtocolEncoder {
    fun encode(frame: Frame): ByteArray {
        require(frame.payload.size.toUInt() == frame.header.payloadLength) {
            "Payload size (${frame.payload.size}) does not match header payloadLength (${frame.header.payloadLength})"
        }
        if (frame.header.payloadLength > ProtocolConstants.MAX_PAYLOAD_SIZE) {
            throw FrameOversizedException(
                "Payload length ${frame.header.payloadLength} exceeds maximum allowed size ${ProtocolConstants.MAX_PAYLOAD_SIZE}"
            )
        }

        val totalSize = ProtocolConstants.HEADER_SIZE + frame.payload.size
        val buffer = ByteBuffer.allocate(totalSize).order(ByteOrder.BIG_ENDIAN)

        buffer.put(ProtocolConstants.MAGIC_BYTES)
        buffer.putShort(frame.header.version.toShort())
        buffer.putShort(frame.header.messageType.id.toShort())
        buffer.putInt(frame.header.streamId.toInt())
        buffer.putInt(frame.header.payloadLength.toInt())
        buffer.put(frame.payload)

        return buffer.array()
    }
}
