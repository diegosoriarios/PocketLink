package com.diego.pocketlink.discovery

import org.junit.Assert.assertEquals
import org.junit.Test

class NsdDiscoveryTest {

    @Test
    fun testDiscoveredDeviceModel() {
        val device = DiscoveredDevice(
            id = "192.168.1.100:52345",
            name = "Link-MacBook-Pro",
            host = "192.168.1.100",
            port = 52345
        )

        assertEquals("192.168.1.100:52345", device.id)
        assertEquals("Link-MacBook-Pro", device.name)
        assertEquals("192.168.1.100", device.host)
        assertEquals(52345, device.port)
    }

    @Test
    fun testNsdConstants() {
        assertEquals("_link._tcp.", NsdAdvertiser.SERVICE_TYPE)
    }
}
