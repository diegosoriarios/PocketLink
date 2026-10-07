# PocketLink — Master Plan

Last updated: 2026-10-07.
This file consolidates and supersedes `planning.md` and `next-steps.md`.
Source of truth for the byte-exact wire protocol: [`macos/docs/PROTOCOL.md`](macos/docs/PROTOCOL.md)
(mirrored in [`android/docs/protocol-spec.md`](android/docs/protocol-spec.md)).

---

## 1. Product & Stack

Privacy-first bridge between a Mac and an Android phone: direct local-network
connection, no backend, no cloud, no relay.

| Layer | macOS client | Android client |
|---|---|---|
| Language | Swift 6 (strict concurrency) | Kotlin 2.x |
| Minimum OS | macOS 14 Sonoma | Android 10 (API 29); target API 34+ |
| UI | SwiftUI + AppKit (`NSStatusItem` menu-bar app) | Jetpack Compose + Material 3 |
| Networking | Network.framework | Raw TCP sockets (server) |
| Cryptography | CryptoKit (Curve25519, ChaChaPoly, SHA-256) | Tink / BouncyCastle (X25519, ChaCha20-Poly1305) |
| Key storage | Keychain (`kSecClassKey`) | Android Keystore |
| Serialization | Codable for control; raw binary for data | `org.json` for control; `ByteBuffer` for data |

Crypto/key-storage rows are the target for Phase C1; the wire is plaintext today.

## 2. Wire Protocol

The original planning sketch (2-byte magic `0x4C4D`, 8-byte header) was
**superseded** during implementation. The shipped framing is:

- 16-byte header: magic `"LINK"` (4B) · version uint16 · type uint16 · streamId uint32 · payloadLength uint32 — all big-endian, max payload 8 MB.
- Android is the TCP server (default port 52345); the Mac connects out.
- Message types `0x0001`–`0x0043` (HANDSHAKE … FILE_CANCEL), documented in
  PROTOCOL.md, including the protocol extensions added beyond the original
  Android app: QR pairing tokens in HANDSHAKE, `NOTIFICATION_REPLY 0x0031`,
  `FILE_CANCEL 0x0043`.

Any new message types (screen mirroring, mirroring touch input) must be added to
PROTOCOL.md and both decoders in the same change, preserving the
unknown-type → ERROR 400 → keep-connection compatibility rule.

## 3. Where We Are

Shipped and verified by unit/integration tests over loopback:

- **Discovery & pairing** — mDNS (`_link._tcp.`) advertise/browse, manual
  IP connect, QR pairing token extension (Mac renders QR → phone scans →
  HANDSHAKE token match → auto-trust; manual trust fallback), persistent
  trust store with revoke.
- **Notifications** — phone → Mac mirroring with quick replies back
  (`NOTIFICATION_REPLY`), notification actions with `hasQuickReply`.
- **Clipboard** — bidirectional text sync (Mac: explicit button; Android:
  auto-send on change) with loop suppression.
- **Files** — chunked (64 KB) SHA-256-verified transfers in both directions,
  FILE_ACK verdicts, FILE_CANCEL with partial cleanup, zero-size handling,
  auto-reconnect with capped backoff (1/2/5/10 s) on the Mac.
- **Connection UX (2026-09-30)** — Mac shows the pairing QR **only** when the
  device cannot be found (QR + background auto-retry, auto-trust on first
  successful connect — no QR in the normal connect flow).
- **Android file UX (2026-09-30)** — send/receive direction labels,
  `VERIFYING → FILE_ACK` verdict flow (`DELIVERED`/`MISMATCH`/`CANCELLED`),
  receiver-side cancel with partial discard, 6 s auto-clear + manual dismiss,
  human-readable sizes, reliable size via `OpenableColumns.SIZE`.
- **Resilience (2026-09-30)** — automatic heartbeat on both platforms
  (12 s PING loop, 2 missed PONGs → teardown → reconnect flow); macOS
  sleep/wake handling (clean disconnect on sleep, session/browse auto-resume
  on wake, expired pairing tokens dropped); macOS drag & drop onto the
  popover; Android Wi-Fi lock + battery-optimization whitelist prompt.

Everything else is roadmap, below.

## 4. Roadmap

### Phase A — Now: connection stability + finish file transfer ✅ COMPLETE (2026-09-30)

- **A1 · Automatic heartbeat (both platforms).** ✅ DONE (2026-09-30)
  12 s app-level PING loop, 2 consecutive missed PONGs → teardown → existing
  reconnect/browse flow. Mac: heartbeat task inside `ConnectionViewModel`
  (starts on `.connected`, cancelled with the session). Android: coroutine in
  `ConnectionManager.handleClient`, tied to the active socket.

- **A2 · macOS sleep/wake handling.** ✅ DONE (2026-09-30)
  `NSWorkspace.willSleepNotification`/`didWakeNotification` observed in
  `ConnectionViewModel`: on sleep the active session (or mDNS browse) is
  captured and torn down without marking a user disconnect; on wake the
  session is restarted with the same endpoint (expired pairing tokens are
  dropped first) or browsing resumes.

- **A3 · File transfer — full completion** (7 sub-items):
  - **A3.1 Concurrent bidirectional transfers.** ✅ DONE (2026-09-30) —
    Android `FileTransferEngine` split into per-direction slots
    (`sendProgress`/`receiveProgress`, `cancelSendTransfer`/
    `cancelReceiveTransfer`); UI shows both rows simultaneously; socket
    writes serialized via a `writeMutex` in `ConnectionManager` so chunks,
    heartbeat and ACKs can no longer interleave on the wire.
  - **A3.2 Send ACK timeout (both).** ✅ DONE (2026-09-30) — 30 s timeout on
    both platforms while waiting for FILE_ACK → failed with "No confirmation
    from receiver" (Android `scheduleAckTimeout`, Mac `scheduleAckTimeout` in
    `ConnectionViewModel`); cancelled on ACK, user cancel, or dismiss.
  - **A3.3 Mac receive writes off the main actor.** ✅ DONE (2026-09-30) —
    `FileReceiver` now delegates chunk writes, hashing and byte counting to a
    private background actor (`FileWriteWorker`) that owns the file handle;
    `begin`/`append` are async and the frame loop awaits them sequentially
    (byte order preserved). Progress still updates on the main actor.
  - **A3.4 Persisted transfer history (both).** ✅ DONE (2026-09-30) — Mac:
    `TransferHistoryStore` actor (TrustStore pattern, `transfer-history.json`
    in Application Support, capped at 50). Android: `TransferHistoryStore`
    singleton persisting JSON in `filesDir` (org.json — the existing
    convention; DataStore skipped to avoid a new dependency), recorded from
    `FileTransferEngine.emit()` on every terminal state before the 6 s
    auto-clear. Both UIs show a "Recent transfers" section with a Clear
    button.
  - **A3.5 Non-modal file pickers (macOS).** ✅ DONE (2026-09-30) —
    `NSOpenPanel`/`NSSavePanel` now use non-modal `begin` completions
    (floating panel, menu-bar window stays responsive); panel references held
    on the view model until completion, with a single-panel-at-a-time guard.
  - **A3.6 macOS drag & drop.** ✅ DONE (2026-09-30) — `.dropDestination(for:
    URL.self)` on the popover with a targeted overlay; sends the first dropped
    file via the existing pipeline.
  - **A3.7 Android share-sheet** ✅ DONE (2026-09-30) — `ACTION_SEND` /
    `ACTION_SEND_MULTIPLE` intent filters on `MainActivity` (singleTop);
    shared URIs queue in the view model and send sequentially via
    `FileTransferEngine.sendFile` once connected, with log feedback.

### Phase B — Next: sync features

- **B1 · Clipboard.** ✅ DONE (2026-09-30) — Mac: "Send on copy" checkbox
  (persisted to `settings.json` in Application Support, 0.5 s pasteboard
  polling via `PasteboardMonitor`); Android: "Auto-send clipboard to Mac"
  switch (persisted to `clipboard-settings.json`). Loop suppression
  hardened on both sides with per-direction markers (remote-applied text is
  never echoed back; local duplicates only suppressed within a 30 s window
  so legitimate re-copies still sync). New `CLIPBOARD_ACK` (0x0011) wire
  type: receiver confirms application, sender shows live status
  ("Clipboard sent… / delivered · time / no confirmation") in the popover;
  Android logs delivery/timeout events. Images remain an open stretch goal
  (needs a framing decision).
- **B2 · Notifications.** ✅ DONE (2026-09-30) — Mac: mirrored notifications
  persist across launches (`NotificationStore` actor, `notifications.json`,
  capped 20) and render grouped per app (newest group first, per-app count).
  New actions per notification: "Copy text" (local) and "Dismiss on phone"
  (new `NOTIFICATION_ACTION` 0x0032 wire type; Android listener resolves the
  id and calls `cancelNotification`). Reply delivery feedback via new
  `NOTIFICATION_REPLY_ACK` 0x0033: the phone reports success/failure after
  firing the reply PendingIntent; the Mac shows per-notification status
  ("Sent… → Delivered ✓ / Failed", 5 s no-confirmation timeout).
  Android protocol-spec table also filled in (0x0031/0x0032/0x0033/0x0043).
- **B3 · Screen mirroring** — v1 (video + touch), started 2026-09-30.
  *Pipeline:* MediaProjection consent → dedicated `MirroringService` FGS
  (type `mediaProjection`, started **before** `createVirtualDisplay` —
  Android 14+ requirement) → MediaCodec `video/avc` low-latency baseline
  (Surface input, 1 s I-frame interval + sync-frame request) → wire types
  0x0050–0x0054 → Mac `AVSampleBufferDisplayLayer` in a dedicated window.
  Sub-items:
  - **B3.1 Protocol + docs** ✅ — MIRROR_START 0x0050 (Mac→phone request),
    MIRROR_STOP 0x0051 (both), MIRROR_CONFIG 0x0052 (phone→Mac:
    dimensions/fps/bitrate + base64 SPS/PPS), MIRROR_FRAME 0x0053
    (phone→Mac: `u64 tsMs + u8 keyframe + u32 len + Annex-B access unit`),
    REMOTE_TOUCH 0x0054 (Mac→phone: `{"action","x","y"}` normalized).
    Frames ≤ 8 MB payload cap (no chunking needed). Both directions can
    initiate; consent dialog always fires on the phone.
  - **B3.2 Android capture** ✅ — `MirroringService` (FGS mediaProjection
    started **before** `createVirtualDisplay`) + `ScreenCaptureEncoder`
    (MediaCodec async, CBR 4 Mbps, KEY_LOW_LATENCY on API 30+), consent via
    `MainActivity` result launcher routed by `MirrorConsentRouter` (activity
    resumed → consent dialog; background → deep-link notification; decline →
    MIRROR_STOP to clear the Mac UI), manual "Start mirroring" button +
    handling of Mac-initiated requests, mirroring auto-stops on disconnect.
  - **B3.3 Mac decode + window** ✅ — `Mirroring/VideoDecoder`
    (Annex-B→AVCC converter, `CMVideoFormatDescription` from SPS/PPS,
    drop-late-frames policy, `AVSampleBufferDisplayLayer`), `MirrorWindow`
    + `MirrorWindowController`, popover toggle with phase
    (idle/requesting/active) + 1 s stats, auto-stop on disconnect/window
    close/10 s request timeout.
  - **B3.4 Touch injection** ✅ (side-loaded only — see §5 pitfall 1) —
    `MirroringAccessibilityService.dispatchGesture()` state machine
    (down/move/up strokes with `willContinue` continuations, single-pointer
    v1), user enables the service in system settings; Mac
    `TouchForwardingView` hit-testing sends normalized REMOTE_TOUCH events.
  - **B3.5 · v2 (parked): audio mirroring** — AudioPlaybackCapture →
    AAC → new MIRROR_AUDIO type + Mac `AVSampleBufferAudioRenderer`.
    Deferred because A/V sync is the risk: audio plays continuously and
    clock drift makes its delay grow over minutes; needs timestamps,
    video-master-clock and drop/repeat "cheap sync" to keep skew
    < 200 ms. Revisit after the real-device pass.
- **B4 · Battery indicator (Mac menu bar)** ✅ DONE (2026-09-30) — the Mac
  now parses BATTERY frames (`BatteryMessage.parse` in LinkProtocol) and
  shows "Phone battery: N% · charging · power save" with a level-mapped SF
  Symbol (battery.0/25/50/75/100, bolt when charging) at the top of the
  connected controls; cleared on disconnect.

### Phase C — Later: hardening, advanced transport & packaging

- **C1 · Encrypted wire + cryptographic identity (biggest item).** ✅ DONE
  (2026-10-02) — Noise XX over X25519/ChaChaPoly/SHA-256
  (`Noise_XX_25519_ChaChaPoly_SHA256`), byte-for-byte compatible
  CryptoKit (macOS) / BouncyCastle (Android) implementations. New CRYPTO_M1/M2/M3
  frame types (0x0060–62); Mac is the initiator, Android the responder;
  application frames sealed payload-only (header = AAD, payloadLength =
  ciphertext size, per-direction 64-bit counters, nonce `4 zero ‖ u64BE`).
  Device identity: Ed25519 key + fingerprint (SHA-256 of Ed25519 pub), bound
  to the X25519 static key via signature inside the handshake payload; QR is
  now `pocketlink://pair?v=2&t=<token>&k=<fingerprint>` — the phone pins the
  scanned fingerprint (mismatch → `ERROR 403` + close) and the Mac verifies
  TOFU/pinned fingerprints in its TrustStore. Plaintext before handshake →
  `ERROR 409`; decrypt failure → `ERROR 401` + close; HANDSHAKE
  `protocolVersion` bumped to 2 (no plaintext fallback; both ends ship
  together). Mac keys in Keychain (`LinkIdentity`), Android keys in
  `filesDir/pocketlink-identity.json` (Keystore wrapping documented follow-up).
  Docs updated in both protocol docs. Tests: Swift suite 121 green incl.
  encrypted loopback integration tests; Android 61 green (Noise vectors,
  tamper tests, encrypted ConnectionManager tests). *Note:* cross-platform
  interop is verified by byte-identical implementations + unit tests; a real
  Mac↔phone pass happens in C5.
- **C2 · Protocol version negotiation.** ✅ DONE (2026-10-01) — the 16-byte
  header `version` field is now validated by both decoders: any value other
  than 1 → `ERROR 409` + close (new `FrameDecodeError.unsupportedVersion` /
  `UnsupportedVersionException`). Both HANDSHAKE payloads now carry
  `"protocolVersion": 2` (bumped by C1); a mismatch also yields `ERROR 409` +
  close (Mac `handleHandshake` guard, Android HANDSHAKE case). HANDSHAKE
  without the field is treated as version 1 and rejected (pre-negotiation
  peers). Documented in both protocol docs; unit tests for decoder rejection +
  handshake parsing on both platforms.
- **C3 · Android keep-alive hardening.** ✅ DONE (2026-09-30) — Wi-Fi lock
  (`WIFI_MODE_FULL_HIGH_PERF`) acquired/released with the foreground service,
  `WAKE_LOCK` + `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permissions, and a
  "Background keep-alive" whitelist prompt in the Android UI.
- **C4 · USB bridge (planning Phase 6 — not started).** Bundled static `adb`,
  `adb forward tcp:…`, USB-first transport priority with Wi-Fi fallback.
- **C5 · Real-device acceptance pass.** *Today:* every milestone is
  loopback-verified only. Run the full matrix (pair, trust, notifications,
  clipboard both ways, files both ways incl. cancel, drop/reconnect, sleep)
  on real hardware.
- **C6 · CI + packaging.** *Today:* local `swift test` / `gradlew` runs only.
  *Build:* CI for both platforms; macOS notarization; Android release flow.
- **C7 · Reconnect/discovery robustness.** Reconnect reuses the same endpoint
  only (never re-resolves a changed phone IP); discovery doesn't dedupe mDNS
  + manual entries.
- **C8 · Trust UI edges.** No rename, no revoke confirmation, no
  duplicate-name handling; show trust dates.
- **C9 · Misc.** Android `data_extraction_rules.xml` still has the template
  TODO; empty macOS placeholder folders (`Clipboard/`, `Files/`,
  `Mirroring/`, `Notifications/`) — delete or fill.

### Phase D — Planned (2026-10-07): menu bar polish, mirroring v2, sharing

Wire changes this phase (both protocol docs + both decoders in the same change,
per §2): new Mac→phone types REMOTE_TEXT 0x0064 (`{"text": "…", "special"?
: "backspace"|"enter"}`) and OPEN_URL 0x0065 (`{"url": "…"}`), JSON payloads,
sealed like all post-C1 frames. Next free codes after crypto's 0x0060–62.

- **D1 · Menu bar & system integration (Mac-only, no wire changes).**
  - **D1.1 Launch at login.** ✅ DONE (2026-10-07) — `SMAppService.mainApp`
    checkbox in the panel footer ("Launch at login", under a divider above
    Quit); `ConnectionViewModel.setLaunchAtLogin` registers/unregisters and
    surfaces errors as panel status text ("Launch at login failed: …").
    *Design note:* the plan originally mirrored the flag into
    `settings.json`, but implementation uses `SMAppService.status` as the
    single source of truth (refreshed on init and after every toggle) — a
    settings.json copy would desync when the user removes the login item
    via System Settings. `.requiresApproval` state shows "Approve PocketLink
    in System Settings → Login Items to activate." Also cleaned 5
    pre-existing unused-`client` binding warnings in `ConnectionViewModel`.
  - **D1.2 Global shortcuts.** ✅ DONE (2026-10-07) —
    `App/GlobalHotKeys.swift`: Carbon `RegisterEventHotKey` + a single
    `kEventHotKeyPressed` handler installed on the application event target
    (no accessibility permission needed); dispatch keyed by `EventHotKeyID`
    and hops to the main actor via `MainActor.assumeIsolated` (Carbon
    delivers app events on the main thread). ⌥⌘M toggles the panel
    (`StatusItemController.togglePanel`, shared with the button click and
    its transient-reopen guard), ⌥⌘S calls `ConnectionViewModel.
    toggleMirroring()` — same semantics as the panel button (starts only
    when connected, cancels requesting/active). Key choices centralized as
    `GlobalHotKeys.togglePanel` / `.toggleMirroring` statics; registration
    failures drop the handler silently. Configurability remains a stretch.
  - **D1.3 Unread badge on the icon.** ✅ DONE (2026-10-07) — red dot
    (7 pt, `StatusItemBadgeDot`, click/drag-transparent via `hitTest → nil`)
    at the top-trailing corner of the status item. Model tracks
    `lastSeenNotificationDate` + `hasUnreadNotifications`, recomputed in a
    central `updateNotifications` setter (receive, load, and clear paths);
    seen-threshold = newest known postTime (never local "now" — phone
    clocks can drift). `StatusItemController` marks seen on popover
    will-show *and* did-close (arrivals while the panel was open count as
    seen); pushes visibility to the dot via
    `ConnectionViewModel.onUnreadNotificationsChanged` callback.
  - **D1.4 Transfer progress on the icon.** ✅ DONE (2026-10-07) — 18 pt
    template ring (`StatusItemController.progressImage`): 2 pt track at 30%
    alpha + round-capped progress arc, redrawn as a template image so menu
    bar tinting handles light/dark/highlighted. Aggregate fraction is
    computed in `ConnectionViewModel.syncTransferProgress` (average across
    sending/awaiting-ack outgoing + receiving incoming transfers; nil when
    idle), invoked from the four transfer-mutation helpers
    (`updateTransfer`, `upsertOutgoing`, `updateOutgoing`,
    `updateOutgoingIfActive`), pushed via
    `onTransferProgressChanged` with a 0.5% update threshold. Icon rendering
    centralized in `refreshIcon()` with priority: drop hover > progress ring
    > plain link icon.
  - **D1.5 Low-battery alert.** ✅ DONE (2026-10-07) — pure decision logic
    lives in LinkProtocol as `BatteryAlertAdvisor` (tested: fires once per
    ≤15% low / ≤5% critical crossing, only while discharging, re-arms above
    a 20% hysteresis band — suite now 130). `ConnectionViewModel` evaluates
    it on every BATTERY frame and posts `UNUserNotificationCenter` local
    notifications ("Phone battery low / critically low — N% remaining"),
    requesting authorization lazily on first alert (`@preconcurrency` import
    bridges the SDK's missing Sendable annotations);
    `NotificationPresenter` (UNUserNotificationCenterDelegate in the app
    delegate) keeps banners visible while the app is active; advisor state
    resets on session teardown so a reconnect re-evaluates.

- **D2 · Mirroring v2.**
  - **D2.1 Keyboard forwarding (hardest item, do last).** ✅ DONE (2026-10-07)
    — new `REMOTE_TEXT 0x0064` Mac→phone type, payload `{"text": "<non-empty
    str>"}` or `{"special": "backspace"|"enter"}` (exactly one key); both
    protocol docs updated. Mac: `TouchForwardingView` now accepts first
    responder on click and forwards `keyDown` — printable text is batched
    (~100 ms flush) into one `.text` frame, delete/return become `.special`
    frames immediately, Cmd/Ctrl combos pass through to the responder chain
    (5 new codec tests; suite 135). Android:
    `MirroringAccessibilityService.dispatchText` → read-modify-write
    `ACTION_SET_TEXT` on the input-focused editable node (code-point-safe
    backspace; no-op logs when there is no focused editable). Best-effort per
    §5 pitfall 5 — clipboard push stays the fallback; real-device pass
    required (field/IME differences, `GLOBAL_ACTION_BACK`/`HOME` stretch
    intentionally not done).
  - **D2.2 Mirror screenshot & recording (Mac-local, no wire changes).**
    ✅ DONE (2026-10-07) — `VideoDecoder` exposes an `onSampleBuffer` hook
    (fired with each ready AVCC sample) plus `currentFormatDescription` and a
    `screenshotPNG()` that renders the display layer into a `CGContext`
    (current displayed frame; popover-independent). New `MirrorRecorder`
    (@MainActor) wraps a passthrough `AVAssetWriter` (.mp4, `outputSettings:
    nil` + `sourceFormatHint`, `expectsMediaDataInRealTime`, session started
    at the first sample PTS; frames dropped when the input is full — same
    drop-late policy as the display). ViewModel: record button starts/stops
    (`Recordings/` in the support dir), screenshot button saves PNG into
    `Screenshots/` and reveals it in Finder; session teardown finalizes any
    open recording; stats loop drives a live "Recording · mm:ss" line
    (`recordingStatusText`, separate from `mirrorStatusText` so the 1 s stats
    refresh can't clobber it). Verified by build (warning-free) — real-device
    pass recommended, especially the screenshot black-frame check.
  - **D2.3 Paste-into-phone.** ✅ DONE (2026-10-07) — v1 shipped with the
    clipboard-sync feature: the "Send clipboard to phone" button in the panel
    pushes Mac pasteboard text via the existing CLIPBOARD type (with ACK +
    "delivered"/"no confirmation" status), zero wire change. Auto-paste into
    the focused phone field remains a stretch riding on D2.1
    (`{"paste": true}`).

- **D3 · Content sharing.**
  - **D3.1 Multi-file drop queue.** ✅ DONE (2026-10-07) — new `.queued`
    state on `OutgoingTransfer` (clock icon, "Queued · size", Cancel removes
    the pending entry); `sendDroppedFiles` queues every dropped URL (rows
    created reversed so the newest-first list reads in drop order) and
    `drainPendingSends` feeds them one at a time through the existing
    `sendFile` pipeline. Drain triggers: send-task defer, prepare failure,
    awaiting-ack cancel, and both `.connected` transitions (queue survives
    a drop + reconnect). `sendFile` itself routes into the queue when busy
    instead of erroring, so picker sends and retries queue too. Queue is
    keyed by row id (same file dropped twice stays independent); teardown
    (`stopSession`) fails queued rows as "Disconnected". No wire changes;
    app-target logic — verified by build, real-device pass recommended.
  - **D3.2 Open on phone.** ✅ DONE (2026-10-07) — new `OPEN_URL 0x0065`
    Mac→phone wire type, payload `{"url": "<str>"}`, sealed post-handshake
    like all application frames; both protocol docs updated. Mac:
    `OpenURLMessage` frame builder + parser in LinkProtocol, URL field +
    "Open on phone" button in connected controls (Enter submits, disabled
    when empty, http/https-only validation with transient status line
    "Opening on phone…"). Android: `MessageType.OPEN_URL` +
    `ConnectionManager` case → `onOpenUrlReceived` → `ConnectionService.
    openOnPhone` fires implicit `ACTION_VIEW` with `FLAG_ACTIVITY_NEW_TASK`
    (scheme re-validated http/https; failures logged). Tests: Swift
    `OpenURLMessageTests` (payload, wire round-trip, foreign-type/empty-url
    rejection — suite now 124); Android `OpenUrlMessageTest` (63 total).
    No ACK in v1 — add one if real-device testing shows silent failures.
  - **D3.3 Finder "Send with PocketLink" (Services).** ✅ DONE (2026-10-07)
    — `NSServices` entry in Info.plist restricted to Finder
    (`NSRequiredContext.NSApplicationIdentifier = com.apple.finder`) with
    `NSSendFileTypes: public.item` and `NSMessage: sendFilesToPhone`;
    `App/ServicesProvider.swift` implements the
    `sendFilesToPhone:userData:error:` method (registered via
    `NSApp.servicesProvider`), reads file URLs (modern `NSURL` objects with
    an `NSFilenamesPboardType` legacy fallback) and feeds them into the
    D3.1 queue — multi-selection queues every file. `sendDroppedFiles` now
    sets a visible "Phone not connected" error instead of silently ignoring
    sends while disconnected (covers icon drop + Services alike). No new
    extension target; verified in the built bundle's Info.plist. Note: the
    first launch may need `pbs -flush` (or a re-login) before macOS picks
    up the new Services entry. Shortcuts/Quick Action support remains a
    stretch.

Suggested order: D1.1 → D1.3 → D1.4 → D3.1 → D3.2 → D1.5 → D1.2 → D3.3 →
D2.2 → D2.3 → D2.1 (quick Mac-only wins first; accessibility injection last).

Verification: extend the Swift suite for REMOTE_TEXT/OPEN_URL parsing +
Mac queue logic; Android unit tests for new decoder cases (§6 commands);
D2.1 and D3.2 are real-device-pass items (C5) before calling them done.

## 5. Critical Pitfalls (carried forward)

1. **Google Play policy traps** — avoid `MANAGE_EXTERNAL_STORAGE` and
   `BIND_ACCESSIBILITY_SERVICE` if targeting Play; restrict storage to
   MediaStore/Downloads and keep remote control (mirroring touch) side-loaded.
2. **Android Doze silently kills TCP** — sockets die with no FIN/RST; always
   rely on application-level heartbeats (10–15 s) to detect half-open
   connections (A1).
3. **macOS local-network privacy** — macOS 15+ prompts repeatedly; binding
   before approval fails silently — explain the permission in onboarding.
4. **Never block the UI on transfers** — background queues on macOS,
   `Dispatchers.IO` on Android (A3.3).
5. **Keyboard injection is IME/field-dependent (D2.1)** —
   `ACTION_SET_TEXT` append fails or misbehaves on some fields/IMEs; always
   ship the clipboard-push fallback and treat the accessibility path as
   best-effort.

## 6. Verification & Tooling

- **macOS build:** `xcodebuild -project PocketLink.xcodeproj -scheme PocketLink
  -destination 'platform=macOS' build` (set
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if
  `xcode-select` points at CommandLineTools).
- **macOS tests:** `cd macos/PocketLinkCore && swift test`.
- **Android build+tests:** `./gradlew :app:testDebugUnitTest :app:assembleDebug`
  from `android/`.
- **Caveat:** until C5 happens, all verification is loopback-only; wire-level
  changes need a real-device pass before being called done.
