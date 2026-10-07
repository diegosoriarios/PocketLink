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
 - header version != 1 → send ERROR 409, close connection

## Message types

| ID       | Name        | Payload format |
|----------|-------------|----------------|
| `0x0001` | HANDSHAKE   | UTF-8 JSON: `{"device": "<str>", "platform": "<str>", "pairingToken": "<str, optional>", "protocolVersion": <int>}` (see QR pairing below) |
| `0x0002` | PING        | UTF-8 JSON: `{"timestamp": <epoch ms>}` |
| `0x0003` | PONG        | Verbatim echo of PING payload; streamId copied from PING |
| `0x0004` | DEVICE_INFO | Defined, unused by Android |
| `0x0005` | ERROR       | UTF-8 JSON: `{"code": <int>, "message": "<str>"}`, streamId 0; codes: 400, 401, 403, 409, 413 |
| `0x0010` | CLIPBOARD   | UTF-8 JSON: `{"text": "<str>", "timestamp": <epoch ms>}` |
| `0x0011` | CLIPBOARD_ACK | UTF-8 JSON: `{"timestamp": <epoch ms of acknowledged CLIPBOARD>}`. Sent by the receiver after applying clipboard text; lets the sender show delivery status. |
| `0x0020` | BATTERY     | UTF-8 JSON: `{"level": <int 0-100>, "isCharging": <bool>, "powerSave": <bool>, "timestamp": <epoch ms>}` |
| `0x0030` | NOTIFICATION | UTF-8 JSON: `{"id": "<str>", "packageName": "<str>", "appName": "<str>", "title": "<str>", "text": "<str>", "postTime": <epoch ms>, "hasQuickReply": <bool>}` |
| `0x0031` | NOTIFICATION_REPLY | UTF-8 JSON: `{"id": "<str>", "text": "<str>"}`, streamId = sender counter (Mac→phone, see below) |
| `0x0032` | NOTIFICATION_ACTION | UTF-8 JSON: `{"id": "<str>", "action": "<str>"}` (Mac→phone; `"dismiss"` cancels the notification on the phone) |
| `0x0033` | NOTIFICATION_REPLY_ACK | UTF-8 JSON: `{"id": "<str>", "success": <bool>}` (phone→Mac; delivery confirmation for NOTIFICATION_REPLY) |
| `0x0040` | FILE_HEADER | UTF-8 JSON: `{"fileId": "<8-char id>", "name": "<str>", "size": <int>, "sha256": "<64 lowercase hex>", "mimeType": "<str>"}` |
| `0x0041` | FILE_CHUNK  | Binary: `int32 BE fileIdHash` + `int64 BE offset` + raw file bytes |
| `0x0042` | FILE_ACK    | UTF-8 JSON: `{"fileId": "<id>", "receivedBytes": <int>, "status": "<str>"}`; status: `SUCCESS`, `SHA_MISMATCH`, `CANCELLED` |
| `0x0043` | FILE_CANCEL | UTF-8 JSON: `{"fileId": "<8-char id>"}`, streamId 0. Sender→receiver abort of the active transfer with that `fileId` (extension, see below) |
| `0x0050` | MIRROR_START | UTF-8 JSON `{}` | Mac→phone request to begin screen mirroring (phone still shows the MediaProjection consent dialog) |
| `0x0051` | MIRROR_STOP | UTF-8 JSON `{}` | Either side stops an active mirroring session |
| `0x0052` | MIRROR_CONFIG | UTF-8 JSON: `{"width": <int>, "height": <int>, "fps": <int>, "bitrateBps": <int>, "sps": "<base64 Annex-B>", "pps": "<base64 Annex-B>"}` | Phone→Mac video stream parameters + H.264 parameter sets (phone→Mac only) |
| `0x0053` | MIRROR_FRAME | Binary: `u64 timestampMs (BE) | u8 keyframe | u32 accessUnitLength (BE) | Annex-B access unit` | One H.264 encoded access unit (phone→Mac only) |
| `0x0054` | REMOTE_TOUCH | UTF-8 JSON: `{"action": "down"\|"move"\|"up", "x": <0..1>, "y": <0..1>}` | Mac→phone touch injection; coordinates normalized to the captured display |
| `0x0064` | REMOTE_TEXT | UTF-8 JSON: `{"text": "<non-empty str>"}` or `{"special": "backspace"\|"enter"}` (exactly one key) | Mac→phone keyboard injection; the phone appends the text (or applies the special key) to the focused editable node via `ACTION_SET_TEXT` (best-effort, no ACK in v1) |
| `0x0060` | CRYPTO_M1 | Binary: 32 B (Noise XX `-> e`) | Initiator ephemeral key; raw Noise message, no extra length prefix |
| `0x0061` | CRYPTO_M2 | Binary: 80 B + 112 B encrypted identity payload (Noise XX `<- e, ee, s, es`) | Responder ephemeral + static + identity |
| `0x0062` | CRYPTO_M3 | Binary: 48 B + 112 B encrypted identity payload (Noise XX `-> s, se`) | Initiator static + identity |
| `0x0065` | OPEN_URL | UTF-8 JSON: `{"url": "<str>"}` | Mac→phone; the phone opens the URL via an implicit `ACTION_VIEW` (http/https only; no ACK in v1) |

JSON is UTF-8 with these exact, case-sensitive key names.

## Version negotiation

- The 16-byte header `version` field must equal `1`. A frame with any other
  version is rejected: the receiver sends `ERROR 409` and closes the
  connection.
- Both HANDSHAKE payloads carry `"protocolVersion": 2` (the encrypted-transport
  revision; both ends ship together and there is no plaintext fallback). On
  mismatch the receiver sends `ERROR 409` and closes the connection. A
  HANDSHAKE without the field is treated as version 1 and rejected the same
  way.

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

### QR pairing (protocol extension)

- Not part of the original Android protocol. Adds a one-time pairing token to
  the HANDSHAKE payload (`pairingToken` key, optional) so the phone can confirm
  a pairing initiated by the Mac, plus an identity fingerprint for out-of-band
  trust anchoring.
- The Mac generates a **one-time token** (16 random bytes, base64url, no
  padding — 22 characters), held in memory for **5 minutes, single use**. It
  renders a QR code encoding:
  `pocketlink://pair?v=2&t=<token>&k=<fingerprint>` where `<fingerprint>` is
  the Mac identity's SHA-256 fingerprint (64 lowercase hex chars; `v = 2` since
  the encrypted-transport milestone; `k` was added in the same revision).
- Flow: the Mac connects to the phone (normal flow), completes the Noise
  handshake, and sends HANDSHAKE including `pairingToken` on every (re)connect
  while pairing is pending. The phone scans the QR (learning the token *and*
  the Mac's identity fingerprint) and when it sees a HANDSHAKE whose
  `pairingToken` matches, replies with its own HANDSHAKE frame (phone → Mac)
  carrying the scanned token. On match, the Mac auto-trusts the peer and both
  sides mark the session as paired.
- **Fingerprint pinning:** the scanned `k` value pins the expected peer
  identity fingerprint. After the phone verifies the initiator's M3 identity
  payload, it compares the received fingerprint with the pinned one; on
  mismatch the phone sends `ERROR 403` ("Device identity does not match the
  scanned pairing code") and closes the connection. The Mac performs the
  mirror-image check against its Trust Store (TOFU on first connect, pin
  afterwards).
- Compatibility: both ends of the current pairing ship together; older peers
  (QR `v=1`) are rejected by the phone's `v=2` requirement and by the
  `protocolVersion` handshake check.
- The token is proximity proof only (someone physically scanned the screen);
  the actual channel security comes from the Noise handshake, with the QR
  fingerprint providing the out-of-band authentication anchor.

## Encrypted transport (C1)

All application frames are encrypted after a Noise XX handshake. Both ends
ship together; there is **no plaintext fallback**.

### Crypto primitives (identical on both platforms)

- Noise XX pattern over **X25519 / ChaChaPoly / SHA-256**
  (`Noise_XX_25519_ChaChaPoly_SHA256`), implemented with CryptoKit (macOS) and
  BouncyCastle (Android) to be byte-for-byte identical.
- Device identity: Ed25519 keypair. The Ed25519 public key's SHA-256
  (lowercase hex) is the **fingerprint** shown in the UI and embedded in the
  QR code. The Noise static key is X25519; each handshake message's encrypted
  payload carries the sender's Ed25519 public key plus an Ed25519 signature
  over the sender's X25519 static public key, binding the two keys together
  (96 B payload; 112 B on the wire with the AEAD tag).

### Handshake messages (one per LINK frame, payload = raw Noise message)

- `CRYPTO_M1` (0x0060): 32 B, `-> e`.
- `CRYPTO_M2` (0x0061): 32 B ephemeral + 48 B encrypted static + 112 B
  encrypted identity payload = 192 B, `<- e, ee, s, es`.
- `CRYPTO_M3` (0x0062): 48 B encrypted static + 112 B encrypted identity
  payload = 160 B, `-> s, se`.
- The **macOS is the initiator** (sends M1/M3), Android the responder.
- `split()` is direction-agnostic: it always returns (k1 = initiator→responder
  send, k2 = responder→initiator send). The responder must mirror the states
  when constructing its transport channel.

### Transport rules

- After the handshake every **application frame** is sealed
  payload-only: the 16-byte wire header travels in the clear with
  `payloadLength` set to the **ciphertext** size (plaintext + 16-byte
  Poly1305 tag); the header bytes (magic, version, type, streamId,
  payloadLength) are the AEAD **associated data**.
- Per-direction 64-bit counters start at 0 and increment per frame; the
  ChaChaPoly nonce is `4 zero bytes ‖ uint64 BE(counter)` (12 B).
- CRYPTO_* frames and pre-channel ERROR frames are sent raw.
- **Decrypt failure** → receiver sends `ERROR 401` (raw), discards the channel,
  closes the connection.
- **Plaintext application frame before the channel exists** → receiver sends
  `ERROR 409 "Encrypted transport required"` and closes.
- **Fingerprint mismatch** (QR pin / trust store) → `ERROR 403` and close.
- ERROR frames sent *after* the channel is established are sealed like any
  other application frame.

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

The wire is fully encrypted once the Noise XX handshake completes (see
*Encrypted transport (C1)* above): X25519 ECDH, ChaCha20-Poly1305 AEAD,
SHA-256, with Ed25519 identity keys bound into the handshake and pinned
out-of-band via the QR fingerprint. Private identity halves live in the
macOS Keychain (`LinkIdentity`) and Android app-private storage
(`filesDir/pocketlink-identity.json`, Keystore wrapping is a documented
follow-up). Before the handshake, only CRYPTO_* handshake frames and raw
ERROR frames are legal; anything else is rejected.

## Golden vectors

PING frame with streamId 1:

```
4C 49 4E 4B 00 01 00 02 00 00 00 01 00 00 00 1B
7B 22 74 69 6D 65 73 74 61 6D 70 22 3A 31 37 31 39 30 30 30 30 30 30 30 30 30 7D
```

Breakdown: magic `LINK` | version `0x0001` | type `0x0002` (PING) |
streamId `0x00000001` | payloadLength `0x0000001B` (27) |
payload `{"timestamp":1719000000000}` (27 bytes UTF-8).
