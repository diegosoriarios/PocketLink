package com.diego.pocketlink.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom

class NoiseHandshakeTests {

    private fun freshStaticKey(): ByteArray {
        val out = ByteArray(32)
        org.bouncycastle.crypto.params.X25519PrivateKeyParameters(SecureRandom()).encode(out, 0)
        return out
    }

    private fun makeHandshakes(): Pair<NoiseHandshake, NoiseHandshake> =
        Pair(NoiseHandshake(freshStaticKey()), NoiseHandshake(freshStaticKey()))

    private fun runHandshake(
        initiator: NoiseHandshake,
        responder: NoiseHandshake,
        initiatorIdentity: LinkIdentity,
        responderIdentity: LinkIdentity
    ): Pair<SecureChannel, SecureChannel> {
        val m1 = initiator.writeM1()
        assertEquals(32, m1.size)
        responder.readM1(m1)

        val m2 = responder.writeM2(responderIdentity)
        assertEquals(80 + 112, m2.size)
        val responderIdentitySeen = initiator.readM2(m2)
        assertEquals(responderIdentity.fingerprint, responderIdentitySeen.fingerprint)

        val m3 = initiator.writeM3(initiatorIdentity)
        assertEquals(48 + 112, m3.size)
        val initiatorIdentitySeen = responder.readM3(m3)
        assertEquals(initiatorIdentity.fingerprint, initiatorIdentitySeen.fingerprint)

        val iKeys = initiator.split()
        val rKeys = responder.split()
        assertTrue(iKeys.handshakeHash.contentEquals(rKeys.handshakeHash))
        assertFalse(iKeys.handshakeHash.isEmpty())

        // split() is direction-agnostic; the responder mirrors the states.
        return Pair(
            SecureChannel(iKeys.send, iKeys.receive, iKeys.handshakeHash),
            SecureChannel(rKeys.receive, rKeys.send, rKeys.handshakeHash)
        )
    }

    @Test
    fun testHandshakeRoundTripAndKeyBinding() {
        val (initiator, responder) = makeHandshakes()
        val initiatorIdentity = LinkIdentity.create()
        val responderIdentity = LinkIdentity.create()
        val (iChannel, rChannel) = runHandshake(initiator, responder, initiatorIdentity, responderIdentity)
        iChannel.seal(ByteArray(16), ByteArray(1))
        rChannel.seal(ByteArray(16), ByteArray(1))
    }

    @Test
    fun testTransportRoundTripBothDirections() {
        val (initiator, responder) = makeHandshakes()
        val (iChannel, rChannel) = runHandshake(
            initiator, responder, LinkIdentity.create(), LinkIdentity.create()
        )

        val headerI = ByteArray(16) { 7 }
        val plaintext = "{\"device\":\"Pixel 8\"}".toByteArray(Charsets.UTF_8)
        val sealed = iChannel.seal(headerI, plaintext)
        assertEquals(plaintext.size + 16, sealed.size)
        assertTrue(rChannel.open(headerI, sealed).contentEquals(plaintext))

        val headerR = ByteArray(16) { 9 }
        val reply = "reply".toByteArray(Charsets.UTF_8)
        assertTrue(iChannel.open(headerR, rChannel.seal(headerR, reply)).contentEquals(reply))

        // Nonces advance: sealing the same payload twice yields different ciphertexts.
        assertNotEquals(iChannel.seal(headerI, plaintext), sealed)
    }

    @Test
    fun testTamperedCiphertextFailsToDecrypt() {
        val (initiator, responder) = makeHandshakes()
        val (iChannel, rChannel) = runHandshake(
            initiator, responder, LinkIdentity.create(), LinkIdentity.create()
        )

        val header = ByteArray(16) { 1 }
        val sealed = iChannel.seal(header, "secret".toByteArray(Charsets.UTF_8))
        assertEquals(22, sealed.size)
        sealed[sealed.size - 20] = (sealed[sealed.size - 20].toInt() xor 0xFF).toByte()
        try {
            rChannel.open(header, sealed)
            throw AssertionError("tampered ciphertext must not decrypt")
        } catch (_: NoiseException) {
        }
    }

    @Test
    fun testTamperedAADFailsToDecrypt() {
        val (initiator, responder) = makeHandshakes()
        val (iChannel, rChannel) = runHandshake(
            initiator, responder, LinkIdentity.create(), LinkIdentity.create()
        )

        val header = ByteArray(16) { 1 }
        val sealed = iChannel.seal(header, "secret".toByteArray(Charsets.UTF_8))
        val tamperedHeader = header.copyOf()
        tamperedHeader[6] = (tamperedHeader[6].toInt() xor 0xFF).toByte()
        try {
            rChannel.open(tamperedHeader, sealed)
            throw AssertionError("tampered AAD must not decrypt")
        } catch (_: NoiseException) {
        }
    }

    @Test
    fun testIdentityBindingVerification() {
        val identity = LinkIdentity.create()
        val staticData = ByteArray(32)
        org.bouncycastle.crypto.params.X25519PrivateKeyParameters(SecureRandom()).encode(staticData, 0)
        val signature = identity.signStaticKey(staticData)

        assertTrue(LinkIdentity.verify(identity.identityPublicKey, signature, staticData))
        // Wrong static key / wrong signer / corrupt signature must all fail.
        assertFalse(LinkIdentity.verify(identity.identityPublicKey, signature, ByteArray(32) { 9 }))
        assertFalse(LinkIdentity.verify(ByteArray(32) { 1 }, signature, staticData))
        val corrupt = signature.copyOf()
        corrupt[0] = (corrupt[0].toInt() xor 0xFF).toByte()
        assertFalse(LinkIdentity.verify(identity.identityPublicKey, corrupt, staticData))
        // A different identity signing the same static key verifies as a valid
        // binding — mismatches are caught by fingerprint pinning, not the signature.
        val other = LinkIdentity.create()
        val otherSignature = other.signStaticKey(staticData)
        assertTrue(LinkIdentity.verify(other.identityPublicKey, otherSignature, staticData))
        assertNotEquals(identity.fingerprint, other.fingerprint)
    }

    @Test
    fun testInterleavedHandshakeMessagesMatchOnBothSides() {
        val (initiator, responder) = makeHandshakes()
        runHandshake(initiator, responder, LinkIdentity.create(), LinkIdentity.create())
        assertTrue(initiator.handshakeHash.contentEquals(responder.handshakeHash))
    }
}

class CipherStateTests {
    @Test
    fun testNonceLayoutMatchesNoiseSpec() {
        val bytes = CipherState.nonceBytes(1u)
        assertEquals(12, bytes.size)
        assertEquals(1, bytes[11].toInt())
        assertTrue(bytes.copyOfRange(0, 11).all { it.toInt() == 0 })

        val high = CipherState.nonceBytes(1uL shl 56)
        assertEquals(1, high[4].toInt())
        assertTrue(high.copyOfRange(0, 4).all { it.toInt() == 0 })
    }

    @Test
    fun testEncryptDecryptRoundTrip() {
        val state = CipherState(ByteArray(32) { 3 })
        val plaintext = "hello".toByteArray(Charsets.UTF_8)
        val sealed = state.encrypt(plaintext, "aad".toByteArray(Charsets.UTF_8))
        assertTrue(state.decrypt(sealed, "aad".toByteArray(Charsets.UTF_8)).contentEquals(plaintext))
    }
}

class LinkIdentityTests {
    @Test
    fun testFingerprintIsStableSha256Hex() {
        val identity = LinkIdentity.create()
        val fingerprint = LinkIdentity.fingerprintFor(identity.identityPublicKey)
        assertEquals(64, fingerprint.length)
        assertEquals(fingerprint.lowercase(), fingerprint)
        assertEquals(fingerprint, identity.fingerprint)
        assertNotEquals(fingerprint, LinkIdentity.create().fingerprint)
    }

    @Test
    fun testSignStaticKeyBindsX25519ToEd25519() {
        val identity = LinkIdentity.create()
        assertEquals(64, identity.signStaticKey(identity.staticPublicKey).size)
    }
}
