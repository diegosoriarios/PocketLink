package com.diego.pocketlink.clipboard

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardLoopSuppressionTest {

    /** Mirrors ClipboardSyncManager's listener suppression gate. */
    private class LocalSendGate(var duplicateSuppressWindowMs: Long = 30_000L) {
        var elapsedRealtime = 0L
        var lastLocalSentText: String? = null
        var lastLocalSentAt = 0L
        var lastRemoteAppliedText: String? = null
        var lastSetTimestamp = -10_000L

        fun markRemoteApplied(text: String) {
            lastRemoteAppliedText = text
            lastSetTimestamp = elapsedRealtime
        }

        fun advance(ms: Long) {
            elapsedRealtime += ms
        }

        fun shouldSend(newText: String): Boolean {
            if (elapsedRealtime - lastSetTimestamp < 1_000L) return false
            if (newText.isBlank()) return false
            if (newText == lastRemoteAppliedText) return false
            if (newText == lastLocalSentText && elapsedRealtime - lastLocalSentAt < duplicateSuppressWindowMs) {
                return false
            }
            lastLocalSentText = newText
            lastLocalSentAt = elapsedRealtime
            return true
        }
    }

    @Test
    fun testDuplicateTextSuppressionLogic() {
        val gate = LocalSendGate()

        assertTrue("First unique text should be sent", gate.shouldSend("Hello World"))
        assertFalse("Duplicate text should be suppressed", gate.shouldSend("Hello World"))
        assertTrue("New unique text should be sent", gate.shouldSend("Hello Link"))
        assertFalse("Blank text should be suppressed", gate.shouldSend("   "))
    }

    @Test
    fun testRemoteAppliedTextIsNotEchoedBack() {
        val gate = LocalSendGate()

        gate.advance(2_000)
        gate.markRemoteApplied("from mac")
        gate.advance(2_000)
        assertFalse("Echo of remote-applied text must be suppressed", gate.shouldSend("from mac"))
        assertTrue("Different local copy after remote write is sent", gate.shouldSend("local"))
    }

    @Test
    fun testRecopyingIdenticalTextAfterWindowIsNotSuppressed() {
        val gate = LocalSendGate(duplicateSuppressWindowMs = 30_000L)

        gate.advance(2_000)
        assertTrue(gate.shouldSend("same"))
        assertFalse("Immediate duplicate suppressed", gate.shouldSend("same"))

        gate.advance(31_000)
        assertTrue(
            "Re-copy of identical text after the duplicate window must be sent again",
            gate.shouldSend("same")
        )
    }

    @Test
    fun testLoopStaysBrokenAcrossRoundTrip() {
        val gate = LocalSendGate()

        gate.advance(2_000)
        assertTrue("Local copy X is sent", gate.shouldSend("X"))
        gate.markRemoteApplied("X")
        gate.advance(2_000)
        assertFalse("Echo of X (remote-applied) is suppressed", gate.shouldSend("X"))
    }
}
