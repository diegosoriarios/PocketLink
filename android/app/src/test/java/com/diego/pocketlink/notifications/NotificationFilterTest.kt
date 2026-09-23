package com.diego.pocketlink.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationFilterTest {

    @Test
    fun testNotificationFilterLogic() {
        val appPackageName = "com.diego.pocketlink"

        fun shouldForward(pkg: String, isOngoing: Boolean, title: String, text: String): Boolean {
            if (isOngoing) return false
            if (pkg == appPackageName) return false
            if (title.isBlank() && text.isBlank()) return false
            return true
        }

        assertTrue("Valid third party notification should be forwarded",
            shouldForward("com.whatsapp", false, "John Doe", "Hello there!"))

        assertFalse("Ongoing media/system notification should be filtered",
            shouldForward("com.spotify.music", true, "Song Title", "Artist"))

        assertFalse("Self-notification from companion app should be filtered",
            shouldForward("com.diego.pocketlink", false, "Link Active", "Service running"))

        assertFalse("Empty title and text notification should be filtered",
            shouldForward("com.example.app", false, "", ""))
    }

    @Test
    fun testForwardedNotificationModel() {
        val notif = ForwardedNotification(
            id = "key_123",
            packageName = "com.slack",
            appName = "Slack",
            title = "Project Channel",
            text = "Build succeeded!",
            postTime = 1711000000000L,
            hasQuickReply = true
        )

        assertEquals("key_123", notif.id)
        assertEquals("com.slack", notif.packageName)
        assertEquals("Slack", notif.appName)
        assertEquals("Project Channel", notif.title)
        assertEquals("Build succeeded!", notif.text)
        assertEquals(1711000000000L, notif.postTime)
        assertTrue(notif.hasQuickReply)
    }
}
