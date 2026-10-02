package com.diego.pocketlink.security

/**
 * Post-handshake transport encryption: seals/opens LINK frame payloads with
 * per-direction [CipherState]s, using the 16-byte on-wire frame header as
 * AEAD additional authenticated data. Matches `LinkSecurity.SecureChannel`.
 */
class SecureChannel(
    private var sendState: CipherState,
    private var receiveState: CipherState,
    val handshakeHash: ByteArray
) {
    /**
     * Encrypts a frame payload; returns ciphertext || tag (16 bytes longer
     * than the plaintext, which is what the frame header's length field must
     * say).
     */
    @Throws(NoiseException::class)
    fun seal(header: ByteArray, payload: ByteArray): ByteArray {
        if (header.size != 16) throw NoiseException("Invalid header size")
        return sendState.encrypt(payload, header)
    }

    /** Decrypts a received payload; [header] is the raw 16-byte header as received on the wire. */
    @Throws(NoiseException::class)
    fun open(header: ByteArray, payload: ByteArray): ByteArray {
        if (header.size != 16) throw NoiseException("Invalid header size")
        return receiveState.decrypt(payload, header)
    }
}
