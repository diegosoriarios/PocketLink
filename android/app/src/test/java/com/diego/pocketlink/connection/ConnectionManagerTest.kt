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
}
