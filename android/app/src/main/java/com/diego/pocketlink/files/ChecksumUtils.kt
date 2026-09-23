package com.diego.pocketlink.files

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

object ChecksumUtils {

    fun calculateSha256(inputStream: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(8192)
        var bytesRead: Int
        while (inputStream.read(buffer).also { bytesRead = it } != -1) {
            digest.update(buffer, 0, bytesRead)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun calculateSha256(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(data)
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun createChunkHeader(fileIdHash: Int, offset: Long): ByteArray {
        val buffer = ByteBuffer.allocate(CHUNK_HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
        buffer.putInt(fileIdHash)
        buffer.putLong(offset)
        return buffer.array()
    }

    fun parseChunkHeader(data: ByteArray, offset: Int = 0): Pair<Int, Long> {
        val buffer = ByteBuffer.wrap(data, offset, CHUNK_HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
        val fileIdHash = buffer.int
        val chunkOffset = buffer.long
        return Pair(fileIdHash, chunkOffset)
    }

    const val CHUNK_HEADER_SIZE = 12
    const val DEFAULT_CHUNK_SIZE = 64 * 1024 // 64 KB chunks
}
