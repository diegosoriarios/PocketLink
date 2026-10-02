package com.diego.pocketlink.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferStateTest {

    @Test
    fun testAckSuccessMapsToDelivered() {
        assertEquals(TransferState.DELIVERED, TransferState.ackStateFor("SUCCESS"))
    }

    @Test
    fun testAckShaMismatchMapsToMismatch() {
        assertEquals(TransferState.MISMATCH, TransferState.ackStateFor("SHA_MISMATCH"))
    }

    @Test
    fun testAckCancelledMapsToCancelled() {
        assertEquals(TransferState.CANCELLED, TransferState.ackStateFor("CANCELLED"))
    }

    @Test
    fun testUnknownAckStatusReturnsNull() {
        assertNull(TransferState.ackStateFor("WEIRD"))
        assertNull(TransferState.ackStateFor(""))
        assertNull(TransferState.ackStateFor("success"))
    }

    @Test
    fun testTerminalStates() {
        assertTrue(TransferState.DELIVERED.isTerminal)
        assertTrue(TransferState.COMPLETED.isTerminal)
        assertTrue(TransferState.CANCELLED.isTerminal)
        assertTrue(TransferState.MISMATCH.isTerminal)
        assertTrue(TransferState.FAILED.isTerminal)
    }

    @Test
    fun testNonTerminalStates() {
        assertFalse(TransferState.IDLE.isTerminal)
        assertFalse(TransferState.IN_PROGRESS.isTerminal)
        assertFalse(TransferState.VERIFYING.isTerminal)
    }

    @Test
    fun testFractionMath() {
        val progress = TransferProgress(
            fileId = "abc12345",
            fileName = "photo.jpg",
            bytesTransferred = 500L,
            totalBytes = 1000L,
            state = TransferState.IN_PROGRESS,
            direction = TransferDirection.SEND
        )
        assertEquals(0.5f, progress.fraction)
    }

    @Test
    fun testFractionClampsAndZeroTotal() {
        val overflow = TransferProgress(
            fileId = "abc12345",
            fileName = "photo.jpg",
            bytesTransferred = 2000L,
            totalBytes = 1000L,
            state = TransferState.IN_PROGRESS,
            direction = TransferDirection.RECEIVE
        )
        assertEquals(1f, overflow.fraction)

        val zeroTotal = overflow.copy(totalBytes = 0L)
        assertEquals(0f, zeroTotal.fraction)
    }
}
