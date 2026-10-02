package com.diego.pocketlink.connection

import com.diego.pocketlink.protocol.Frame
import com.diego.pocketlink.protocol.FrameHeader
import com.diego.pocketlink.protocol.MessageType
import com.diego.pocketlink.protocol.ProtocolConstants
import com.diego.pocketlink.protocol.ProtocolDecoder
import com.diego.pocketlink.protocol.ProtocolEncoder
import com.diego.pocketlink.security.LinkIdentity
import com.diego.pocketlink.security.NoiseHandshake
import com.diego.pocketlink.security.SecureChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Test-side stand-in for the macOS initiator: performs the Noise XX
 * handshake, then exchanges sealed frames exactly like `LinkClient`.
 */
private class CryptoTestClient(private val socket: Socket) {
    private val identity = LinkIdentity.create()
    private val handshake = NoiseHandshake(identity.staticPrivateKey)
    private var channel: SecureChannel? = null
    private val decoder = ProtocolDecoder()
    private val rawQueue = ArrayDeque<Frame>()

    fun performHandshake(out: OutputStream) {
        socket.soTimeout = 5000
        val m1 = handshake.writeM1()
        out.write(rawEncoded(MessageType.CRYPTO_M1, m1))
        out.flush()

        val m2 = receiveRaw()
            ?: throw AssertionError("no CRYPTO_M2 received")
        assertEquals(MessageType.CRYPTO_M2, m2.header.messageType)
        handshake.readM2(m2.payload)

        val m3 = handshake.writeM3(identity)
        out.write(rawEncoded(MessageType.CRYPTO_M3, m3))
        out.flush()

        val keys = handshake.split()
        channel = SecureChannel(keys.send, keys.receive, keys.handshakeHash)
    }

    fun send(frame: Frame, out: OutputStream) {
        val active = channel ?: throw AssertionError("channel not established")
        val header = wireHeader(frame.header.version, frame.header.messageType, frame.header.streamId, frame.payload.size + 16)
        out.write(header + active.seal(header, frame.payload))
        out.flush()
    }

    /** Reads encrypted frames from the socket (blocking until at least one frame). */
    fun receiveFrames(): List<Frame> {
        val received = mutableListOf<Frame>()
        while (received.isEmpty()) {
            val raw = receiveRaw() ?: break
            val active = channel
            if (active == null || raw.header.messageType.isCryptoHandshake) {
                received.add(raw)
                continue
            }
            val header = wireHeader(raw.header.version, raw.header.messageType, raw.header.streamId, raw.payload.size)
            val plain = active.open(header, raw.payload)
            received.add(
                Frame(
                    header = FrameHeader(
                        version = raw.header.version,
                        messageType = raw.header.messageType,
                        streamId = raw.header.streamId,
                        payloadLength = plain.size.toUInt()
                    ),
                    payload = plain
                )
            )
        }
        return received
    }

    /** Reads frames from the socket without decrypting (blocking until at least one frame). */
    fun receiveRawFrames(): List<Frame> {
        val received = mutableListOf<Frame>()
        while (received.isEmpty()) {
            val raw = receiveRaw() ?: break
            received.add(raw)
        }
        return received
    }

    private fun receiveRaw(): Frame? {
        if (rawQueue.isNotEmpty()) return rawQueue.removeFirst()
        val buffer = ByteArray(8192)
        val input: InputStream = socket.getInputStream()
        while (rawQueue.isEmpty()) {
            val read = input.read(buffer)
            if (read == -1) return null
            rawQueue.addAll(decoder.feed(buffer, 0, read))
        }
        return rawQueue.removeFirst()
    }

    private fun rawEncoded(type: MessageType, payload: ByteArray): ByteArray =
        ProtocolEncoder.encode(
            Frame(
                header = FrameHeader(
                    messageType = type,
                    streamId = 0u,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
        )

    companion object {
        fun wireHeader(version: UShort, messageType: MessageType, streamId: UInt, payloadLength: Int): ByteArray {
            val buffer = ByteBuffer.allocate(ProtocolConstants.HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
            buffer.put(ProtocolConstants.MAGIC_BYTES)
            buffer.putShort(version.toShort())
            buffer.putShort(messageType.id.toShort())
            buffer.putInt(streamId.toInt())
            buffer.putInt(payloadLength)
            return buffer.array()
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionManagerTest {

    private lateinit var testScope: CoroutineScope
    private lateinit var connectionManager: ConnectionManager

    @Before
    fun setUp() {
        testScope = CoroutineScope(Dispatchers.IO)
        connectionManager = ConnectionManager(testScope, LinkIdentity.create())
    }

    @After
    fun tearDown() {
        connectionManager.stopServer()
    }

    @Test
    fun testServerStartAndPingPongExchange() = runBlocking {
        // Start server on free port (0 picks an available system port)
        connectionManager.startServer(0)

        // Wait until server is listening
        var state = connectionManager.connectionState.first { it is ConnectionState.Listening }
        val listeningPort = (state as ConnectionState.Listening).port
        assertTrue(listeningPort > 0)

        // Connect client socket and run the Noise handshake
        val clientSocket = Socket("127.0.0.1", listeningPort)
        val client = CryptoTestClient(clientSocket)
        val outStream = clientSocket.getOutputStream()

        // Wait until server updates state to Connected
        state = connectionManager.connectionState.first { it is ConnectionState.Connected }
        assertTrue(state is ConnectionState.Connected)

        client.performHandshake(outStream)

        // Send PING frame from client
        val pingPayload = """{"timestamp":12345}""".toByteArray(Charsets.UTF_8)
        client.send(
            Frame(
                header = FrameHeader(
                    messageType = MessageType.PING,
                    streamId = 99u,
                    payloadLength = pingPayload.size.toUInt()
                ),
                payload = pingPayload
            ),
            outStream
        )

        // Read response PONG frame on client
        val frames = client.receiveFrames()
        assertEquals(1, frames.size)

        val responseFrame = frames[0]
        assertEquals(MessageType.PONG, responseFrame.header.messageType)
        assertEquals(99u, responseFrame.header.streamId)
        assertTrue(responseFrame.payload.contentEquals(pingPayload))

        clientSocket.close()
        connectionManager.stopServer()
    }

    @Test
    fun testFingerprintPinMismatchRejectsHandshake() = runBlocking {
        ConnectionService.setPendingPairingToken(
            QrPairing(token = "pin-token-12345678901", identityFingerprint = "ab".repeat(32))
        )

        connectionManager.startServer(0)
        val state = connectionManager.connectionState.first { it is ConnectionState.Listening }
        val listeningPort = (state as ConnectionState.Listening).port

        val clientSocket = Socket("127.0.0.1", listeningPort)
        val client = CryptoTestClient(clientSocket)
        val outStream = clientSocket.getOutputStream()

        connectionManager.connectionState.first { it is ConnectionState.Connected }

        // Handshake completes on the crypto layer, but the M3 peer identity
        // does not match the QR-pinned fingerprint -> rejected.
        client.performHandshake(outStream)

        val frames = client.receiveRawFrames()
        assertEquals(1, frames.size)
        val errorFrame = frames[0]
        assertEquals(MessageType.ERROR, errorFrame.header.messageType)
        val jsonStr = errorFrame.payload.toString(Charsets.UTF_8)
        assertTrue(jsonStr.contains("\"code\":403"))
        assertTrue(jsonStr.contains("pairing code"))

        clientSocket.close()
        connectionManager.stopServer()
    }

    @Test
    fun testHandshakeWithMatchingPairingTokenRespondsWithHandshake() = runBlocking {
        ConnectionService.setPendingPairingToken(QrPairing(token = "valid-token-1234567890", identityFingerprint = null))

        connectionManager.startServer(0)
        val state = connectionManager.connectionState.first { it is ConnectionState.Listening }
        val listeningPort = (state as ConnectionState.Listening).port

        val clientSocket = Socket("127.0.0.1", listeningPort)
        val client = CryptoTestClient(clientSocket)
        val outStream = clientSocket.getOutputStream()

        connectionManager.connectionState.first { it is ConnectionState.Connected }

        val eventsList = mutableListOf<String>()
        val job = testScope.launch {
            connectionManager.events.collect { eventsList.add(it.message) }
        }

        client.performHandshake(outStream)

        val handshakePayload = """{"device":"MacBook Pro","platform":"macOS","pairingToken":"valid-token-1234567890","protocolVersion":2}""".toByteArray(Charsets.UTF_8)
        client.send(
            Frame(
                header = FrameHeader(
                    messageType = MessageType.HANDSHAKE,
                    streamId = 100u,
                    payloadLength = handshakePayload.size.toUInt()
                ),
                payload = handshakePayload
            ),
            outStream
        )

        val frames = client.receiveFrames()
        job.cancel()
        assertEquals(1, frames.size)

        val responseFrame = frames[0]
        assertEquals(MessageType.HANDSHAKE, responseFrame.header.messageType)
        assertEquals(100u, responseFrame.header.streamId)

        val jsonStr = responseFrame.payload.toString(Charsets.UTF_8)
        assertTrue(jsonStr.contains("valid-token-1234567890"))
        assertTrue(jsonStr.contains("Android"))
        assertTrue(jsonStr.contains("\"protocolVersion\":2"))

        org.junit.Assert.assertNull(ConnectionService.pendingPairingToken)

        clientSocket.close()
        connectionManager.stopServer()
    }
}
