package com.diego.pocketlink.security

import android.content.Context
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.json.JSONObject
import java.io.File
import java.security.SecureRandom

/**
 * The device's cryptographic identity: an X25519 static key for the Noise
 * handshake and an Ed25519 identity key whose fingerprint is pinned out of
 * band (QR code / trust store).
 *
 * Both private halves persist in app-private storage (`filesDir`). This is
 * comparable to the macOS Keychain storage; a future improvement could wrap
 * the private keys in Android Keystore. Documented gap (C1 scope).
 */
class LinkIdentity private constructor(
    staticPrivateKeyBytes: ByteArray,
    identityPrivateKeyBytes: ByteArray
) {
    val staticPrivateKey = staticPrivateKeyBytes.copyOf()
    val identityPrivateKey = identityPrivateKeyBytes.copyOf()
    val staticPublicKey: ByteArray = x25519Public(staticPrivateKey)
    val identityPublicKey: ByteArray = ed25519Public(identityPrivateKey)

    /** SHA-256 fingerprint (lowercase hex) of the Ed25519 identity key. */
    val fingerprint: String get() = fingerprintFor(identityPublicKey)

    /**
     * Ed25519 signature over the Noise static X25519 public key, binding the
     * two keys together for the handshake identity payload.
     */
    fun signStaticKey(staticKeyBytes: ByteArray): ByteArray {
        val signer = Ed25519Signer()
        signer.init(true, Ed25519PrivateKeyParameters(identityPrivateKey, 0))
        signer.update(staticKeyBytes, 0, staticKeyBytes.size)
        return signer.generateSignature()
    }

    companion object {
        private const val FILE_NAME = "pocketlink-identity.json"

        /** Loads the persisted identity, creating one on first launch (TOFU enrollment). */
        @Synchronized
        fun load(context: Context): LinkIdentity {
            val file = File(context.filesDir, FILE_NAME)
            if (file.exists()) {
                try {
                    val json = JSONObject(file.readText())
                    val staticKey = android.util.Base64.decode(
                        json.getString("staticPrivateKey"),
                        android.util.Base64.NO_WRAP
                    )
                    val identityKey = android.util.Base64.decode(
                        json.getString("identityPrivateKey"),
                        android.util.Base64.NO_WRAP
                    )
                    return LinkIdentity(staticKey, identityKey)
                } catch (_: Exception) {
                    // Fall through and re-enroll on a corrupt identity file.
                }
            }
            val identity = create()
            val json = JSONObject().apply {
                put(
                    "staticPrivateKey",
                    android.util.Base64.encodeToString(identity.staticPrivateKey, android.util.Base64.NO_WRAP)
                )
                put(
                    "identityPrivateKey",
                    android.util.Base64.encodeToString(identity.identityPrivateKey, android.util.Base64.NO_WRAP)
                )
            }
            file.parentFile?.mkdirs()
            file.writeText(json.toString())
            return identity
        }

        /** Creates a fresh identity without persisting it (tests, tooling). */
        fun create(random: SecureRandom = SecureRandom()): LinkIdentity {
            val staticKey = ByteArray(32)
            X25519PrivateKeyParameters(random).encode(staticKey, 0)
            val identityKey = ByteArray(Ed25519PrivateKeyParameters.KEY_SIZE)
            Ed25519PrivateKeyParameters(random).encode(identityKey, 0)
            return LinkIdentity(staticKey, identityKey)
        }

        /** SHA-256 fingerprint of an Ed25519 identity public key, lowercase hex. */
        fun fingerprintFor(identityKeyRaw: ByteArray): String {
            val digest = NoiseHandshake.sha256(identityKeyRaw)
            return digest.joinToString("") { "%02x".format(it) }
        }

        /** Ed25519 signature verification of the identity↔static binding. */
        fun verify(identityKeyRaw: ByteArray, signature: ByteArray, signedData: ByteArray): Boolean {
            return try {
                if (identityKeyRaw.size != 32) return false
                val verifier = Ed25519Signer()
                verifier.init(false, Ed25519PublicKeyParameters(identityKeyRaw, 0))
                verifier.update(signedData, 0, signedData.size)
                verifier.verifySignature(signature)
            } catch (_: Exception) {
                false
            }
        }

        private fun x25519Public(privateKeyBytes: ByteArray): ByteArray {
            val out = ByteArray(32)
            X25519PrivateKeyParameters(privateKeyBytes, 0).generatePublicKey().encode(out, 0)
            return out
        }

        private fun ed25519Public(privateKeyBytes: ByteArray): ByteArray =
            Ed25519PrivateKeyParameters(privateKeyBytes, 0).generatePublicKey().getEncoded()
    }
}
