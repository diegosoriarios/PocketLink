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
| Cryptography | CryptoKit (Curve25519, ChaChaPoly, SHA-256) | BouncyCastle (X25519, ChaCha20-Poly1305) |
| Key storage | Keychain (`LinkIdentity`) | `filesDir/pocketlink-identity.json` (Keystore wrapping is an E3 follow-up) |
| Serialization | Codable for control; raw binary for data | `org.json` for control; `ByteBuffer` for data |

## 2. Wire Protocol

- 16-byte header: magic `"LINK"` (4B) · version uint16 · type uint16 ·
  streamId uint32 · payloadLength uint32 — all big-endian, max payload 8 MB.
- Android is the TCP server (default port 52345); the Mac connects out.
- Shipped types (all documented byte-exact in PROTOCOL.md):
  control `0x0001`–`0x0005`, clipboard `0x0010`/`0x0011`, battery `0x0020`,
  notifications `0x0030`–`0x0033`, files `0x0040`–`0x0043`, mirroring
  `0x0050`–`0x0054`, Noise crypto `0x0060`–`0x0062`, `REMOTE_TEXT 0x0064`,
  `OPEN_URL 0x0065`.
- HANDSHAKE carries `protocolVersion: 2`; the header `version` field must be
  `1` (any other → `ERROR 409` + close). Unknown types → `ERROR 400` + keep
  connection. All application frames after C1 are Noise-sealed (header = AAD).

Any new message types must be added to PROTOCOL.md and both decoders in the
same change.

## 3. Shipped

All four original phases are complete (2026-09-30 → 2026-10-07). Summary:

- **Phase A — Connection stability & file transfers.** 12 s heartbeat with
  2-missed-PONG teardown, sleep/wake session recovery, concurrent
  bidirectional transfers with serialized socket writes, ACK timeouts,
  off-main-actor receive writes, persisted transfer history (both platforms),
  non-modal pickers, drag & drop to the popover, Android share-sheet queue.
- **Phase B — Sync features.** Bidirectional clipboard with `CLIPBOARD_ACK`
  and loop suppression ("send on copy" Mac, auto-send Android), notification
  mirroring with replies/actions/persisted store, screen mirroring v1
  (MediaProjection → H.264 → `AVSampleBufferDisplayLayer`, touch injection
  via accessibility service), phone battery indicator in the Mac panel.
- **Phase C — Hardening & transport.** Noise XX encrypted wire with Ed25519
  identity + QR fingerprint pinning (CRYPTO_M1/M2/M3), protocol version
  negotiation, Android keep-alive (Wi-Fi lock, battery-optimization
  whitelist).
- **Phase D — Menu bar v2 & content sharing.** Custom `NSStatusItem` (drop
  overlay, unread badge, progress ring), launch at login, global hotkeys
  (⌥⌘M/⌥⌘S), low-battery alerts, multi-file drop queue, OPEN_URL + Finder
  Services, mirror screenshot + MP4 recording, REMOTE_TEXT keyboard
  forwarding (batched text + backspace/enter via accessibility
  `ACTION_SET_TEXT`).

Tests: Swift suite 135 green (`cd macos/PocketLinkCore && swift test`);
Android 63 green (`./gradlew :app:testDebugUnitTest`).

**Pending real-device validation** (loopback/build-verified only): keyboard
injection across IMEs/fields, screenshot black-frame check, recording
playback, OPEN_URL, multi-file queue reconnect behavior.

## 4. Roadmap — Phase E

### E1 · Mirroring performance (do first, in order)

- **E1.1 Ordered mirror sender (bugfix).** `sendMirrorFrame` currently does
  `scope.launch(Dispatchers.IO)` per frame — coroutines can hit the
  `writeMutex` out of order, so frames reach the Mac reordered and the
  decoder drops them (`pts < lastPresentedPTS`), which reads as "low,
  stuttery fps". Replace with a single consumer: a bounded
  `Channel<Frame>` drained by one `Dispatchers.IO` coroutine. MIRROR_FRAME
  uses `trySend` + drop-oldest (never blocks the encoder callback, never
  reorders, bounds latency under Wi-Fi dips). Payload encoding moves into
  the consumer so the encoder callback stays cheap.
- **E1.2 Quality presets (wire change).** Mac picks a preset in the mirror
  section; parameters ride in the MIRROR_START payload so the phone configures
  the encoder before capture (docs + both decoders in the same change, per §2;
  phone clamps fps to the display refresh rate):
  - *Sharp*: native resolution, 60 fps, 12 Mbps
  - *Balanced* (default): 720p-class, 60 fps, 8 Mbps
  - *Efficient*: 480p-class, 30 fps, 3 Mbps
  VirtualDisplay scales for free when asked for smaller dimensions.
- **E1.3 Mac decode off the main actor.** Annex-B→AVCC conversion and
  `CMBlockBuffer` creation run per frame on the frame-loop actor today; at
  60 fps this risks UI jank. Move parse/convert to a background serial
  queue, keep only `layer.enqueue` (and the recorder's `onSampleBuffer`
  hook, re-dispatched to the main actor) on main.
- **E1.4 Tuning & stats.** I-frame interval 1 s → 2 s (smoother CBR);
  extend the 1 s stats line with encoded fps and average frame size so
  presets can be verified on-device.

### E2 · CI + packaging

- GitHub Actions: ubuntu job (`gradlew :app:testDebugUnitTest :app:assembleDebug`)
  + macOS job (`swift test` + `xcodebuild` build), run on PRs and main.
- Android release flow: signed release APK/AAB via repo secrets
  (base64 keystore), versioned artifacts.
- macOS notarization requires a paid Apple Developer account — blocked until
  then; a plain archive step is still worth wiring up.

### E3 · Robustness batch

- Reconnect: re-resolve the phone when the stored endpoint stops responding
  (IP changes), instead of only retrying the same address; dedupe mDNS vs
  manual entries for the same host:port.
- Trust UI edges: revoke confirmation, device rename, duplicate-name
  suffixing, show trust dates.
- Misc cleanups: Android `data_extraction_rules.xml` template TODO, delete
  empty macOS placeholder folders (`Clipboard/`, `Files/` if still unused).
- Android Keystore wrapping of the identity file (C1 follow-up).

### E4 · Audio mirroring (design first, after E1)

AudioPlaybackCapture → AAC → new `MIRROR_AUDIO 0x0055` + Mac
`AVSampleBufferAudioRenderer`. The risk is A/V sync: audio plays
continuously and clock drift grows over minutes; needs timestamps, a master
clock (video), and drop/repeat "cheap sync" to keep skew < 200 ms. Write the
design into this plan before implementing.

Suggested order: E1.1 → E1.3 → E1.2 → E1.4 → E2 → E3 → E4.

## 5. Critical Pitfalls (carried forward)

1. **Google Play policy traps** — avoid `MANAGE_EXTERNAL_STORAGE` and
   `BIND_ACCESSIBILITY_SERVICE` if targeting Play; restrict storage to
   MediaStore/Downloads and keep remote control (mirroring touch/keyboard)
   side-loaded.
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
6. **Per-frame coroutine launches reorder frames (E1.1)** —
   `scope.launch(Dispatchers.IO)` per frame gives no ordering guarantee even
   behind a write mutex; anything rate-critical needs a single ordered
   consumer with an explicit drop policy.
7. **Surface-input encoders treat `KEY_FRAME_RATE` loosely** — the display
   refresh drives production; verify real fps via decoder-side stats
   (E1.4), never assume the configured number.

## 6. Verification & Tooling

- **macOS build:** `xcodebuild -project macos/PocketLink.xcodeproj -scheme
  PocketLink -configuration Debug build` (set
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if
  `xcode-select` points at CommandLineTools).
- **macOS tests:** `cd macos/PocketLinkCore && swift test` (135).
- **Android build+tests:** `./gradlew :app:testDebugUnitTest :app:assembleDebug`
  from `android/` (63).
- **Caveat:** wire-level changes need a real-device pass before being called
  done; the pending-validation list in §3 tracks what's still open.
