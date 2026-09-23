package com.diego.pocketlink.protocol

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ProtocolDecoder {
    private var buffer = ByteArrayOutputStream()

    /**
     * Appends bytes to decoder buffer and returns any fully decoded frames.
     * @throws InvalidFrameException if magic bytes do not match "LINK"
     * @throws FrameOversizedException if frame payload exceeds MAX_PAYLOAD_SIZE
     * @throws UnknownMessageTypeException if message type ID is not recognized
     */
    fun feed(data: ByteArray, offset: Int = 0, length: Int = data.size): List<Frame> {
        buffer.write(data, offset, length)
        val frames = mutableListOf<Frame>()

        while (true) {
            val currentBytes = buffer.toByteArray()
            if (currentBytes.size < ProtocolConstants.HEADER_SIZE) {
                break
            }

            val byteBuffer = ByteBuffer.wrap(currentBytes).order(ByteOrder.BIG_ENDIAN)

            // Validate magic bytes
            val magic = ByteArray(4)
            byteBuffer.get(magic)
            if (!magic.contentEquals(ProtocolConstants.MAGIC_BYTES)) {
                reset()
                throw InvalidFrameException(
                    "Invalid magic bytes: 0x${magic.joinToString("") { "%02X".format(it) }}. Expected 'LINK'"
                )
            }

            val version = byteBuffer.short.toUShort()
            val messageTypeId = byteBuffer.short.toUShort()
            val streamId = byteBuffer.int.toUInt()
            val payloadLength = byteBuffer.int.toUInt()

            if (payloadLength > ProtocolConstants.MAX_PAYLOAD_SIZE) {
                reset()
                throw FrameOversizedException(
                    "Payload length $payloadLength exceeds limit of ${ProtocolConstants.MAX_PAYLOAD_SIZE} bytes"
                )
            }

            val totalFrameSize = ProtocolConstants.HEADER_SIZE + payloadLength.toInt()

            if (currentBytes.size < totalFrameSize) {
                // Incomplete frame, wait for more data
                break
            }

            val messageType = MessageType.fromId(messageTypeId)
                ?: run {
                    reset()
                    throw UnknownMessageTypeException(messageTypeId)
                }

            val payload = ByteArray(payloadLength.toInt())
            byteBuffer.get(payload)

            val header = FrameHeader(
                version = version,
                messageType = messageType,
                streamId = streamId,
                payloadLength = payloadLength
            )
            frames.add(Frame(header, payload))

            // Consume frame bytes from buffer
            val remainingLength = currentBytes.size - totalFrameSize
            val newBuffer = ByteArrayOutputStream()
            if (remainingLength > 0) {
                newBuffer.write(currentBytes, totalFrameSize, remainingLength)
            }
            buffer = newBuffer
        }

        return frames
    }

    fun reset() {
        buffer.reset()
    }
}
