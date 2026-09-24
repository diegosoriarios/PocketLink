package com.diego.pocketlink.connection

import com.diego.pocketlink.battery.BatteryStatus
import com.diego.pocketlink.files.FileTransferEngine
import com.diego.pocketlink.notifications.ForwardedNotification
import com.diego.pocketlink.protocol.Frame
import com.diego.pocketlink.protocol.FrameHeader
import com.diego.pocketlink.protocol.FrameOversizedException
import com.diego.pocketlink.protocol.InvalidFrameException
import com.diego.pocketlink.protocol.MessageType
import com.diego.pocketlink.protocol.ProtocolDecoder
import com.diego.pocketlink.protocol.ProtocolEncoder
import com.diego.pocketlink.protocol.ProtocolException
import com.diego.pocketlink.protocol.UnknownMessageTypeException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicInteger

class ConnectionManager(
    private val scope: CoroutineScope
) {
    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _events = MutableSharedFlow<ConnectionEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<ConnectionEvent> = _events.asSharedFlow()

    private val streamIdCounter = AtomicInteger(1)

    private var serverSocket: ServerSocket? = null
    private var activeSocket: Socket? = null
    private var serverJob: Job? = null
    private var clientJob: Job? = null

    var onRemoteClipboardReceived: ((String) -> Unit)? = null
    var onNotificationReplyReceived: ((id: String, text: String) -> Unit)? = null
    var fileTransferEngine: FileTransferEngine? = null

    fun sendRawFrame(typeId: Int, payload: ByteArray): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        val msgType = MessageType.fromId(typeId.toUShort()) ?: return false
        val streamId = streamIdCounter.getAndIncrement().toUInt()
        val frame = Frame(
            header = FrameHeader(
                messageType = msgType,
                streamId = streamId,
                payloadLength = payload.size.toUInt()
            ),
            payload = payload
        )

        return runBlocking(Dispatchers.IO) {
            sendFrameOnSocket(socket, frame)
        }
    }

    fun startServer(port: Int = DEFAULT_PORT) {
        if (serverJob != null && serverJob?.isActive == true) return

        serverJob = scope.launch(Dispatchers.IO) {
            try {
                val ss = ServerSocket(port)
                serverSocket = ss
                val localIps = NetworkUtils.getLocalIpAddresses()
                _connectionState.value = ConnectionState.Listening(ss.localPort, localIps)
                logEvent("TCP Server started on port ${ss.localPort}")

                while (isActive && !ss.isClosed) {
                    try {
                        val clientSocket = ss.accept()
                        handleClient(clientSocket)
                    } catch (e: SocketException) {
                        if (!ss.isClosed) {
                            logEvent("Socket exception accepting connection: ${e.message}")
                        }
                    }
                }
            } catch (e: Exception) {
                logEvent("Failed to start server: ${e.message}")
                _connectionState.value = ConnectionState.Error(e.message ?: "Server error")
            } finally {
                stopServerInternal()
            }
        }
    }

    fun connectToHost(host: String, port: Int) {
        if (activeSocket != null && activeSocket?.isClosed == false) {
            logEvent("Already connected to ${activeSocket?.remoteSocketAddress}")
            return
        }

        clientJob?.cancel()
        clientJob = scope.launch(Dispatchers.IO) {
            try {
                logEvent("Connecting to $host:$port...")
                val socket = Socket()
                socket.connect(InetSocketAddress(host, port), 5000)
                handleClient(socket)
            } catch (e: Exception) {
                logEvent("Failed to connect to $host:$port: ${e.message}")
                _connectionState.value = ConnectionState.Error("Connection failed: ${e.message}")
            }
        }
    }

    private suspend fun handleClient(socket: Socket) {
        activeSocket = socket
        val remoteAddr = socket.remoteSocketAddress?.toString() ?: "Unknown"
        _connectionState.value = ConnectionState.Connected(remoteAddr, socket.localPort)
        logEvent("Connected to remote endpoint $remoteAddr")

        val decoder = ProtocolDecoder()
        val buffer = ByteArray(8192)

        try {
            val inputStream: InputStream = socket.getInputStream()
            while (scope.isActive && !socket.isClosed) {
                val bytesRead = inputStream.read(buffer)
                if (bytesRead == -1) {
                    logEvent("Remote endpoint disconnected ($remoteAddr)")
                    break
                }

                try {
                    val frames = decoder.feed(buffer, 0, bytesRead)
                    for (frame in frames) {
                        handleReceivedFrame(socket, frame)
                    }
                } catch (e: ProtocolException) {
                    when (e) {
                        is InvalidFrameException -> {
                            logEvent("Rejected malformed frame: ${e.message}")
                            sendErrorFrame(socket, 400, "Invalid frame header or magic bytes")
                            socket.close()
                            break
                        }
                        is FrameOversizedException -> {
                            logEvent("Rejected oversized frame: ${e.message}")
                            sendErrorFrame(socket, 413, "Frame payload exceeds maximum size")
                        }
                        is UnknownMessageTypeException -> {
                            logEvent("Received unknown message type ID: 0x${e.typeId.toString(16)}")
                            sendErrorFrame(socket, 400, "Unknown message type")
                        }
                    }
                }
            }
        } catch (e: Exception) {
            logEvent("Connection error with $remoteAddr: ${e.message}")
        } finally {
            try {
                socket.close()
            } catch (_: Exception) {}
            activeSocket = null

            // Revert back to Listening if server is still active
            val currentServer = serverSocket
            if (currentServer != null && !currentServer.isClosed) {
                val localIps = NetworkUtils.getLocalIpAddresses()
                _connectionState.value = ConnectionState.Listening(currentServer.localPort, localIps)
            } else {
                _connectionState.value = ConnectionState.Disconnected
            }
        }
    }

    private suspend fun handleReceivedFrame(socket: Socket, frame: Frame) {
        when (frame.header.messageType) {
            MessageType.PING -> {
                logEvent("Received PING frame (Stream ID ${frame.header.streamId})")
                val pongFrame = Frame(
                    header = FrameHeader(
                        messageType = MessageType.PONG,
                        streamId = frame.header.streamId,
                        payloadLength = frame.payload.size.toUInt()
                    ),
                    payload = frame.payload
                )
                sendFrameOnSocket(socket, pongFrame)
                logEvent("Sent PONG response frame (Stream ID ${frame.header.streamId})")
            }
            MessageType.PONG -> {
                logEvent("Received PONG frame (Stream ID ${frame.header.streamId})")
            }
            MessageType.CLIPBOARD -> {
                try {
                    val jsonStr = frame.payload.toString(Charsets.UTF_8)
                    val json = JSONObject(jsonStr)
                    val text = json.optString("text")
                    if (text.isNotEmpty()) {
                        logEvent("Received remote clipboard payload (${text.length} chars)")
                        onRemoteClipboardReceived?.invoke(text)
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse CLIPBOARD payload: ${e.message}")
                }
            }
            MessageType.BATTERY -> {
                try {
                    val jsonStr = frame.payload.toString(Charsets.UTF_8)
                    val json = JSONObject(jsonStr)
                    val level = json.optInt("level", -1)
                    val isCharging = json.optBoolean("isCharging", false)
                    val powerSave = json.optBoolean("powerSave", false)
                    logEvent("Received remote battery update: $level% (Charging: $isCharging, PowerSave: $powerSave)")
                } catch (e: Exception) {
                    logEvent("Failed to parse BATTERY payload: ${e.message}")
                }
            }
            MessageType.NOTIFICATION_REPLY -> {
                try {
                    val jsonStr = frame.payload.toString(Charsets.UTF_8)
                    val json = JSONObject(jsonStr)
                    val id = json.optString("id")
                    val text = json.optString("text")
                    if (id.isNotBlank() && text.isNotBlank()) {
                        logEvent("Received NOTIFICATION_REPLY frame (id: $id)")
                        onNotificationReplyReceived?.invoke(id, text)
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse NOTIFICATION_REPLY payload: ${e.message}")
                }
            }
            MessageType.FILE_HEADER -> {
                val jsonStr = frame.payload.toString(Charsets.UTF_8)
                logEvent("Received FILE_HEADER frame")
                fileTransferEngine?.handleIncomingHeader(jsonStr)
            }
            MessageType.FILE_CHUNK -> {
                fileTransferEngine?.handleIncomingChunk(frame.payload)
            }
            MessageType.FILE_CANCEL -> {
                val jsonStr = frame.payload.toString(Charsets.UTF_8)
                logEvent("Received FILE_CANCEL frame")
                fileTransferEngine?.handleIncomingCancel(jsonStr)
            }
            MessageType.FILE_ACK -> {
                val jsonStr = frame.payload.toString(Charsets.UTF_8)
                val json = JSONObject(jsonStr)
                val status = json.optString("status")
                logEvent("Received FILE_ACK frame (Status: $status)")
            }
            MessageType.HANDSHAKE -> {
                val body = frame.payload.toString(Charsets.UTF_8)
                val json = try {
                    JSONObject(body)
                } catch (_: Exception) {
                    null
                }
                val deviceName = json?.optString("device")?.takeIf { it.isNotBlank() } ?: "Unknown"
                val incomingToken = json?.optString("pairingToken")?.takeIf { it.isNotBlank() }

                val pending = ConnectionService.pendingPairingToken
                val now = System.currentTimeMillis()

                if (pending != null && !pending.isExpired(now) && incomingToken != null && incomingToken == pending.value) {
                    logEvent("Paired via QR with $deviceName")
                    ConnectionService.clearPendingPairingToken()

                    val localDeviceName = try {
                        Class.forName("android.os.Build").getField("MODEL").get(null) as? String
                    } catch (_: Throwable) {
                        null
                    } ?: "Android"

                    val responseJson = JSONObject().apply {
                        put("device", localDeviceName)
                        put("platform", "Android")
                        put("pairingToken", pending.value)
                    }
                    val payload = responseJson.toString().toByteArray(Charsets.UTF_8)
                    val responseFrame = Frame(
                        header = FrameHeader(
                            messageType = MessageType.HANDSHAKE,
                            streamId = frame.header.streamId,
                            payloadLength = payload.size.toUInt()
                        ),
                        payload = payload
                    )
                    sendFrameOnSocket(socket, responseFrame)
                } else {
                    logEvent("Received HANDSHAKE: $body")
                }
            }
            else -> {
                logEvent("Received ${frame.header.messageType} frame (${frame.payload.size} bytes)")
            }
        }
    }

    fun sendNotification(notification: ForwardedNotification): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        scope.launch(Dispatchers.IO) {
            val json = JSONObject().apply {
                put("id", notification.id)
                put("packageName", notification.packageName)
                put("appName", notification.appName)
                put("title", notification.title)
                put("text", notification.text)
                put("postTime", notification.postTime)
                put("hasQuickReply", notification.hasQuickReply)
            }
            val payload = json.toString().toByteArray(Charsets.UTF_8)
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.NOTIFICATION,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            val success = sendFrameOnSocket(socket, frame)
            if (success) {
                logEvent("Forwarded NOTIFICATION from ${notification.appName} (${notification.packageName})")
            }
        }
        return true
    }

    fun sendClipboard(text: String): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed || text.isEmpty()) return false

        scope.launch(Dispatchers.IO) {
            val json = JSONObject().apply {
                put("text", text)
                put("timestamp", System.currentTimeMillis())
            }
            val payload = json.toString().toByteArray(Charsets.UTF_8)
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.CLIPBOARD,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            val success = sendFrameOnSocket(socket, frame)
            if (success) {
                logEvent("Sent CLIPBOARD frame (${text.length} chars)")
            } else {
                logEvent("Failed to send CLIPBOARD frame")
            }
        }
        return true
    }

    fun sendBatteryStatus(status: BatteryStatus): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        scope.launch(Dispatchers.IO) {
            val json = JSONObject().apply {
                put("level", status.level)
                put("isCharging", status.isCharging)
                put("powerSave", status.powerSaveMode)
                put("timestamp", System.currentTimeMillis())
            }
            val payload = json.toString().toByteArray(Charsets.UTF_8)
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.BATTERY,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            val success = sendFrameOnSocket(socket, frame)
            if (success) {
                logEvent("Sent BATTERY frame (${status.level}%, Charging=${status.isCharging})")
            }
        }
        return true
    }

    fun sendPing(): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        scope.launch(Dispatchers.IO) {
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val payload = """{"timestamp":${System.currentTimeMillis()}}""".toByteArray(Charsets.UTF_8)
            val pingFrame = Frame(
                header = FrameHeader(
                    messageType = MessageType.PING,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            val success = sendFrameOnSocket(socket, pingFrame)
            if (success) {
                logEvent("Sent PING frame (Stream ID $streamId)")
            } else {
                logEvent("Failed to send PING frame")
            }
        }
        return true
    }

    private suspend fun sendErrorFrame(socket: Socket, code: Int, message: String) {
        val payload = """{"code":$code,"message":"$message"}""".toByteArray(Charsets.UTF_8)
        val frame = Frame(
            header = FrameHeader(
                messageType = MessageType.ERROR,
                streamId = 0u,
                payloadLength = payload.size.toUInt()
            ),
            payload = payload
        )
        sendFrameOnSocket(socket, frame)
    }

    private suspend fun sendFrameOnSocket(socket: Socket, frame: Frame): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val encoded = ProtocolEncoder.encode(frame)
                val outputStream: OutputStream = socket.getOutputStream()
                outputStream.write(encoded)
                outputStream.flush()
                true
            } catch (e: Exception) {
                logEvent("Failed to write frame to socket: ${e.message}")
                false
            }
        }
    }

    fun stopServer() {
        scope.launch(Dispatchers.IO) {
            stopServerInternal()
        }
    }

    private fun stopServerInternal() {
        try {
            activeSocket?.close()
        } catch (_: Exception) {}
        activeSocket = null

        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        serverSocket = null

        serverJob?.cancel()
        serverJob = null
        clientJob?.cancel()
        clientJob = null

        _connectionState.value = ConnectionState.Disconnected
        logEvent("Connection service stopped")
    }

    private fun logEvent(msg: String) {
        _events.tryEmit(ConnectionEvent(message = msg))
    }

    companion object {
        const val DEFAULT_PORT = 52345
    }
}
