package com.diego.pocketlink.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingTokenTest {

    @Test
    fun testQrPairingPayloadParseValid() {
        val raw = "pocketlink://pair?v=1&t=abcdef1234567890ghijkl"
        val token = QrPairingPayload.parse(raw)
        assertEquals("abcdef1234567890ghijkl", token)
    }

    @Test
    fun testQrPairingPayloadParseWithTrailingWhitespace() {
        val raw = "  pocketlink://pair?v=1&t=abcdef1234567890ghijkl \n "
        val token = QrPairingPayload.parse(raw)
        assertEquals("abcdef1234567890ghijkl", token)
    }

    @Test
    fun testQrPairingPayloadParseReorderedQueryParameters() {
        val raw = "pocketlink://pair?t=abcdef1234567890ghijkl&v=1"
        val token = QrPairingPayload.parse(raw)
        assertEquals("abcdef1234567890ghijkl", token)
    }

    @Test
    fun testQrPairingPayloadParseWrongScheme() {
        val raw = "https://pair?v=1&t=abcdef1234567890ghijkl"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseWrongHost() {
        val raw = "pocketlink://connect?v=1&t=abcdef1234567890ghijkl"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseWrongVersion() {
        val raw = "pocketlink://pair?v=2&t=abcdef1234567890ghijkl"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseMissingToken() {
        val raw = "pocketlink://pair?v=1"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseBlankToken() {
        val raw = "pocketlink://pair?v=1&t=  "
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testPendingPairingTokenIsExpired() {
        val startMs = 1000000L
        val token = PendingPairingToken(value = "test-token", receivedAtMillis = startMs)

        // At creation time
        assertFalse(token.isExpired(startMs))

        // Within 5 minutes (e.g., 4 minutes 59 seconds)
        assertFalse(token.isExpired(startMs + 4 * 60 * 1000L + 59 * 1000L))

        // Exactly 5 minutes (300,000 ms)
        assertFalse(token.isExpired(startMs + 300000L))

        // Past 5 minutes (e.g. 300,001 ms)
        assertTrue(token.isExpired(startMs + 300001L))
    }
}
