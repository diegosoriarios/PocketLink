package com.diego.pocketlink.protocol

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class MirrorProtocolTest {

    @Test
    fun testFramePayloadRoundTrip() {
        val accessUnit = ByteArray(64) { it.toByte() }
        val payload = MirrorProtocol.encodeFramePayload(
            timestampMs = 1_700_000_123_456L,
            keyframe = true,
            accessUnit = accessUnit
        )
        assertEquals(13 + accessUnit.size, payload.size)

        val decoded = MirrorProtocol.decodeFramePayload(payload)!!
        assertEquals(1_700_000_123_456L, decoded.timestampMs)
        assertTrue(decoded.keyframe)
        assertArrayEquals(accessUnit, decoded.accessUnit)
    }

    @Test
    fun testFramePayloadNonKeyframe() {
        val payload = MirrorProtocol.encodeFramePayload(42L, false, byteArrayOf(1, 2, 3))
        val decoded = MirrorProtocol.decodeFramePayload(payload)!!
        assertEquals(42L, decoded.timestampMs)
        assertFalse(decoded.keyframe)
    }

    @Test
    fun testDecodeFramePayloadRejectsTruncatedAndOverlongLengths() {
        assertNull(MirrorProtocol.decodeFramePayload(ByteArray(12)))

        val empty = MirrorProtocol.decodeFramePayload(ByteArray(13))!!
        assertEquals(0, empty.accessUnit.size)

        val payload = MirrorProtocol.encodeFramePayload(1L, true, byteArrayOf(9, 9, 9))
        payload[9] = 0x7F
        assertNull(MirrorProtocol.decodeFramePayload(payload))
    }

    @Test
    fun testConfigJsonRoundTrip() {
        val config = MirrorProtocol.MirrorConfig(
            width = 1080,
            height = 2400,
            fps = 30,
            bitrateBps = 4_000_000,
            sps = byteArrayOf(0, 0, 0, 1, 0x67, 0x42),
            pps = byteArrayOf(0, 0, 0, 1, 0x68)
        )
        val json = JSONObject(MirrorProtocol.encodeConfigJson(config))
        val parsed = MirrorProtocol.parseConfigJson(json)!!
        assertEquals(config.width, parsed.width)
        assertEquals(config.height, parsed.height)
        assertEquals(config.fps, parsed.fps)
        assertEquals(config.bitrateBps, parsed.bitrateBps)
        assertArrayEquals(config.sps, parsed.sps)
        assertArrayEquals(config.pps, parsed.pps)
    }

    @Test
    fun testParseConfigJsonRejectsInvalidDimensions() {
        assertNull(MirrorProtocol.parseConfigJson(JSONObject("""{"width":0,"height":100}""")))
        assertNull(MirrorProtocol.parseConfigJson(JSONObject("{}")))
    }

    @Test
    fun testTouchJsonRoundTrip() {
        val json = JSONObject(MirrorProtocol.encodeTouchJson(MirrorProtocol.ACTION_MOVE, 0.25, 0.75))
        val parsed = MirrorProtocol.parseTouchJson(json)!!
        assertEquals(MirrorProtocol.ACTION_MOVE, parsed.action)
        assertEquals(0.25, parsed.x, 1e-9)
        assertEquals(0.75, parsed.y, 1e-9)
    }

    @Test
    fun testParseTouchJsonRejectsInvalid() {
        assertNull(MirrorProtocol.parseTouchJson(JSONObject("""{"action":"swipe","x":0.5,"y":0.5}""")))
        assertNull(MirrorProtocol.parseTouchJson(JSONObject("""{"action":"down","y":0.5}""")))
    }

    @Test
    fun testBase64Compatibility() {
        val bytes = byteArrayOf(0, 0, 0, 1, 0x67.toByte())
        val encoded = Base64.getEncoder().encodeToString(bytes)
        assertEquals(bytes.toList(), Base64.getDecoder().decode(encoded).toList())
    }
}
