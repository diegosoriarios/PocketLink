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
| `0x0011` | `CLIPBOARD_ACK` | UTF-8 JSON | Delivery confirmation for `CLIPBOARD`; echoes the original `timestamp` |
| `0x0020` | `BATTERY` | UTF-8 JSON | Battery status and power level updates |
| `0x0030` | `NOTIFICATION` | UTF-8 JSON | Forwarded notification content |
| `0x0031` | `NOTIFICATION_REPLY` | UTF-8 JSON | Quick reply from the Mac (`{"id", "text"}`) |
| `0x0032` | `NOTIFICATION_ACTION` | UTF-8 JSON | Notification action from the Mac (`{"id", "action"}`, e.g. `dismiss`) |
| `0x0033` | `NOTIFICATION_REPLY_ACK` | UTF-8 JSON | Delivery confirmation for `NOTIFICATION_REPLY` (`{"id", "success"}`) |
| `0x0040` | `FILE_HEADER` | UTF-8 JSON | File metadata before transfer |
| `0x0041` | `FILE_CHUNK` | Binary | Raw file payload chunk with chunk header |
| `0x0042` | `FILE_ACK` | UTF-8 JSON | File chunk/completion receipt acknowledgement |
| `0x0043` | `FILE_CANCEL` | UTF-8 JSON | Cancel an in-progress file transfer |
| `0x0050` | `MIRROR_START` | UTF-8 JSON | Mac→phone request to begin screen mirroring |
| `0x0051` | `MIRROR_STOP` | UTF-8 JSON | Either side stops mirroring |
| `0x0052` | `MIRROR_CONFIG` | UTF-8 JSON | Phone→Mac video parameters + H.264 SPS/PPS (base64 Annex-B) |
| `0x0053` | `MIRROR_FRAME` | Binary | `u64 tsMs \| u8 keyframe \| u32 len \| Annex-B access unit` |
| `0x0054` | `REMOTE_TOUCH` | UTF-8 JSON | Mac→phone touch injection (`{"action","x","y"}` normalized) |
| `0x0064` | `REMOTE_TEXT` | UTF-8 JSON | Mac→phone keyboard injection: `{"text": "<non-empty str>"}` or `{"special": "backspace"\|"enter"}` (exactly one key) — appended to the focused editable node via `ACTION_SET_TEXT` (best-effort; no ACK in v1) |
| `0x0060` | `CRYPTO_M1` | Binary | Noise XX `-> e`: 32 B initiator ephemeral key |
| `0x0061` | `CRYPTO_M2` | Binary | Noise XX `<- e, ee, s, es`: 80 B + 112 B encrypted identity payload |
| `0x0062` | `CRYPTO_M3` | Binary | Noise XX `-> s, se`: 48 B + 112 B encrypted identity payload |
| `0x0065` | `OPEN_URL` | UTF-8 JSON | Mac→phone; `{"url": "<str>"}` — phone opens it via implicit `ACTION_VIEW` (http/https only; no ACK in v1) |

---

## Security Note

The wire is fully encrypted once the Noise XX handshake completes — see
**Encrypted Transport (C1)** below. Before the handshake only `CRYPTO_*`
frames and raw `ERROR` frames are legal; any plaintext application frame is
rejected with `ERROR 409` and the connection is closed.

---

## Message Details

### HANDSHAKE (`0x0001`)

The HANDSHAKE frame is exchanged during connection initialization. Its payload is a UTF-8 JSON object:

```json
{"device": "<name>", "platform": "<platform>", "pairingToken": "<optional string>", "protocolVersion": 2}
```

- `device`: Device name (e.g. `"Pixel 8"`, `"Diego's Mac"`).
- `platform`: Operating system platform (`"Android"`, `"macOS"`).
- `pairingToken`: Optional single-use token when executing QR-based device pairing.
- `protocolVersion`: Protocol version the sender speaks (`2` since the
  encrypted-transport milestone; both ends ship together, no plaintext
  fallback). A HANDSHAKE without the field is treated as version 1 and
  rejected with `ERROR 409`.

### QR Pairing Flow (Protocol Extension, QR payload v2)

1. The macOS app displays a QR code containing a one-time pairing token and
   its identity fingerprint:
   `pocketlink://pair?v=2&t=<token>&k=<fingerprint>` (fingerprint = SHA-256 of
   the Mac's Ed25519 identity key, 64 lowercase hex chars).
2. The phone scans the QR code and stores the token **and** the pinned
   fingerprint as a pending in-memory pairing token (5-minute expiration).
3. The Mac connects and completes the Noise handshake, then sends a
   `HANDSHAKE` frame with `pairingToken` set to `<token>`.
4. The phone verifies the initiator's M3 identity payload **against the
   pinned fingerprint** before the channel is established: on mismatch it
   sends `ERROR 403` ("Device identity does not match the scanned pairing
   code") and closes the connection.
5. If the token matches the phone's non-expired pending token, the phone
   responds on the same (encrypted) socket with a `HANDSHAKE` frame containing:
   `{"device": "<Model>", "platform": "Android", "pairingToken": "<token>", "protocolVersion": 2}`
   and clears the pending token.
6. If no token is pending or the token does not match / is expired, the phone
   accepts the connection without replying with a pairing HANDSHAKE.

### Version Negotiation

- The 16-byte header `version` field must equal `0x0001`. A frame with any
  other version is rejected: the receiver sends `ERROR 409` and closes the
  connection.
- Both HANDSHAKE payloads carry `"protocolVersion": 2`. On mismatch the
  receiver sends `ERROR 409` and closes the connection.

---

## Encrypted Transport (C1)

### Primitives

- Noise XX over **X25519 / ChaChaPoly / SHA-256**
  (`Noise_XX_25519_ChaChaPoly_SHA256`), byte-for-byte compatible with the
  macOS CryptoKit implementation (Android uses BouncyCastle).
- Device identity: Ed25519 keypair; SHA-256 of the Ed25519 public key is the
  **fingerprint** (QR `k=` field, UI display, pinning). The Noise static key
  is X25519. Each handshake payload carries the sender's Ed25519 public key
  and an Ed25519 signature over the sender's X25519 static public key
  (96 B payload; 112 B on the wire with the 16 B AEAD tag).

### Handshake frames

| Type | Size | Noise tokens |
|---|---|---|
| `CRYPTO_M1` (0x0060) | 32 B | `-> e` |
| `CRYPTO_M2` (0x0061) | 192 B | `<- e, ee, s, es` |
| `CRYPTO_M3` (0x0062) | 160 B | `-> s, se` |

- One Noise message per LINK frame; the payload is the raw Noise message with
  no extra length prefix.
- **macOS is the initiator** (sends M1/M3); Android is the responder.
- `split()` is direction-agnostic: it always returns (k1 = initiator→responder
  send, k2 = responder→initiator send). The responder mirrors the states when
  constructing its channel.

### Transport rules

- Application frames are sealed payload-only: the 16-byte header travels in
  the clear with `payloadLength` = ciphertext size (plaintext + 16 B
  Poly1305 tag); the header bytes are the AEAD associated data.
- Per-direction 64-bit counters start at 0; the ChaChaPoly nonce is
  `4 zero bytes ‖ uint64 BE(counter)`.
- `CRYPTO_*` frames and pre-channel `ERROR` frames go out raw.
- Decrypt failure → `ERROR 401` (raw), channel discarded, connection closed.
- Plaintext application frame before the channel exists → `ERROR 409
  "Encrypted transport required"`, connection closed.
- Peer fingerprint mismatch vs the QR-pinned fingerprint → `ERROR 403`,
  connection closed.
- `ERROR` frames sent after the channel is established are sealed like any
  other application frame.
