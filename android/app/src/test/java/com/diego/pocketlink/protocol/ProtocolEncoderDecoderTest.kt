package com.diego.pocketlink.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ProtocolEncoderDecoderTest {

    private lateinit var decoder: ProtocolDecoder

    @Before
    fun setUp() {
        decoder = ProtocolDecoder()
    }

    @Test
    fun testEncodeAndDecodeFrame_pingFrame() {
        val payload = """{"timestamp":1711000000000}""".toByteArray(Charsets.UTF_8)
        val header = FrameHeader(
            version = 1u,
            messageType = MessageType.PING,
            streamId = 100u,
            payloadLength = payload.size.toUInt()
        )
        val frame = Frame(header, payload)

        val encoded = ProtocolEncoder.encode(frame)
        assertEquals(ProtocolConstants.HEADER_SIZE + payload.size, encoded.size)

        val decodedFrames = decoder.feed(encoded)
        assertEquals(1, decodedFrames.size)

        val decoded = decodedFrames[0]
        assertEquals(MessageType.PING, decoded.header.messageType)
        assertEquals(1u.toUShort(), decoded.header.version)
        assertEquals(100u, decoded.header.streamId)
        assertEquals(payload.size.toUInt(), decoded.header.payloadLength)
        assertArrayEquals(payload, decoded.payload)
    }

    @Test
    fun testDecodeFragmentedStream() {
        val payload = """{"text":"Hello Link"}""".toByteArray(Charsets.UTF_8)
        val header = FrameHeader(
            version = 1u,
            messageType = MessageType.CLIPBOARD,
            streamId = 1u,
            payloadLength = payload.size.toUInt()
        )
        val frame = Frame(header, payload)
        val encoded = ProtocolEncoder.encode(frame)

        // Feed byte by byte
        var decoded: List<Frame> = emptyList()
        for (i in encoded.indices) {
            decoded = decoder.feed(byteArrayOf(encoded[i]))
            if (i < encoded.size - 1) {
                assertTrue("Expected empty result until last byte", decoded.isEmpty())
            }
        }

        assertEquals(1, decoded.size)
        assertEquals(MessageType.CLIPBOARD, decoded[0].header.messageType)
        assertArrayEquals(payload, decoded[0].payload)
    }

    @Test
    fun testMultipleFramesInSingleChunk() {
        val frame1 = Frame(
            FrameHeader(messageType = MessageType.PING, streamId = 1u, payloadLength = 4u),
            byteArrayOf(1, 2, 3, 4)
        )
        val frame2 = Frame(
            FrameHeader(messageType = MessageType.PONG, streamId = 2u, payloadLength = 4u),
            byteArrayOf(5, 6, 7, 8)
        )

        val bytes1 = ProtocolEncoder.encode(frame1)
        val bytes2 = ProtocolEncoder.encode(frame2)
        val combined = bytes1 + bytes2

        val decoded = decoder.feed(combined)
        assertEquals(2, decoded.size)
        assertEquals(MessageType.PING, decoded[0].header.messageType)
        assertEquals(MessageType.PONG, decoded[1].header.messageType)
    }

    @Test
    fun testInvalidMagicBytes_throwsException() {
        val badBytes = "BADM".toByteArray(Charsets.US_ASCII) + ByteArray(12)
        assertThrows(InvalidFrameException::class.java) {
            decoder.feed(badBytes)
        }
    }

    @Test
    fun testFrameOversized_throwsException() {
        val headerBytes = ByteBuffer.allocate(ProtocolConstants.HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
            .put(ProtocolConstants.MAGIC_BYTES)
            .putShort(1)
            .putShort(MessageType.PING.id.toShort())
            .putInt(1)
            .putInt(9_000_000) // Exceeds 8 MB
            .array()

        assertThrows(FrameOversizedException::class.java) {
            decoder.feed(headerBytes)
        }
    }

    @Test
    fun testUnknownMessageType_throwsException() {
        val headerBytes = ByteBuffer.allocate(ProtocolConstants.HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
            .put(ProtocolConstants.MAGIC_BYTES)
            .putShort(1)
            .putShort(0x9999.toShort()) // Unknown type
            .putInt(1)
            .putInt(0)
            .array()

        assertThrows(UnknownMessageTypeException::class.java) {
            decoder.feed(headerBytes)
        }
    }
}
