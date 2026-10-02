package com.diego.pocketlink.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingTokenTest {

    @Test
    fun testQrPairingPayloadParseValid() {
        val raw = "pocketlink://pair?v=2&t=abcdef1234567890ghijkl"
        val pairing = QrPairingPayload.parse(raw)
        assertEquals("abcdef1234567890ghijkl", pairing?.token)
        assertNull(pairing?.identityFingerprint)
    }

    @Test
    fun testQrPairingPayloadParseWithTrailingWhitespace() {
        val raw = "  pocketlink://pair?v=2&t=abcdef1234567890ghijkl \n "
        val token = QrPairingPayload.parse(raw)
        assertEquals("abcdef1234567890ghijkl", token?.token)
    }

    @Test
    fun testQrPairingPayloadParseReorderedQueryParameters() {
        val raw = "pocketlink://pair?t=abcdef1234567890ghijkl&v=2"
        val token = QrPairingPayload.parse(raw)
        assertEquals("abcdef1234567890ghijkl", token?.token)
    }

    @Test
    fun testQrPairingPayloadParseWithIdentityFingerprint() {
        val raw = "pocketlink://pair?v=2&t=abcdef1234567890ghijkl&k=0123abcd"
        val pairing = QrPairingPayload.parse(raw)
        assertEquals("abcdef1234567890ghijkl", pairing?.token)
        assertEquals("0123abcd", pairing?.identityFingerprint)
    }

    @Test
    fun testQrPairingPayloadParseFingerprintOutOfOrder() {
        val raw = "pocketlink://pair?k=0123abcd&t=abcdef1234567890ghijkl&v=2"
        val pairing = QrPairingPayload.parse(raw)
        assertEquals("0123abcd", pairing?.identityFingerprint)
    }

    @Test
    fun testQrPairingPayloadParseWrongScheme() {
        val raw = "https://pair?v=2&t=abcdef1234567890ghijkl"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseWrongHost() {
        val raw = "pocketlink://connect?v=2&t=abcdef1234567890ghijkl"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseWrongVersion() {
        val raw = "pocketlink://pair?v=1&t=abcdef1234567890ghijkl"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseMissingToken() {
        val raw = "pocketlink://pair?v=2"
        assertNull(QrPairingPayload.parse(raw))
    }

    @Test
    fun testQrPairingPayloadParseBlankToken() {
        val raw = "pocketlink://pair?v=2&t=  "
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

    @Test
    fun testPendingPairingTokenCarriesFingerprint() {
        val token = PendingPairingToken(value = "t", identityFingerprint = "abc123")
        assertEquals("abc123", token.identityFingerprint)
        val legacy = PendingPairingToken(value = "t")
        assertNull(legacy.identityFingerprint)
    }
}
