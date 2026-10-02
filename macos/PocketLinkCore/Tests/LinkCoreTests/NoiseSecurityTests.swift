import XCTest

@testable import LinkSecurity
import CryptoKit

final class NoiseHandshakeTests: XCTestCase {

    private func makeHandshakes() throws -> (NoiseHandshake, NoiseHandshake, LinkIdentity, LinkIdentity) {
        let initiator = NoiseHandshake(staticKey: Curve25519.KeyAgreement.PrivateKey())
        let responder = NoiseHandshake(staticKey: Curve25519.KeyAgreement.PrivateKey())
        let initiatorIdentity = LinkIdentity(
            staticKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey()
        )
        let responderIdentity = LinkIdentity(
            staticKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey()
        )
        return (initiator, responder, initiatorIdentity, responderIdentity)
    }

    private func runHandshake(
        _ initiator: inout NoiseHandshake,
        _ responder: inout NoiseHandshake,
        initiatorIdentity: LinkIdentity,
        responderIdentity: LinkIdentity
    ) throws -> (SecureChannel, SecureChannel, NoiseHandshake.InitiatorIdentity, NoiseHandshake.ResponderIdentity) {
        let m1 = try initiator.writeM1()
        XCTAssertEqual(m1.count, 32)
        try responder.readM1(m1)

        let m2 = try responder.writeM2(identity: responderIdentity)
        XCTAssertEqual(m2.count, 80 + 112)
        let responderIdentitySeen = try initiator.readM2(m2)
        XCTAssertEqual(responderIdentitySeen.fingerprint, responderIdentity.fingerprint)

        let m3 = try initiator.writeM3(identity: initiatorIdentity)
        XCTAssertEqual(m3.count, 48 + 112)
        let initiatorIdentitySeen = try responder.readM3(m3)
        XCTAssertEqual(initiatorIdentitySeen.fingerprint, initiatorIdentity.fingerprint)

        let (iSend, iRecv, iHash) = try initiator.split()
        let (rSend, rRecv, rHash) = try responder.split()
        XCTAssertEqual(iHash, rHash)
        XCTAssertFalse(iHash.isEmpty)

        let initiatorChannel = SecureChannel(sendState: iSend, receiveState: iRecv, handshakeHash: iHash)
        // split() is direction-agnostic: k1 = initiator→responder, k2 =
        // responder→initiator. The responder must mirror the states.
        let responderChannel = SecureChannel(sendState: rRecv, receiveState: rSend, handshakeHash: rHash)
        return (initiatorChannel, responderChannel, initiatorIdentitySeen, responderIdentitySeen)
    }

    func testHandshakeRoundTripAndKeyBinding() throws {
        var (initiator, responder, initiatorIdentity, responderIdentity) = try makeHandshakes()
        let (iChannel, rChannel, seenInitiator, seenResponder) = try runHandshake(
            &initiator, &responder,
            initiatorIdentity: initiatorIdentity,
            responderIdentity: responderIdentity
        )

        XCTAssertEqual(seenInitiator.identityKey, initiatorIdentity.signingPublicKeyRaw)
        XCTAssertEqual(seenResponder.identityKey, responderIdentity.signingPublicKeyRaw)
        XCTAssertEqual(seenInitiator.staticKey, initiator.staticKey.publicKey.rawRepresentation)
        _ = iChannel
        _ = rChannel
    }

    func testTransportRoundTripBothDirections() throws {
        var (initiator, responder, initiatorIdentity, responderIdentity) = try makeHandshakes()
        var (iChannel, rChannel, _, _) = try runHandshake(
            &initiator, &responder,
            initiatorIdentity: initiatorIdentity,
            responderIdentity: responderIdentity
        )

        let headerI: [UInt8] = Array(repeating: 7, count: 16)
        let plaintext = Data("{\"device\":\"Pixel 8\"}".utf8)
        let sealed = try iChannel.seal(header: headerI, payload: plaintext)
        XCTAssertEqual(sealed.count, plaintext.count + 16)
        let opened = try rChannel.open(header: headerI, payload: sealed)
        XCTAssertEqual(opened, plaintext)

        let headerR: [UInt8] = Array(repeating: 9, count: 16)
        let reply = Data("reply".utf8)
        let sealedReply = try rChannel.seal(header: headerR, payload: reply)
        XCTAssertEqual(try iChannel.open(header: headerR, payload: sealedReply), reply)

        // Nonces advance: sealing the same payload twice yields different ciphertexts.
        let sealedAgain = try iChannel.seal(header: headerI, payload: plaintext)
        XCTAssertNotEqual(sealedAgain, sealed)
    }

    func testTamperedCiphertextFailsToDecrypt() throws {
        var (initiator, responder, initiatorIdentity, responderIdentity) = try makeHandshakes()
        var (iChannel, rChannel, _, _) = try runHandshake(
            &initiator, &responder,
            initiatorIdentity: initiatorIdentity,
            responderIdentity: responderIdentity
        )

        let header: [UInt8] = Array(repeating: 1, count: 16)
        var sealed = try iChannel.seal(header: header, payload: Data("secret".utf8))
        XCTAssertEqual(sealed.count, 22)
        XCTAssertEqual(sealed.startIndex, 0, "seal() must return a zero-based Data")
        var bytes = [UInt8](sealed)
        bytes[bytes.count - 20] ^= 0xFF
        sealed = Data(bytes)
        XCTAssertThrowsError(try rChannel.open(header: header, payload: sealed))
    }

    func testTamperedAADFailsToDecrypt() throws {
        var (initiator, responder, initiatorIdentity, responderIdentity) = try makeHandshakes()
        var (iChannel, rChannel, _, _) = try runHandshake(
            &initiator, &responder,
            initiatorIdentity: initiatorIdentity,
            responderIdentity: responderIdentity
        )

        let header: [UInt8] = Array(repeating: 1, count: 16)
        let sealed = try iChannel.seal(header: header, payload: Data("secret".utf8))
        var tamperedHeader = header
        tamperedHeader[6] ^= 0xFF
        XCTAssertThrowsError(try rChannel.open(header: tamperedHeader, payload: sealed))
    }

    func testIdentityBindingVerification() throws {
        let identity = LinkIdentity(
            staticKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey()
        )
        let staticData = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let signature = try identity.sign(staticKeyData: staticData)

        XCTAssertTrue(LinkIdentity.verify(identityKeyRaw: identity.signingPublicKeyRaw, signature: signature, signedData: staticData))
        // Wrong static key / wrong signer / corrupt signature must all fail.
        XCTAssertFalse(LinkIdentity.verify(identityKeyRaw: identity.signingPublicKeyRaw, signature: signature, signedData: Data(repeating: 9, count: 32)))
        XCTAssertFalse(LinkIdentity.verify(identityKeyRaw: Data(repeating: 1, count: 32), signature: signature, signedData: staticData))
        var corrupt = signature
        corrupt[0] ^= 0xFF
        XCTAssertFalse(LinkIdentity.verify(identityKeyRaw: identity.signingPublicKeyRaw, signature: corrupt, signedData: staticData))
        // A different identity signing the same static key verifies as a valid
        // binding — mismatches are caught by fingerprint pinning, not the signature.
        let other = LinkIdentity(
            staticKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey()
        )
        let otherSignature = try other.sign(staticKeyData: staticData)
        XCTAssertTrue(LinkIdentity.verify(identityKeyRaw: other.signingPublicKeyRaw, signature: otherSignature, signedData: staticData))
        XCTAssertNotEqual(identity.fingerprint, other.fingerprint)
    }

    func testInterleavedHandshakeMessagesMatchOnBothSides() throws {
        // Same-session determinism: both sides derive identical handshake hash
        // even when identity payloads differ per direction.
        var (initiator, responder, initiatorIdentity, responderIdentity) = try makeHandshakes()
        _ = try runHandshake(
            &initiator, &responder,
            initiatorIdentity: initiatorIdentity,
            responderIdentity: responderIdentity
        )
        XCTAssertEqual(initiator.handshakeHash, responder.handshakeHash)
    }
}

final class CipherStateTests: XCTestCase {
    func testNonceLayoutMatchesNoiseSpec() {
        let bytes = [UInt8](CipherState.nonceBytes(1))
        XCTAssertEqual(bytes.count, 12)
        XCTAssertEqual(bytes[11], 1)
        XCTAssertTrue(bytes.prefix(11).allSatisfy { $0 == 0 })

        let high = [UInt8](CipherState.nonceBytes(UInt64(1) << 56))
        XCTAssertEqual(high[4], 1)
        XCTAssertTrue(high.prefix(4).allSatisfy { $0 == 0 })
    }

    func testEncryptDecryptRoundTrip() throws {
        var state = CipherState(key: SymmetricKey(size: .bits256))
        let plaintext = Data("hello".utf8)
        let sealed = try state.encrypt(plaintext, aad: Data("aad".utf8))
        XCTAssertEqual(try state.decrypt(sealed, aad: Data("aad".utf8)), plaintext)
    }
}
