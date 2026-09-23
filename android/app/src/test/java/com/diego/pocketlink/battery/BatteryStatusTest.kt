package com.diego.pocketlink.battery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BatteryStatusTest {

    @Test
    fun testBatteryStatusDataClass() {
        val status = BatteryStatus(
            level = 88,
            isCharging = true,
            powerSaveMode = false
        )

        assertEquals(88, status.level)
        assertTrue(status.isCharging)
        assertEquals(false, status.powerSaveMode)
    }
}
