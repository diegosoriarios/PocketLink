package com.diego.pocketlink.security

import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.KeyParameter

/**
 * A Noise CipherState: symmetric key plus monotonically increasing 96-bit
 * nonces (`32 zero bits || u64 big-endian counter`). Encrypt and decrypt
 * counters are tracked separately so a single state can be used for either
 * direction without cross-talk.
 */
class CipherState(key: ByteArray? = null) {
    private var key: ByteArray? = key?.copyOf()
    private var encryptNonce: ULong = 0u
    private var decryptNonce: ULong = 0u

    val isInitialized: Boolean get() = key != null

    fun setKey(newKey: ByteArray) {
        key = newKey.copyOf()
        encryptNonce = 0u
        decryptNonce = 0u
    }

    /** Returns ciphertext || 16-byte tag. */
    @Throws(NoiseException::class)
    fun encrypt(plaintext: ByteArray, aad: ByteArray = ByteArray(0)): ByteArray {
        val activeKey = key ?: throw NoiseException("Cipher not initialized")
        val cipher = ChaCha20Poly1305()
        cipher.init(
            true,
            AEADParameters(KeyParameter(activeKey, 0, activeKey.size), 128, nonceBytes(encryptNonce), aad)
        )
        val out = ByteArray(plaintext.size + TAG_SIZE)
        val written = cipher.processBytes(plaintext, 0, plaintext.size, out, 0)
        cipher.doFinal(out, written)
        encryptNonce += 1u
        return out
    }

    /** Expects ciphertext || 16-byte tag. */
    @Throws(NoiseException::class)
    fun decrypt(ciphertextWithTag: ByteArray, aad: ByteArray = ByteArray(0)): ByteArray {
        val activeKey = key ?: throw NoiseException("Cipher not initialized")
        if (ciphertextWithTag.size < TAG_SIZE) throw NoiseException("Decrypt failed")
        val cipher = ChaCha20Poly1305()
        cipher.init(
            false,
            AEADParameters(KeyParameter(activeKey, 0, activeKey.size), 128, nonceBytes(decryptNonce), aad)
        )
        // BC may write up to the input length into `out` before the tag
        // check, so the buffer must be input-sized, not plaintext-sized.
        val out = ByteArray(ciphertextWithTag.size)
        try {
            val written = cipher.processBytes(ciphertextWithTag, 0, ciphertextWithTag.size, out, 0)
            val finalized = cipher.doFinal(out, written)
            decryptNonce += 1u
            return out.copyOf(written + finalized)
        } catch (e: Exception) {
            throw NoiseException("Decrypt failed")
        }
    }

    companion object {
        const val TAG_SIZE = 16

        /** 12-byte nonce: 4 zero bytes || u64 big-endian counter. */
        fun nonceBytes(counter: ULong): ByteArray {
            val bytes = ByteArray(12)
            var value = counter
            for (i in 11 downTo 4) {
                bytes[i] = (value and 0xFFu).toByte()
                value = value shr 8
            }
            return bytes
        }
    }
}

class NoiseException(message: String, cause: Throwable? = null) : Exception(message, cause)
