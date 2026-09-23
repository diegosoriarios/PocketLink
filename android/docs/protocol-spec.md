# PocketLink Length-Framed Binary Protocol Specification (v1)

## Overview

The PocketLink protocol is a length-framed binary protocol operating over TCP. TCP is a byte-stream protocol that does not preserve message boundaries; framing ensures that the receiver can cleanly delimit messages without ambiguity.

All multi-byte integers are encoded in **Big-Endian (Network Byte Order)**.

---

## Header Structure (16 Bytes Fixed)

Every frame begins with a fixed 16-byte header:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Magic ("LINK")                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Version              |          Message Type         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           Stream ID                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Payload Length                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                        Payload (Variable)                     |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### Field Definitions

| Offset | Field | Type | Description |
|---|---|---|---|
| `0..3` | **Magic** | `4 bytes` ASCII | Fixed magic bytes: `LINK` (`0x4C 0x49 0x4E 0x4B`) |
| `4..5` | **Version** | `uint16` | Protocol version (`0x0001` for v1) |
| `6..7` | **Message Type** | `uint16` | Type of message (see Message Types table) |
| `8..11` | **Stream ID** | `uint32` | Stream / Request correlation identifier |
| `12..15` | **Payload Length**| `uint32` | Payload size in bytes (Max: `8,388,608` bytes / 8 MB) |
| `16..N` | **Payload** | `byte[]` | Payload data matching Message Type format |

---

## Message Types

| ID (`uint16`) | Enum Name | Payload Format | Description |
|---|---|---|---|
| `0x0001` | `HANDSHAKE` | UTF-8 JSON | Connection initialization and identity exchange |
| `0x0002` | `PING` | UTF-8 JSON | Keepalive ping frame |
| `0x0003` | `PONG` | UTF-8 JSON | Keepalive pong response frame |
| `0x0004` | `DEVICE_INFO` | UTF-8 JSON | System info / capacity updates |
| `0x0005` | `ERROR` | UTF-8 JSON | Protocol or processing error description |
| `0x0010` | `CLIPBOARD` | UTF-8 JSON | Clipboard text sync |
| `0x0020` | `BATTERY` | UTF-8 JSON | Battery status and power level updates |
| `0x0030` | `NOTIFICATION` | UTF-8 JSON | Forwarded notification content |
| `0x0040` | `FILE_HEADER` | UTF-8 JSON | File metadata before transfer |
| `0x0041` | `FILE_CHUNK` | Binary | Raw file payload chunk with chunk header |
| `0x0042` | `FILE_ACK` | UTF-8 JSON | File chunk/completion receipt acknowledgement |

---

## Security Note

In early milestones, frames are transmitted unencrypted over the local Wi-Fi connection. In future milestones, an authenticated and encrypted layer (such as Noise Protocol / TLS with pinned certificates via QR code pairing) will wrap the frame payload or stream.
