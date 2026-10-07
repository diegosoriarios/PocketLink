package com.diego.pocketlink.connection

import com.diego.pocketlink.battery.BatteryStatus
import com.diego.pocketlink.files.FileTransferEngine
import com.diego.pocketlink.notifications.ForwardedNotification
import com.diego.pocketlink.protocol.Frame
import com.diego.pocketlink.protocol.FrameHeader
import com.diego.pocketlink.protocol.FrameOversizedException
import com.diego.pocketlink.protocol.InvalidFrameException
import com.diego.pocketlink.protocol.MessageType
import com.diego.pocketlink.protocol.MirrorProtocol
import com.diego.pocketlink.protocol.ProtocolDecoder
import com.diego.pocketlink.protocol.ProtocolEncoder
import com.diego.pocketlink.protocol.ProtocolConstants
import com.diego.pocketlink.protocol.ProtocolException
import com.diego.pocketlink.protocol.UnsupportedVersionException
import com.diego.pocketlink.protocol.UnknownMessageTypeException
import com.diego.pocketlink.security.LinkIdentity
import com.diego.pocketlink.security.NoiseException
import com.diego.pocketlink.security.NoiseHandshake
import com.diego.pocketlink.security.SecureChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger

class ConnectionManager(
    private val scope: CoroutineScope,
    private val identity: LinkIdentity
) {
    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _events = MutableSharedFlow<ConnectionEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<ConnectionEvent> = _events.asSharedFlow()

    private val streamIdCounter = AtomicInteger(1)
    private val writeMutex = Mutex()

    // Encrypted transport state (one Noise session per connection).
    private var noiseHandshake: NoiseHandshake? = null
    @Volatile
    private var channel: SecureChannel? = null
    @Volatile
    var peerFingerprint: String? = null
        private set
    private val pendingOutbound = ArrayDeque<Frame>()
    private val pendingOutboundLock = Any()

    private var serverSocket: ServerSocket? = null
    private var activeSocket: Socket? = null
    private var serverJob: Job? = null
    private var clientJob: Job? = null
    private var heartbeatJob: Job? = null

    @Volatile
    private var awaitingPong = false

    var onRemoteClipboardReceived: ((String) -> Unit)? = null
    var onNotificationReplyReceived: ((id: String, text: String) -> Unit)? = null
    var onNotificationActionReceived: ((id: String, action: String) -> Unit)? = null
    var onMirrorStartRequested: (() -> Unit)? = null
    var onMirrorStopRequested: (() -> Unit)? = null
    var onRemoteTouchReceived: ((action: String, x: Double, y: Double) -> Unit)? = null
    var onRemoteTextReceived: ((text: String?, special: String?) -> Unit)? = null
    var onOpenUrlReceived: ((url: String) -> Unit)? = null
    var fileTransferEngine: FileTransferEngine? = null

    private var pendingClipboardAckTimestamp: Long = -1
    private var clipboardAckTimeoutJob: Job? = null

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

        // Every connection starts a fresh Noise XX session; the remote peer
        // (macOS) is the initiator.
        noiseHandshake = NoiseHandshake(identity.staticPrivateKey)
        channel = null
        peerFingerprint = null
        synchronized(pendingOutboundLock) { pendingOutbound.clear() }

        awaitingPong = false
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch { runHeartbeat(socket) }

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
                        if (frame.header.messageType.isCryptoHandshake) {
                            if (channel == null) {
                                if (!handleCryptoFrame(socket, frame)) {
                                    socket.close()
                                    return
                                }
                            }
                            // Crypto frames after the handshake: ignored.
                            continue
                        }
                        val activeChannel = channel
                        if (activeChannel == null) {
                            logEvent("Rejected plaintext frame before encrypted channel was established")
                            sendErrorFrame(socket, 409, "Encrypted transport required")
                            socket.close()
                            return
                        }
                        val header = wireHeaderBytes(
                            version = frame.header.version,
                            messageType = frame.header.messageType,
                            streamId = frame.header.streamId,
                            payloadLength = frame.payload.size
                        )
                        val plaintext: ByteArray = try {
                            activeChannel.open(header, frame.payload)
                        } catch (e: NoiseException) {
                            logEvent("Payload decryption failed: ${e.message}")
                            channel = null
                            sendErrorFrame(socket, 401, "Decryption failed")
                            socket.close()
                            return
                        }
                        val decrypted = Frame(
                            header = FrameHeader(
                                version = frame.header.version,
                                messageType = frame.header.messageType,
                                streamId = frame.header.streamId,
                                payloadLength = plaintext.size.toUInt()
                            ),
                            payload = plaintext
                        )
                        handleReceivedFrame(socket, decrypted)
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
                        is UnsupportedVersionException -> {
                            logEvent("Rejected frame with unsupported version: ${e.received.toInt()}")
                            sendErrorFrame(
                                socket,
                                409,
                                "Protocol version mismatch: peer sent ${e.received.toInt()}, expected ${ProtocolConstants.PROTOCOL_VERSION.toInt()}"
                            )
                            socket.close()
                            break
                        }
                    }
                }
            }
        } catch (e: Exception) {
            logEvent("Connection error with $remoteAddr: ${e.message}")
        } finally {
            heartbeatJob?.cancel()
            heartbeatJob = null
            channel = null
            noiseHandshake = null
            synchronized(pendingOutboundLock) { pendingOutbound.clear() }
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

    /**
     * Drives the responder side of the Noise XX handshake. Returns false on
     * protocol violations (wrong order, oversized, crypto failure).
     */
    private suspend fun handleCryptoFrame(socket: Socket, frame: Frame): Boolean {
        val handshake = noiseHandshake ?: return false
        when (frame.header.messageType) {
            MessageType.CRYPTO_M1 -> {
                return try {
                    handshake.readM1(frame.payload)
                    val m2 = handshake.writeM2(identity)
                    sendFrameOnSocket(
                        socket,
                        Frame(
                            header = FrameHeader(
                                messageType = MessageType.CRYPTO_M2,
                                streamId = 0u,
                                payloadLength = m2.size.toUInt()
                            ),
                            payload = m2
                        )
                    )
                    true
                } catch (e: NoiseException) {
                    logEvent("Noise M1 processing failed: ${e.message}")
                    false
                }
            }
            MessageType.CRYPTO_M3 -> {
                return try {
                    val peer = handshake.readM3(frame.payload)

                    // If the phone scanned a Mac QR, the QR's `k` field pins the
                    // expected peer fingerprint (trust on first use out of band).
                    val expectedFingerprint = ConnectionService.pendingPairingToken?.identityFingerprint
                    if (expectedFingerprint != null && !expectedFingerprint.equals(peer.fingerprint, ignoreCase = true)) {
                        logEvent(
                            "Peer fingerprint mismatch: QR pinned ${expectedFingerprint.take(16)}…, " +
                                "received ${peer.fingerprint.take(16)}…"
                        )
                        sendErrorFrame(socket, 403, "Device identity does not match the scanned pairing code")
                        return false
                    }

                    peerFingerprint = peer.fingerprint
                    val keys = handshake.split()
                    // split() is direction-agnostic (k1 = initiator→responder,
                    // k2 = responder→initiator); the responder mirrors the states.
                    channel = SecureChannel(keys.receive, keys.send, keys.handshakeHash)
                    logEvent("Encrypted channel established (peer fingerprint ${peer.fingerprint.take(16)}…)")
                    flushPendingOutbound(socket)
                    true
                } catch (e: NoiseException) {
                    logEvent("Noise M3 processing failed: ${e.message}")
                    false
                }
            }
            else -> {
                logEvent("Unexpected crypto message ${frame.header.messageType}")
                return false
            }
        }
    }

    private suspend fun flushPendingOutbound(socket: Socket) {
        val queued: List<Frame> = synchronized(pendingOutboundLock) {
            val out = pendingOutbound.toList()
            pendingOutbound.clear()
            out
        }
        for (frame in queued) {
            sendFrameOnSocket(socket, frame)
        }
        if (queued.isNotEmpty()) {
            logEvent("Flushed ${queued.size} buffered frame(s) after handshake")
        }
    }

    private fun wireHeaderBytes(
        version: UShort,
        messageType: MessageType,
        streamId: UInt,
        payloadLength: Int
    ): ByteArray {
        val buffer = ByteBuffer.allocate(ProtocolConstants.HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
        buffer.put(ProtocolConstants.MAGIC_BYTES)
        buffer.putShort(version.toShort())
        buffer.putShort(messageType.id.toShort())
        buffer.putInt(streamId.toInt())
        buffer.putInt(payloadLength)
        return buffer.array()
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
                awaitingPong = false
            }
            MessageType.CLIPBOARD -> {
                try {
                    val jsonStr = frame.payload.toString(Charsets.UTF_8)
                    val json = JSONObject(jsonStr)
                    val text = json.optString("text")
                    if (text.isNotEmpty()) {
                        logEvent("Received remote clipboard payload (${text.length} chars)")
                        onRemoteClipboardReceived?.invoke(text)
                        sendClipboardAck(json.optLong("timestamp", 0L))
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse CLIPBOARD payload: ${e.message}")
                }
            }
            MessageType.CLIPBOARD_ACK -> {
                try {
                    val jsonStr = frame.payload.toString(Charsets.UTF_8)
                    val json = JSONObject(jsonStr)
                    val timestamp = json.optLong("timestamp", -1L)
                    if (timestamp == pendingClipboardAckTimestamp) {
                        pendingClipboardAckTimestamp = -1
                        clipboardAckTimeoutJob?.cancel()
                        clipboardAckTimeoutJob = null
                        logEvent("Clipboard delivered (receiver confirmed)")
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse CLIPBOARD_ACK payload: ${e.message}")
                }
            }
            MessageType.NOTIFICATION_ACTION -> {
                try {
                    val jsonStr = frame.payload.toString(Charsets.UTF_8)
                    val json = JSONObject(jsonStr)
                    val id = json.optString("id")
                    val action = json.optString("action")
                    if (id.isNotBlank() && action.isNotBlank()) {
                        logEvent("Received NOTIFICATION_ACTION frame (id: $id, action: $action)")
                        onNotificationActionReceived?.invoke(id, action)
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse NOTIFICATION_ACTION payload: ${e.message}")
                }
            }
            MessageType.MIRROR_START -> {
                logEvent("Received MIRROR_START request")
                onMirrorStartRequested?.invoke()
            }
            MessageType.MIRROR_STOP -> {
                logEvent("Received MIRROR_STOP request")
                onMirrorStopRequested?.invoke()
            }
            MessageType.MIRROR_CONFIG, MessageType.MIRROR_FRAME -> {
                // Phone→Mac only; ignored on the phone.
            }
            MessageType.REMOTE_TOUCH -> {
                try {
                    val json = JSONObject(frame.payload.toString(Charsets.UTF_8))
                    val touch = MirrorProtocol.parseTouchJson(json)
                    if (touch != null) {
                        onRemoteTouchReceived?.invoke(touch.action, touch.x, touch.y)
                    } else {
                        logEvent("Ignored invalid REMOTE_TOUCH payload")
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse REMOTE_TOUCH payload: ${e.message}")
                }
            }
            MessageType.REMOTE_TEXT -> {
                try {
                    val json = JSONObject(frame.payload.toString(Charsets.UTF_8))
                    val special = json.optString("special").takeIf { it.isNotBlank() }
                    val text = json.optString("text").takeIf { it.isNotBlank() }
                    if (special != null || text != null) {
                        logEvent("Received REMOTE_TEXT frame (${text?.length ?: 0} chars, special: $special)")
                        onRemoteTextReceived?.invoke(text, special)
                    } else {
                        logEvent("Ignored invalid REMOTE_TEXT payload")
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse REMOTE_TEXT payload: ${e.message}")
                }
            }
            MessageType.OPEN_URL -> {
                try {
                    val json = JSONObject(frame.payload.toString(Charsets.UTF_8))
                    val url = json.optString("url")
                    if (url.isNotBlank()) {
                        logEvent("Received OPEN_URL frame: $url")
                        onOpenUrlReceived?.invoke(url)
                    } else {
                        logEvent("Ignored OPEN_URL frame with blank url")
                    }
                } catch (e: Exception) {
                    logEvent("Failed to parse OPEN_URL payload: ${e.message}")
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
                try {
                    val json = JSONObject(jsonStr)
                    val fileId = json.optString("fileId")
                    val status = json.optString("status")
                    if (fileId.isNotBlank()) {
                        fileTransferEngine?.handleFileAck(fileId, status)
                    }
                    logEvent("Received FILE_ACK frame (fileId: $fileId, Status: $status)")
                } catch (e: Exception) {
                    logEvent("Failed to parse FILE_ACK payload: ${e.message}")
                }
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
                val peerVersion = json?.optInt("protocolVersion", 1) ?: 1

                if (peerVersion != ProtocolConstants.HANDSHAKE_VERSION.toInt()) {
                    logEvent("HANDSHAKE version mismatch: peer $peerVersion, local ${ProtocolConstants.HANDSHAKE_VERSION.toInt()}")
                    sendErrorFrame(
                        socket,
                        409,
                        "Protocol version mismatch: peer $peerVersion, expected ${ProtocolConstants.HANDSHAKE_VERSION.toInt()}"
                    )
                    socket.close()
                    return
                }

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
                        put("protocolVersion", ProtocolConstants.HANDSHAKE_VERSION.toInt())
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

    fun sendNotificationReplyAck(id: String, success: Boolean): Boolean {        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        scope.launch(Dispatchers.IO) {
            val payload = JSONObject().apply {
                put("id", id)
                put("success", success)
            }.toString().toByteArray(Charsets.UTF_8)
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.NOTIFICATION_REPLY_ACK,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            sendFrameOnSocket(socket, frame)
        }
        return true
    }

    fun sendMirrorConfig(config: MirrorProtocol.MirrorConfig): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        scope.launch(Dispatchers.IO) {
            val payload = MirrorProtocol.encodeConfigJson(config).toByteArray(Charsets.UTF_8)
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.MIRROR_CONFIG,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            val success = sendFrameOnSocket(socket, frame)
            if (success) {
                logEvent("Sent MIRROR_CONFIG (${config.width}x${config.height} @${config.fps})")
            }
        }
        return true
    }

    fun sendMirrorFrame(timestampMs: Long, keyframe: Boolean, accessUnit: ByteArray): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        scope.launch(Dispatchers.IO) {
            val payload = MirrorProtocol.encodeFramePayload(timestampMs, keyframe, accessUnit)
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.MIRROR_FRAME,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            sendFrameOnSocket(socket, frame)
        }
        return true
    }

    fun sendMirrorStop(): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed) return false

        scope.launch(Dispatchers.IO) {
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.MIRROR_STOP,
                    streamId = streamId,
                    payloadLength = 2.toUInt()
                ),
                payload = "{}".toByteArray(Charsets.UTF_8)
            )
            sendFrameOnSocket(socket, frame)
        }
        return true
    }

    fun sendClipboard(text: String): Boolean {
        val socket = activeSocket ?: return false
        if (socket.isClosed || text.isEmpty()) return false

        val timestamp = System.currentTimeMillis()
        scope.launch(Dispatchers.IO) {
            val json = JSONObject().apply {
                put("text", text)
                put("timestamp", timestamp)
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
                scheduleClipboardAckTimeout(timestamp)
            } else {
                logEvent("Failed to send CLIPBOARD frame")
            }
        }
        return true
    }

    private fun scheduleClipboardAckTimeout(timestamp: Long) {
        clipboardAckTimeoutJob?.cancel()
        pendingClipboardAckTimestamp = timestamp
        clipboardAckTimeoutJob = scope.launch {
            delay(CLIPBOARD_ACK_TIMEOUT_MS)
            if (pendingClipboardAckTimestamp == timestamp) {
                pendingClipboardAckTimestamp = -1
                logEvent("Clipboard sent · no confirmation from receiver")
            }
        }
    }

    private fun sendClipboardAck(timestamp: Long) {
        val socket = activeSocket ?: return
        if (socket.isClosed) return

        scope.launch(Dispatchers.IO) {
            val payload = JSONObject().apply {
                put("timestamp", timestamp)
            }.toString().toByteArray(Charsets.UTF_8)
            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val frame = Frame(
                header = FrameHeader(
                    messageType = MessageType.CLIPBOARD_ACK,
                    streamId = streamId,
                    payloadLength = payload.size.toUInt()
                ),
                payload = payload
            )
            sendFrameOnSocket(socket, frame)
        }
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

    private suspend fun runHeartbeat(socket: Socket) {
        var missed = 0
        while (scope.isActive && !socket.isClosed) {
            delay(HEARTBEAT_INTERVAL_MS)
            if (!scope.isActive || socket.isClosed) return

            if (awaitingPong) {
                missed++
                if (missed >= MAX_MISSED_HEARTBEATS) {
                    logEvent("Heartbeat timeout ($missed missed PONGs); closing connection")
                    try { socket.close() } catch (_: Exception) {}
                    return
                }
            } else {
                missed = 0
            }

            val streamId = streamIdCounter.getAndIncrement().toUInt()
            val payload = """{"timestamp":${System.currentTimeMillis()}}""".toByteArray(Charsets.UTF_8)
            val sent = sendFrameOnSocket(
                socket,
                Frame(
                    header = FrameHeader(
                        messageType = MessageType.PING,
                        streamId = streamId,
                        payloadLength = payload.size.toUInt()
                    ),
                    payload = payload
                )
            )
            if (!sent) {
                logEvent("Heartbeat PING failed; closing connection")
                try { socket.close() } catch (_: Exception) {}
                return
            }
            awaitingPong = true
        }
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
            // Frames are atomic units on the wire: serialize writes so concurrent
            // producers (file chunks, heartbeat, ACKs) cannot interleave bytes.
            writeMutex.withLock {
                val activeChannel = channel
                when {
                    activeChannel != null && !frame.header.messageType.isCryptoHandshake -> {
                        // Seal the payload; the 16-byte wire header (with
                        // payloadLength = ciphertext size) is the AEAD AAD.
                        try {
                            val header = wireHeaderBytes(
                                version = frame.header.version,
                                messageType = frame.header.messageType,
                                streamId = frame.header.streamId,
                                payloadLength = frame.payload.size + 16
                            )
                            val sealed = activeChannel.seal(header, frame.payload)
                            val outputStream: OutputStream = socket.getOutputStream()
                            outputStream.write(header + sealed)
                            outputStream.flush()
                            true
                        } catch (e: NoiseException) {
                            logEvent("Failed to seal frame: ${e.message}")
                            false
                        } catch (e: Exception) {
                            logEvent("Failed to write frame to socket: ${e.message}")
                            false
                        }
                    }
                    activeChannel == null && !frame.header.messageType.isCryptoHandshake &&
                        frame.header.messageType != MessageType.ERROR -> {
                        // Channel not ready yet: queue the plaintext frame.
                        bufferUntilChannelReady(frame)
                        true
                    }
                    else -> {
                        // Handshake frames and pre-channel ERROR frames go out raw.
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
            }
        }
    }

    /**
     * Queues a plaintext frame until the encrypted channel is up (heartbeat
     * and battery updates start before the Noise handshake completes).
     */
    private fun bufferUntilChannelReady(frame: Frame) {
        synchronized(pendingOutboundLock) { pendingOutbound.add(frame) }
    }

    fun stopServer() {
        // Synchronous teardown: close/cancel are non-blocking and this makes
        // stop-then-start deterministic. The old async version raced with
        // startServer()'s `serverJob?.isActive` guard, swallowing the start.
        stopServerInternal()
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

        private const val HEARTBEAT_INTERVAL_MS = 12_000L
        private const val MAX_MISSED_HEARTBEATS = 2
        private const val CLIPBOARD_ACK_TIMEOUT_MS = 5_000L
    }
}
