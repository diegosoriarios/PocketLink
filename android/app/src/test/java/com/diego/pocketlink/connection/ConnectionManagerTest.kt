package com.diego.pocketlink.connection

import com.diego.pocketlink.protocol.Frame
import com.diego.pocketlink.protocol.FrameHeader
import com.diego.pocketlink.protocol.MessageType
import com.diego.pocketlink.protocol.ProtocolDecoder
import com.diego.pocketlink.protocol.ProtocolEncoder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket

@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionManagerTest {

    private lateinit var testScope: CoroutineScope
    private lateinit var connectionManager: ConnectionManager

    @Before
    fun setUp() {
        testScope = CoroutineScope(Dispatchers.IO)
        connectionManager = ConnectionManager(testScope)
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

        // Connect client socket
        val clientSocket = Socket("127.0.0.1", listeningPort)
        val outStream: OutputStream = clientSocket.getOutputStream()
        val inStream: InputStream = clientSocket.getInputStream()

        // Wait until server updates state to Connected
        state = connectionManager.connectionState.first { it is ConnectionState.Connected }
        assertTrue(state is ConnectionState.Connected)

        // Send PING frame from client
        val pingPayload = """{"timestamp":12345}""".toByteArray(Charsets.UTF_8)
        val pingFrame = Frame(
            header = FrameHeader(
                messageType = MessageType.PING,
                streamId = 99u,
                payloadLength = pingPayload.size.toUInt()
            ),
            payload = pingPayload
        )
        outStream.write(ProtocolEncoder.encode(pingFrame))
        outStream.flush()

        // Read response PONG frame on client
        val decoder = ProtocolDecoder()
        val buffer = ByteArray(1024)
        val readBytes = inStream.read(buffer)
        assertTrue(readBytes > 0)

        val frames = decoder.feed(buffer, 0, readBytes)
        assertEquals(1, frames.size)

        val responseFrame = frames[0]
        assertEquals(MessageType.PONG, responseFrame.header.messageType)
        assertEquals(99u, responseFrame.header.streamId)

        clientSocket.close()
        connectionManager.stopServer()
    }

    @Test
    fun testHandshakeWithMatchingPairingTokenRespondsWithHandshake() = runBlocking {
        ConnectionService.setPendingPairingToken("valid-token-1234567890")

        connectionManager.startServer(0)
        val state = connectionManager.connectionState.first { it is ConnectionState.Listening }
        val listeningPort = (state as ConnectionState.Listening).port

        val clientSocket = Socket("127.0.0.1", listeningPort)
        clientSocket.soTimeout = 2000
        val outStream: OutputStream = clientSocket.getOutputStream()
        val inStream: InputStream = clientSocket.getInputStream()

        connectionManager.connectionState.first { it is ConnectionState.Connected }

        val eventsList = mutableListOf<String>()
        val job = testScope.launch {
            connectionManager.events.collect { eventsList.add(it.message) }
        }

        val handshakePayload = """{"device":"MacBook Pro","platform":"macOS","pairingToken":"valid-token-1234567890"}""".toByteArray(Charsets.UTF_8)
        val handshakeFrame = Frame(
            header = FrameHeader(
                messageType = MessageType.HANDSHAKE,
                streamId = 100u,
                payloadLength = handshakePayload.size.toUInt()
            ),
            payload = handshakePayload
        )
        outStream.write(ProtocolEncoder.encode(handshakeFrame))
        outStream.flush()

        val decoder = ProtocolDecoder()
        val buffer = ByteArray(1024)
        val readBytes = inStream.read(buffer)
        job.cancel()
        assertTrue(readBytes > 0)

        val frames = decoder.feed(buffer, 0, readBytes)
        assertEquals(1, frames.size)

        val responseFrame = frames[0]
        assertEquals(MessageType.HANDSHAKE, responseFrame.header.messageType)
        assertEquals(100u, responseFrame.header.streamId)

        val jsonStr = responseFrame.payload.toString(Charsets.UTF_8)
        assertTrue(jsonStr.contains("valid-token-1234567890"))
        assertTrue(jsonStr.contains("Android"))

        org.junit.Assert.assertNull(ConnectionService.pendingPairingToken)

        clientSocket.close()
        connectionManager.stopServer()
    }
}
