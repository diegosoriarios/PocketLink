# PocketLink — Wire Protocol v1

This is the byte-exact specification of the protocol implemented by the existing
Android app (`android/`). The macOS client must reproduce it exactly. Source of
truth: Android `ProtocolEncoder` / `ProtocolDecoder` / `MessageType` /
`ConnectionManager` / `ChecksumUtils`.

## Framing

Every message is a single frame on the TCP stream:

```
offset  size  field
0       4     Magic            ASCII "LINK" (0x4C 0x49 0x4E 0x4B)
4       2     Version          uint16, big-endian, currently 1
6       2     Message type     uint16, big-endian (see table)
8       4     Stream ID        uint32, big-endian
12      4     Payload length   uint32, big-endian, max 8_388_608 (8 MB)
16      N     Payload          see per-type table
```

- All integers are **big-endian** (network byte order).
- `HEADER_SIZE = 16`. Total frame size = `16 + payloadLength`.
- Encoder must guarantee `payload.count == header.payloadLength`.

## Decoder rules (mirror Android `ProtocolDecoder`)

The decoder is incremental: bytes are appended to a buffer; frames are extracted
as they complete. Validation happens in this order per attempt:

1. Fewer than 16 bytes buffered → wait for more data.
2. Magic != "LINK" → discard entire buffer (`reset`), fail with **invalid frame**.
3. `payloadLength > 8_388_608` → discard entire buffer, fail with **oversized frame**.
4. Fewer than `16 + payloadLength` bytes buffered → wait for more data.
5. Message type ID not in table → discard entire buffer, fail with **unknown type**.
6. Otherwise emit one frame and consume its bytes from the buffer; loop.

Connection policy (as implemented on Android):
- invalid frame → send ERROR 400, **close connection**
- oversized frame → send ERROR 413, keep connection
- unknown type → send ERROR 400, keep connection

## Message types

| ID       | Name        | Payload format |
|----------|-------------|----------------|
| `0x0001` | HANDSHAKE   | UTF-8 text (no schema enforced; Android logs only) |
| `0x0002` | PING        | UTF-8 JSON: `{"timestamp": <epoch ms>}` |
| `0x0003` | PONG        | Verbatim echo of PING payload; streamId copied from PING |
| `0x0004` | DEVICE_INFO | Defined, unused by Android |
| `0x0005` | ERROR       | UTF-8 JSON: `{"code": <int>, "message": "<str>"}`, streamId 0; codes: 400, 413 |
| `0x0010` | CLIPBOARD   | UTF-8 JSON: `{"text": "<str>", "timestamp": <epoch ms>}` |
| `0x0020` | BATTERY     | UTF-8 JSON: `{"level": <int 0-100>, "isCharging": <bool>, "powerSave": <bool>, "timestamp": <epoch ms>}` |
| `0x0030` | NOTIFICATION | UTF-8 JSON: `{"id": "<str>", "packageName": "<str>", "appName": "<str>", "title": "<str>", "text": "<str>", "postTime": <epoch ms>, "hasQuickReply": <bool>}` |
| `0x0031` | NOTIFICATION_REPLY | UTF-8 JSON: `{"id": "<str>", "text": "<str>"}`, streamId = sender counter (Mac→phone, see below) |
| `0x0040` | FILE_HEADER | UTF-8 JSON: `{"fileId": "<8-char id>", "name": "<str>", "size": <int>, "sha256": "<64 lowercase hex>", "mimeType": "<str>"}` |
| `0x0041` | FILE_CHUNK  | Binary: `int32 BE fileIdHash` + `int64 BE offset` + raw file bytes |
| `0x0042` | FILE_ACK    | UTF-8 JSON: `{"fileId": "<id>", "receivedBytes": <int>, "status": "<str>"}`; status: `SUCCESS`, `SHA_MISMATCH`, `CANCELLED` |
| `0x0043` | FILE_CANCEL | UTF-8 JSON: `{"fileId": "<8-char id>"}`, streamId 0. Sender→receiver abort of the active transfer with that `fileId` (extension, see below) |

JSON is UTF-8 with these exact, case-sensitive key names.

### FILE_CHUNK details

- `CHUNK_HEADER_SIZE = 12`, `DEFAULT_CHUNK_SIZE = 65536` (64 KB).
- `fileIdHash` is **Java's `String.hashCode()`** of the fileId, written as a
  raw 32-bit big-endian value (bit pattern of the possibly-negative int):
  `h = 0; for c in s { h = 31*h + Int32(cUnicode) }` with wrapping Int32 arithmetic.
- There is **no FILE_END message**. Transfer completion is inferred when
  `bytesReceived >= FILE_HEADER.size`; the receiver then verifies SHA-256
  (lowercase hex, compare case-insensitively) and replies with FILE_ACK.

### FILE_CANCEL details (protocol extension)

- Not part of the original Android protocol; implemented by both current apps.
- Direction: **file sender → file receiver** (Mac cancels its outgoing send).
- Semantics for the receiver: if an incoming transfer with a matching `fileId`
  is active, close and **delete the partial file**, reset receive state, and
  publish a `CANCELLED` progress state (which also unblocks the phone's own
  outgoing sends). Unknown `fileId`, no active transfer, or an
  already-finished transfer → silently ignore (idempotent).
- The sender sends it best-effort after any failure past the header
  (cancellation, size mismatch, IO error). If the header itself was never
  delivered, no FILE_CANCEL is sent.
- Compatibility: receivers that predate this extension treat `0x0043` as an
  unknown type (ERROR 400 reply, connection survives) and keep the partial
  file — the pre-extension behavior.

### NOTIFICATION_REPLY details (protocol extension)

- Not part of the original Android protocol; implemented by both current apps.
- Direction: **Mac → phone**, a reply to a previously forwarded notification.
- `id` is the exact notification id the Mac received in the NOTIFICATION frame
  (Android's `"<sbn.key>_<postTime>"`). `text` is the reply, non-empty after
  trimming; senders must not send empty replies and receivers ignore them.
- Receiver semantics: find the still-active notification whose
  `"<sbn.key>_<postTime>"` equals `id`, locate its quick-reply action (an
  action with non-empty `RemoteInput`s), inject `text` into the reply intent,
  and post it. Unknown/expired id, no reply action, or failed post → log and
  ignore (no ERROR frame). The phone never echoes reply contents to logs.
- Compatibility: phones that predate this extension treat `0x0031` as an
  unknown type (ERROR 400 reply, connection survives).

## Transport

- TCP. **Android is the server**, default port **52345**; the macOS client connects out.
- Single connection at a time; a new accepted connection replaces the old one.
- Stream IDs: a per-side counter starting at 1, incremented on every outbound
  frame. Special cases: PONG reuses the PING's streamId; ERROR uses 0.
  File-transfer correlation is by payload (`fileId` / `fileIdHash`), not stream ID.

## Discovery

- Android advertises mDNS/NSD service type **`_link._tcp.`** (trailing dot).
- Service name: `Link-<Android model with spaces replaced by dashes>`.
- Advertised port = live TCP server port. **No TXT records.**

## Security

The wire is currently plaintext on both platforms. Encryption/pairing
(X25519/Ed25519, Noise XX) is a later milestone; frames are what both sides
exchange today.

## Golden vectors

PING frame with streamId 1:

```
4C 49 4E 4B 00 01 00 02 00 00 00 01 00 00 00 1B
7B 22 74 69 6D 65 73 74 61 6D 70 22 3A 31 37 31 39 30 30 30 30 30 30 30 30 30 7D
```

Breakdown: magic `LINK` | version `0x0001` | type `0x0002` (PING) |
streamId `0x00000001` | payloadLength `0x0000001B` (27) |
payload `{"timestamp":1719000000000}` (27 bytes UTF-8).
