package com.diego.pocketlink.protocol

sealed class ProtocolException(message: String, cause: Throwable? = null) : Exception(message, cause)

class InvalidFrameException(message: String) : ProtocolException(message)

class FrameOversizedException(message: String) : ProtocolException(message)

class UnknownMessageTypeException(val typeId: UShort) : ProtocolException("Unknown message type ID: 0x${typeId.toString(16)}")

class UnsupportedVersionException(val received: UShort) :
    ProtocolException("Unsupported protocol version: ${received.toInt()}, expected ${ProtocolConstants.PROTOCOL_VERSION.toInt()}")
