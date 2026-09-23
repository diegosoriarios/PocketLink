# Link My App — Next Steps

Last updated: 2026-09-23 (after M9)
Scope: prevent partial files on the phone when a Mac→phone transfer is cancelled, plus the full limitations inventory and prioritized roadmap.

---

## 1. Goal

When the user cancels an outgoing file transfer on the Mac mid-send, the phone currently keeps receiving
nothing (chunks stop) and is left with:

- A **partial file saved** in `Downloads/LinkCompanion` (MediaStore entry already created by `FILE_HEADER`)
- Receive state stuck at `IN_PROGRESS`, which **blocks phone→Mac `sendFile`** ("File transfer already in
  progress", `FileTransferEngine.kt:44`) until a new incoming header resets it

The wire protocol has **no abort message** today (types end at `FILE_ACK 0x0042`). Both apps must change.

## 2. Design decision (approved)

New message type **`FILE_CANCEL = 0x0043`**, payload JSON `{"fileId": "<8-char id>"}`, `streamId 0`.

Alternatives considered and rejected:

- *Reuse `FILE_ACK` with `status=CANCELLED`*: no new wire type, but semantically wrong (acks flow
  receiver→sender) and Android still has to learn to act on received acks. No savings.
- *Phone-side cleanup only* (delete on new header + receive-idle timeout): no protocol change, but the
  partial persists for the timeout window and phone→Mac sends stay blocked meanwhile. Weaker guarantee.

Why 0x0043 is safe: `MessageType.kt` ends at `FILE_ACK(0x0042u)`; old Android parsing an unknown type throws
`UnknownMessageTypeException` → replies `ERROR 400` but **does not close the socket**
(`ConnectionManager.kt:161-164`), so a new Mac talking to an old phone degrades gracefully.

---

## 3. Android changes (mobile app)

### 3.1 `protocol/MessageType.kt` — one line

```kotlin
FILE_CANCEL(0x0043u);
```

`MessageType.fromId` (used by `ConnectionManager.sendRawFrame:60`) is a lookup over the enum entries and
adopts the new value automatically. Nothing else in the protocol package changes.

### 3.2 `files/FileTransferEngine.kt` — the core work

1. **Retain the destination** (currently discarded in `createMediaStoreOutputStream`):
   - Add fields `private var incomingUri: Uri? = null` (API 29+) and
     `private var incomingFile: File? = null` (pre-Q)
   - Change `createMediaStoreOutputStream` to return/record both the stream and its target
     (`contentResolver.insert(...)` result must be kept to delete it later; pre-Q keeps the `File`)

2. **New `handleIncomingCancel(json: String)`** (suspend, `Dispatchers.IO`, same pattern as
   `handleIncomingHeader`):
   - Parse `{"fileId": "..."}`
   - If no active incoming transfer or `fileId` does not match `incomingMetadata?.fileId` → log + ignore
     (stale/unknown cancel)
   - If it matches:
     - Close `incomingOutputStream` (without flushing partial data semantics — just close)
     - Delete the partial: `contentResolver.delete(incomingUri, null, null)` (Q+) or `incomingFile?.delete()`
     - Clear `incomingMetadata / incomingOutputStream / incomingDigest / incomingBytesReceived /
       incomingUri / incomingFile`
     - Publish `TransferProgress(fileId, fileName, bytesTransferred, totalBytes, state = CANCELLED)` —
       this **unblocks phone→Mac `sendFile`**
   - Idempotent: cancel after completion (`incomingOutputStream == null`) must be a no-op

3. **Fix zero-size header hang** (related, same file): in `handleIncomingHeader`, when
   `metadata.size == 0L`, immediately flush/close the (empty) stream, verify SHA-256 of empty input, send
   `SUCCESS` ack, publish `COMPLETED`. Today the phone waits forever for chunks that never come.

4. **Optional hygiene**: when a new `FILE_HEADER` arrives while a transfer is active
   (`handleIncomingHeader`), close + delete the previous partial using the same retention plumbing
   (currently the old MediaStore entry lingers as an orphan).

### 3.3 `connection/ConnectionManager.kt` — one case

In `handleReceivedFrame`'s `when` (after `MessageType.FILE_CHUNK`):

```kotlin
MessageType.FILE_CANCEL -> {
    val jsonStr = frame.payload.toString(Charsets.UTF_8)
    logEvent("Received FILE_CANCEL frame")
    fileTransferEngine?.handleIncomingCancel(jsonStr)
}
```

### 3.4 No other Android files change

- `ConnectionService.kt` wiring (`fileEngine` lambda) is unaffected
- Android's own phone→Mac cancel (`cancelTransfer`) already sends a `FILE_ACK CANCELLED` to the Mac, and
  the Mac already handles `.cancelled` acks — unchanged
- Android's `FILE_ACK` receive branch (log-only, `ConnectionManager.kt:238-243`) stays as-is

---

## 4. Mac changes — ✅ implemented 2026-09-23

Implementation notes (deviations/details beyond the original sketch):

- `cancelFrame(fileId:streamId:)` uses **streamId 0** everywhere (simpler than the planned
  per-connection counter; Android ignores the field; consistent with ERROR frames)
- `sendCancelBestEffort` is **fire-and-forget** (unstructured `Task`, no await): an awaited delivery
  can block indefinitely behind queued chunks when the receiver drains slowly, which would hang the
  rethrow. Unstructured tasks don't inherit cancellation, so the frame still goes out from an already
  cancelled context
- The chunk loop is wrapped so **any** error after the header was accepted (CancellationError,
  sizeMismatch, IO error) triggers the best-effort cancel — a superset of the planned two cases
- Verified by the extended `testCancelMidSendStopsTransferAndThrowsCancellationError`: the stub now
  decodes frames and asserts a `FILE_CANCEL` frame with the matching `fileId` (streamId 0) arrives
  after the cancel

1. **`LinkCore/Sources/LinkProtocol/MessageType.swift`** — add `case fileCancel = 0x0043` and the
   `init?(id:)` entry
2. **`LinkCore/Sources/LinkFiles/FileSender.swift`** — in `send(...)`, on `CancellationError` (and on
   `sizeMismatch`), best-effort send `FILE_CANCEL {"fileId"}` before rethrowing. Safe because
   `LinkClient.send` is cancellation-aware (M9): a blocked send resumes with `CancellationError` instead of
   hanging. The cancel frame itself must be sent with `try?` so it never masks the original error
3. **`Link My App/UI/ConnectionViewModel.swift`** — `cancelOutgoing` for `.awaitingAck` also sends
   `FILE_CANCEL` best-effort (final bytes may still be draining on the phone); mid-send cancel already
   flows through the task cancellation → sender path. Reuse the file-cancel helper for the
   "file no longer exists"/prepare-failure path? No — prepare failure means no header was ever sent, so no
   cancel frame
4. **`docs/PROTOCOL.md`** — document `0x0043 FILE_CANCEL` with payload schema, direction
   (sender→receiver), and compatibility notes

---

## 5. Compatibility matrix

| Mac \ Phone   | Old Android (≤ current)                                   | New Android                                  |
|---------------|-----------------------------------------------------------|----------------------------------------------|
| **Old Mac**   | unchanged                                                 | `FILE_CANCEL` case dormant, everything as before |
| **New Mac**   | cancel frame → phone replies `ERROR 400`, connection survives; partial stays on phone; phone→Mac sends stay blocked until next header | partial deleted, state reset, phone→Mac unblocked |

Rollout order: ship both apps in either order — the new type is additive on both sides.

---

## 6. Test plan

**Mac (Swift package):**
- FrameDecoder/FrameEncoder roundtrip for `fileCancel`
- Extend `SlowDrainStub` (`FileSendIntegrationTests.swift`) to record received frames; assert a
  `FILE_CANCEL` frame with the matching `fileId` arrives after `Task.cancel()` mid-send
- Existing 72 tests must stay green

**Android:**
- Unit-test `handleIncomingCancel`: matching fileId deletes the entry and resets state; unknown fileId is a
  no-op; cancel-after-completion is a no-op (Robolectric or instrumented test with MediaStore)
- Zero-size header: completes immediately with SUCCESS ack
- Manual on-device: cancel a large Mac→phone transfer mid-flight → `Downloads/LinkCompanion` has no
  leftover; immediately send phone→Mac file → no "already in progress" rejection

---

## 7. All limitations so far (M0–M9)

**Connection / discovery**
- Auto-reconnect is implemented with capped backoff (1s/2s/5s/10s via ReconnectPolicy, ~18s total); after
  exhaustion it falls back to mDNS browsing and requires a click. No retry on the *initial* connect, and
  reconnect reuses the same endpoint only (no mDNS re-resolution of a changed phone IP)
- Connect timeout is fixed at 10 s; no configurable per-attempt tuning
- Discovery does not deduplicate devices that advertise both mDNS and manual entries
- Plaintext wire protocol — no TLS, no message authentication

**Pairing / trust**
- Trust key is the mDNS device name (or IP for manual connects) — a spoofed name would re-prompt or
  impersonate; no cryptographic peer identity (wire-breaking, needs versioning)
- No UI to view trust *dates/ids* beyond name + addedAt; revoke is immediate with no confirmation dialog
- Handshake payload schema is a Mac-side convention (Android logs it but does not validate)

**Notifications**
- Quick-reply from Mac is implemented both platforms (0x0031, see §8.3); replies are fire-and-forget —
  no delivery ack, no failure surfaced on the Mac beyond generic send errors
- In-memory only, capped at 20, cleared on quit; no persistence
- No action buttons beyond quick-reply, no grouping per app

**Clipboard**
- Mac sends only via explicit button (deliberate: avoids exfiltrating copied passwords); Android auto-sends
  on change — asymmetric by design
- Text only; no images/URIs; no sync-status feedback

**Files**
- Single transfer at a time in both directions (mirrors Android's shared `TransferProgress` state)
- No transfer history persistence (rows capped at 10, in-memory)
- Modal `NSOpenPanel`/`NSSavePanel` block the menu bar window while open
- Receiver writes 64 KB chunks on the main actor (fine for MVP, not for sustained throughput)
- Phone→Mac cancel exists on Android but the partial-handling gap this document fixes was Mac→phone only
- Android quirks mirrored/documented: per-chunk hash field ignored; zero-size hang (fixed by §3.2.3 once
  shipped); stalled IN_PROGRESS blocks phone→Mac sends (fixed by §3.2.2)

**Protocol / platform**
- No protocol version negotiation beyond the static `version: 1` header field (not validated by either side)
- Error policy mirrored from Android: `ERROR 400/413`; `invalidMagic` additionally closes on the Mac
- No CI; verification is local `swift test` + `xcodebuild` + manual smoke launches
- Real-device acceptance has not happened yet — every milestone so far is verified by unit/integration
  tests over loopback only

---

## 8. Recommended next work (prioritized)

1. **FILE_CANCEL extension (this document)** — coordinated Android + Mac + protocol doc; small, unblocks
   the last known data-loss-ish wart in the file pipeline
2. **Real-device acceptance pass** — run M0–M9 flows against an actual phone on Wi-Fi (pair, trust,
   notifications, clipboard both ways, file both ways incl. cancel, drop/reconnect). Everything so far is
   loopback-verified only
3. **Notification quick-reply** — ✅ DONE (both platforms). Wire type `0x0031 NOTIFICATION_REPLY`
   (`{"id","text"}`, documented in docs/PROTOCOL.md). Mac: MessageType case,
   `NotificationReply.frame`, ViewModel replyDrafts/sendReply, reply field on hasQuickReply rows,
   3 tests. Android (user-implemented, verified): MessageType `NOTIFICATION_REPLY(0x0031u)`,
   ConnectionManager routing with silent-ignore on parse failure, ConnectionService bridge to
   `LinkNotificationListenerService.instance.handleReply` — looks up active notification by
   `"<sbn.key>_<postTime>"`, injects text into the RemoteInput reply action (with ClipData),
   posts the intent, logs metadata only.
4. **Auto-reconnect with backoff** — ✅ DONE (Mac-side). `ReconnectPolicy` in LinkConnection
   (default 1s/2s/5s/10s, injectable for tests, 4 unit tests); on unexpected drop the session task
   sleeps, replaces the client, and retries the same endpoint up to 4 times with a
   "Reconnecting…" phase; user-initiated disconnects never auto-reconnect; on exhaustion it
   surfaces "Could not reconnect" + resumes mDNS browsing (Retry button also available).
5. **Cryptographic pairing identity** — both apps, wire-breaking: derive a peer key at trust time, sign
   handshake, pin identity in TrustStore; needs protocol versioning/negotiation first
6. **Polish backlog** — non-modal file pickers (window-based), persisted transfer history, clipboard
   send-on-copy behind an explicit user toggle, peers management edge cases (rename, duplicate names)
