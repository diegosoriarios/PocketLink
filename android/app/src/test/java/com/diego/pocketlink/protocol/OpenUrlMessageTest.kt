package com.diego.pocketlink.protocol

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OpenUrlMessageTest {
    @Test
    fun `message id is 0x0065 and resolves via fromId`() {
        assertEquals(0x0065u.toUShort(), MessageType.OPEN_URL.id)
        assertEquals(MessageType.OPEN_URL, MessageType.fromId(0x0065u))
        assertEquals(MessageType.REMOTE_TEXT, MessageType.fromId(0x0064u))
        assertNull(MessageType.fromId(0x0066u))
    }

    @Test
    fun `url payload round-trips through frame`() {
        val url = "https://example.com/page?x=1"
        val payload = """{"url":"$url"}""".toByteArray(Charsets.UTF_8)
        val frame = Frame(
            header = FrameHeader(
                messageType = MessageType.OPEN_URL,
                streamId = 7u,
                payloadLength = payload.size.toUInt()
            ),
            payload = payload
        )

        assertEquals(MessageType.OPEN_URL, frame.header.messageType)
        val parsed = JSONObject(frame.payload.toString(Charsets.UTF_8)).optString("url")
        assertEquals(url, parsed)
    }
}
