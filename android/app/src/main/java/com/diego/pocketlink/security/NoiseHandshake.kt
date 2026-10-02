package com.diego.pocketlink.security

import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Result payloads for reading handshake messages. */
class PeerIdentity(
    val identityKey: ByteArray,
    val staticKey: ByteArray,
    val fingerprint: String
)

/** Transport cipher states derived from [NoiseHandshake.split]. */
class TransportKeys(
    val send: CipherState,
    val receive: CipherState,
    val handshakeHash: ByteArray
)

/**
 * Noise XX handshake over X25519 / ChaChaPoly / SHA-256.
 *
 * Wire (one message per LINK frame, no extra length prefix):
 * - M1 `-> e`            : 32 B
 * - M2 `<- e, ee, s, es` : 80 B + encrypted payload (identity || signature)
 * - M3 `-> s, se`        : 48 B + encrypted payload (identity || signature)
 *
 * The encrypted payload carries the sender's Ed25519 identity public key
 * and an Ed25519 signature over the sender's Noise static X25519 public
 * key, binding the two keys together. Byte-for-byte compatible with the
 * macOS `LinkSecurity.NoiseHandshake` implementation.
 */
class NoiseHandshake(staticKey: ByteArray) {

    private var ck: ByteArray
    private var h: ByteArray
    private var k: ByteArray? = null
    private var nonce: ULong = 0u

    private val staticKey: ByteArray = staticKey.copyOf()
    private var ephemeralKey: ByteArray? = null
    private var remoteStatic: ByteArray? = null
    private var remoteEphemeral: ByteArray? = null

    var handshakeHash: ByteArray = ByteArray(0)
        private set

    init {
        require(staticKey.size == KEY_SIZE) { "X25519 static key must be 32 bytes" }
        val name = PROTOCOL_NAME.toByteArray(Charsets.US_ASCII)
        h = if (name.size <= 32) name + ByteArray(32 - name.size) else sha256(name)
        ck = h.copyOf()
    }

    // MARK: - Initiator

    /** Writes message 1 (`-> e`). */
    fun writeM1(random: SecureRandom = SecureRandom()): ByteArray {
        val e = X25519PrivateKeyParameters(random)
        val eBytes = ByteArray(KEY_SIZE)
        e.generatePublicKey().encode(eBytes, 0)
        ephemeralKey = ByteArray(KEY_SIZE).also { e.encode(it, 0) }
        h = sha256(h + eBytes)
        return eBytes
    }

    /**
     * Reads message 2 (`<- e, ee, s, es`), verifies the responder's identity
     * signature, and returns its identity public key.
     */
    @Throws(NoiseException::class)
    fun readM2(message: ByteArray): PeerIdentity {
        if (message.size < M2_STATIC_END) throw NoiseException("Invalid message length")
        val e = message.copyOfRange(0, KEY_SIZE)
        remoteEphemeral = e
        h = sha256(h + e)

        mixKey(dh(requireEphemeral(), e))

        val sBytes = decryptAndHash(message.copyOfRange(KEY_SIZE, M2_STATIC_END))
        remoteStatic = sBytes

        mixKey(dh(requireEphemeral(), sBytes))

        if (message.size < M2_STATIC_END + IdentityPayload.encryptedWireSize) {
            throw NoiseException("Invalid identity payload")
        }
        val payloadBytes = decryptAndHash(
            message.copyOfRange(M2_STATIC_END, M2_STATIC_END + IdentityPayload.encryptedWireSize)
        )
        val payload = IdentityPayload.parse(payloadBytes)
        if (!verifyPayload(payload, sBytes)) throw NoiseException("Signature verification failed")
        return PeerIdentity(payload.identityKey, sBytes, LinkIdentity.fingerprintFor(payload.identityKey))
    }

    /** Writes message 3 (`-> s, se`) carrying our identity payload. */
    @Throws(NoiseException::class)
    fun writeM3(identity: LinkIdentity): ByteArray {
        val sBytes = encryptAndHash(staticKey.publicX25519())

        mixKey(dh(staticKey, requireRemoteEphemeral()))

        val payload = IdentityPayload(
            identityKey = identity.identityPublicKey,
            signature = identity.signStaticKey(staticKey.publicX25519())
        )
        val payloadBytes = encryptAndHash(payload.encoded())
        return sBytes + payloadBytes
    }

    // MARK: - Responder

    /** Reads message 1 (`-> e`). */
    @Throws(NoiseException::class)
    fun readM1(message: ByteArray) {
        if (message.size != KEY_SIZE) throw NoiseException("Invalid message length")
        remoteEphemeral = message.copyOf()
        h = sha256(h + message)
    }

    /** Writes message 2 (`<- e, ee, s, es`) carrying our identity payload. */
    @Throws(NoiseException::class)
    fun writeM2(identity: LinkIdentity, random: SecureRandom = SecureRandom()): ByteArray {
        val e = X25519PrivateKeyParameters(random)
        val eBytes = ByteArray(KEY_SIZE)
        e.generatePublicKey().encode(eBytes, 0)
        ephemeralKey = ByteArray(KEY_SIZE).also { e.encode(it, 0) }
        h = sha256(h + eBytes)

        // `ee`
        mixKey(dh(requireEphemeral(), requireRemoteEphemeral()))

        val sBytes = encryptAndHash(staticKey.publicX25519())

        // `es`: shared = responder static x initiator ephemeral.
        mixKey(dh(staticKey, requireRemoteEphemeral()))

        val payload = IdentityPayload(
            identityKey = identity.identityPublicKey,
            signature = identity.signStaticKey(staticKey.publicX25519())
        )
        val payloadBytes = encryptAndHash(payload.encoded())
        return eBytes + sBytes + payloadBytes
    }

    /**
     * Reads message 3 (`-> s, se`), verifies the initiator's identity
     * signature, and returns its identity public key.
     */
    @Throws(NoiseException::class)
    fun readM3(message: ByteArray): PeerIdentity {
        if (message.size < M3_STATIC_END + IdentityPayload.encryptedWireSize) {
            throw NoiseException("Invalid identity payload")
        }
        val sBytes = decryptAndHash(message.copyOfRange(0, M3_STATIC_END))
        remoteStatic = sBytes

        // `se`: shared = responder ephemeral x initiator static.
        mixKey(dh(requireEphemeral(), requireRemoteStatic()))

        val payloadBytes = decryptAndHash(
            message.copyOfRange(M3_STATIC_END, M3_STATIC_END + IdentityPayload.encryptedWireSize)
        )
        val payload = IdentityPayload.parse(payloadBytes)
        if (!verifyPayload(payload, sBytes)) throw NoiseException("Signature verification failed")
        return PeerIdentity(payload.identityKey, sBytes, LinkIdentity.fingerprintFor(payload.identityKey))
    }


    /**
     * Splits into transport cipher states. Direction-agnostic: `send` is
     * always the k1 (initiator→responder) state. The responder must mirror
     * the states when constructing its channel.
     */
    fun split(): TransportKeys {
        val temp = hkdf(ByteArray(0), ck, 64)
        val k1 = temp.copyOfRange(0, 32)
        val k2 = temp.copyOfRange(32, 64)
        val finalHash = sha256(h)
        handshakeHash = finalHash
        val sendState = CipherState()
        sendState.setKey(k1)
        val receiveState = CipherState()
        receiveState.setKey(k2)
        return TransportKeys(sendState, receiveState, finalHash)
    }

    // MARK: - Internals

    private fun ByteArray.publicX25519(): ByteArray {
        // Derive the public key from this private scalar. Constructing
        // X25519PublicKeyParameters(bytes, 0) directly would simply wrap the
        // raw bytes instead of deriving.
        val out = ByteArray(KEY_SIZE)
        X25519PrivateKeyParameters(this, 0).generatePublicKey().encode(out, 0)
        return out
    }

    private fun requireEphemeral(): ByteArray =
        ephemeralKey ?: throw NoiseException("Ephemeral key not set")

    private fun requireRemoteStatic(): ByteArray =
        remoteStatic ?: throw NoiseException("Remote static key not set")

    private fun requireRemoteEphemeral(): ByteArray =
        remoteEphemeral ?: throw NoiseException("Remote ephemeral key not set")

    private fun mixKey(input: ByteArray) {
        val output = hkdf(input, ck, 64)
        ck = output.copyOfRange(0, 32)
        k = output.copyOfRange(32, 64)
        nonce = 0u
        h = sha256(h + output.copyOfRange(32, 64))
    }

    private fun encryptAndHash(plaintext: ByteArray): ByteArray {
        val key = k
        if (key == null) {
            h = sha256(h + plaintext)
            return plaintext
        }
        val ciphertext = encryptWith(plaintext, key, nonce, h)
        nonce += 1u
        h = sha256(h + ciphertext)
        return ciphertext
    }

    private fun decryptAndHash(ciphertext: ByteArray): ByteArray {
        val key = k
        if (key == null) {
            h = sha256(h + ciphertext)
            return ciphertext
        }
        val plaintext = decryptWith(ciphertext, key, nonce, h)
        nonce += 1u
        h = sha256(h + ciphertext)
        return plaintext
    }

    private fun dh(privateKey: ByteArray, publicKey: ByteArray): ByteArray {
        val agreement = X25519Agreement()
        agreement.init(X25519PrivateKeyParameters(privateKey, 0))
        val out = ByteArray(KEY_SIZE)
        agreement.calculateAgreement(X25519PublicKeyParameters(publicKey, 0), out, 0)
        return out
    }

    private fun verifyPayload(payload: IdentityPayload, staticKeyBytes: ByteArray): Boolean {
        return LinkIdentity.verify(payload.identityKey, payload.signature, staticKeyBytes)
    }

    companion object {
        const val PROTOCOL_NAME = "Noise_XX_25519_ChaChaPoly_SHA256"
        const val KEY_SIZE = 32
        private const val M2_STATIC_END = 80
        private const val M3_STATIC_END = 48

        fun sha256(data: ByteArray): ByteArray =
            MessageDigest.getInstance("SHA-256").digest(data)

        /** HKDF-SHA256 (RFC 5869); matches the macOS implementation byte for byte. */
        fun hkdf(ikm: ByteArray, salt: ByteArray, outputLength: Int): ByteArray {
            val saltKey = if (salt.isEmpty()) ByteArray(32) else salt
            val prk = hmacSha256(saltKey, ikm)
            var okm = ByteArray(0)
            var previousBlock = ByteArray(0)
            var counter = 1
            while (okm.size < outputLength) {
                val block = hmacSha256(prk, previousBlock + byteArrayOf(counter.toByte()))
                okm += block
                previousBlock = block
                counter++
            }
            return okm.copyOf(outputLength)
        }

        private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(key, "HmacSHA256"))
            return mac.doFinal(data)
        }

        private fun chacha20Poly1305(encrypting: Boolean, key: ByteArray, nonce: ULong, aad: ByteArray): ChaCha20Poly1305 {
            val cipher = ChaCha20Poly1305()
            cipher.init(encrypting, AEADParameters(KeyParameter(key, 0, key.size), 128, CipherState.nonceBytes(nonce), aad))
            return cipher
        }
    }

    /** One-shot handshake-cipher encrypt (nonce managed externally). */
    private fun encryptWith(plaintext: ByteArray, key: ByteArray, nonce: ULong, aad: ByteArray): ByteArray {
        val cipher = chacha20Poly1305(true, key, nonce, aad)
        val out = ByteArray(plaintext.size + CipherState.TAG_SIZE)
        val written = cipher.processBytes(plaintext, 0, plaintext.size, out, 0)
        cipher.doFinal(out, written)
        return out
    }

    /** One-shot handshake-cipher decrypt (nonce managed externally). */
    private fun decryptWith(ciphertextWithTag: ByteArray, key: ByteArray, nonce: ULong, aad: ByteArray): ByteArray {
        if (ciphertextWithTag.size < CipherState.TAG_SIZE) throw NoiseException("Decrypt failed")
        val cipher = chacha20Poly1305(false, key, nonce, aad)
        // BC may write up to the input length into `out` before the tag check,
        // so the buffer must be input-sized, not plaintext-sized.
        val out = ByteArray(ciphertextWithTag.size)
        val written: Int
        try {
            written = cipher.processBytes(ciphertextWithTag, 0, ciphertextWithTag.size, out, 0)
            val finalized = cipher.doFinal(out, written)
            return out.copyOf(written + finalized)
        } catch (e: Exception) {
            throw NoiseException("Decrypt failed")
        }
    }
}

/** Identity payload on the wire: Ed25519 identity key (32 B) || signature (64 B). */
private class IdentityPayload(val identityKey: ByteArray, val signature: ByteArray) {
    fun encoded(): ByteArray = identityKey + signature

    companion object {
        const val wireSize = 32 + 64
        /** Wire size once AEAD-encrypted (ciphertext || 16-byte tag). */
        const val encryptedWireSize = wireSize + 16

        fun parse(bytes: ByteArray): IdentityPayload {
            if (bytes.size != wireSize) throw NoiseException("Invalid identity payload")
            return IdentityPayload(
                identityKey = bytes.copyOfRange(0, 32),
                signature = bytes.copyOfRange(32, bytes.size)
            )
        }
    }
}
