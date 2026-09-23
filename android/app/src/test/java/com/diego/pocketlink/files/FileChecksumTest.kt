package com.diego.pocketlink.files

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream

class FileChecksumTest {

    @Test
    fun testSha256Calculation() {
        val testData = "Link Companion Protocol SHA-256 Test String".toByteArray(Charsets.UTF_8)
        val stream = ByteArrayInputStream(testData)
        val hashFromStream = ChecksumUtils.calculateSha256(stream)
        val hashFromBytes = ChecksumUtils.calculateSha256(testData)

        assertEquals("Hashes from stream and byte array must match", hashFromBytes, hashFromStream)
        assertEquals(64, hashFromStream.length)
    }

    @Test
    fun testChunkHeaderPackingAndUnpacking() {
        val fileIdHash = 0x12345678
        val offset = 1048576L

        val headerBytes = ChecksumUtils.createChunkHeader(fileIdHash, offset)
        assertEquals(ChecksumUtils.CHUNK_HEADER_SIZE, headerBytes.size)

        val (parsedHash, parsedOffset) = ChecksumUtils.parseChunkHeader(headerBytes)
        assertEquals(fileIdHash, parsedHash)
        assertEquals(offset, parsedOffset)
    }
}
