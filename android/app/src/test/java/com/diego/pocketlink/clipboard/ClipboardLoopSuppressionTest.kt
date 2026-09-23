package com.diego.pocketlink.clipboard

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardLoopSuppressionTest {

    @Test
    fun testDuplicateTextSuppressionLogic() {
        var lastText: String? = null

        fun shouldSend(newText: String): Boolean {
            if (newText == lastText || newText.isBlank()) {
                return false
            }
            lastText = newText
            return true
        }

        assertTrue("First unique text should be sent", shouldSend("Hello World"))
        assertFalse("Duplicate text should be suppressed", shouldSend("Hello World"))
        assertTrue("New unique text should be sent", shouldSend("Hello Link"))
        assertFalse("Blank text should be suppressed", shouldSend("   "))
    }
}
