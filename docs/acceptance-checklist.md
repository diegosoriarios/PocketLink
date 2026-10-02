# PocketLink — Real-Device Acceptance Checklist (C5)

First true Mac↔phone validation. Everything before this was loopback-verified
only — most importantly the Swift(CryptoKit) ↔ Kotlin(BouncyCastle) Noise XX
interop. Work top to bottom; tick the boxes as you go and note failures
inline. After the pass: record results in `PLAN.md` (C5) and fix what failed.

**Builds used for this pass** (rebuild fresh before starting):

| Artifact | Command | Output |
|---|---|---|
| Android APK | `./gradlew :app:assembleDebug` (from `android/`) | `android/app/build/outputs/apk/debug/app-debug.apk` |
| macOS app | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PocketLink.xcodeproj -scheme PocketLink -destination 'platform=macOS' build` (from `macos/`) | `~/Library/Developer/Xcode/DerivedData/PocketLink-*/Build/Products/Debug/PocketLink.app` (or just Cmd+R in Xcode) |

Unit-suite baselines at time of writing: Swift 121/121, Android 61/61.

---

## 0. Setup

### Phone (Android 10+, API 29+)
- [ ] `adb install -r android/app/build/outputs/apk/debug/app-debug.apk`
- [ ] Launch PocketLink → **Connection Engine** card → **Start Service**.
      Expect: "Listening & Advertising (mDNS) on network…", a Port (52345) and the phone's IP addresses shown.
- [ ] Grant when prompted (or via the cards' buttons):
  - [ ] **Camera** (needed by the QR scanner card)
  - [ ] **Notifications** (API 33+ runtime prompt)
  - [ ] **Notification Listener access** — "Notification Forwarding" card → *Enable Notification Access* (system Settings toggle)
  - [ ] **Accessibility** — "PocketLink Remote Control" enabled in system Settings (needed for touch injection later)
  - [ ] **Background keep-alive** — battery-optimization whitelist button in "Clipboard & Battery Synchronization" card
- [ ] Note the phone's Wi-Fi IP from the Connection Engine card: ______________

### Mac
- [ ] Launch PocketLink (menu-bar app — **no Dock icon**, look for the link icon in the menu bar).
- [ ] macOS 15+: accept the **Local Network** privacy prompt on the first
      connection attempt (before approval, binds fail silently).
- [ ] **Trusted devices** section: for a clean pass, **Revoke** any old entries.

### Network notes
- Phone and Mac on the same Wi-Fi; mDNS service type is `_link._tcp.`
  (service name `Link-<model>`). Multicast must not be blocked by the AP.
- QR pairing tokens expire after **5 minutes** on both sides.

### Debug tooling (open these before starting)
- Phone: **Event Log** card (bottom of ConnectionScreen, newest first) — primary phone-side diagnostic.
- Mac: inline captions in the popover (last ping RTT, `lastDeviceError` line).
- Optional: `adb logcat | grep -iE "pocketlink|linkmyapp"` and
  `log stream --predicate 'process == "PocketLink"'` in a terminal.

---

## Phase 1 — Crypto-specific (the reason for this pass)

### 1.1 First connect + TOFU (manual trust path)
1. Mac popover → **Nearby devices** → tap the phone's row.
   (Or type the phone IP + port and hit **Connect manually**.)
2. Expect the QR pairing card to appear (peer untrusted) with
   **Trust manually instead** / **Cancel** buttons.
3. Tap **Trust manually instead**.

Expected:
- [ ] Mac reaches connected state; **Ping** button works; "Last ping: N ms" caption appears.
- [ ] Phone Event Log: `Encrypted channel established (peer fingerprint <16 hex>…)` — **record the fingerprint prefix**: ______________
- [ ] Mac **Trusted devices** now lists the phone (TOFU fingerprint pinned at connect).
- [ ] Phone battery caption appears on the Mac within seconds.

### 1.2 QR v2 pairing (token + fingerprint pin)
1. Mac: **Revoke** the phone in Trusted devices → QR card reappears
   (`pocketlink://pair?v=2&t=…&k=…`).
2. Phone: **Scan Pairing Code** (QR Code Pairing card) → grant camera → scan.
3. Let the Mac's background retry complete the connection (token still valid).

Expected:
- [ ] Phone Event Log: `Scanned pairing QR code. Waiting for Mac handshake...`
- [ ] Connection completes; phone Event Log: `Paired via QR with MacBook …` (or similar) and the encrypted-channel line with the **same** fingerprint prefix as 1.1.
- [ ] Mac: connected without further prompts (auto-trust via token match); QR card gone.
- [ ] Retry fails (token single-use): scan nothing, revoke + re-pair later is fine.

### 1.3 Mac-side identity-change detection (Android reinstall)
1. Note current state is working (from 1.2).
2. `adb uninstall com.diego.pocketlink` (wipes the phone identity in `filesDir/`).
3. Reinstall + **Start Service**, then connect from the Mac (trusted entry still points at the old identity).

Expected:
- [ ] Mac shows: `Device identity changed since pairing — remove the device and pair again` and disconnects.
- [ ] Phone Event Log shows a fresh fingerprint prefix, different from 1.1: ______________
- [ ] Cleanup: Mac **Revoke** the stale entry; re-pair via 1.2 (QR) to restore a working state.

### 1.4 Phone-side pin rejection (`ERROR 403`)
Purpose: phone rejects a Mac whose identity no longer matches the scanned QR's `k=`.

1. Mac: **Revoke** phone → QR appears (pins the Mac's **current** identity A).
2. Phone scans the QR **now** (pin = A, token pending, 5 min).
3. Immediately: phone → **Stop Service** (or toggle Wi-Fi off) so the Mac's
   handshake can't complete — the pin must stay pending. Mac retries fail: fine.
4. Quit the Mac app. Reset its identity:
   ```
   security delete-generic-password -s PocketLink -a noise-static-x25519
   security delete-generic-password -s PocketLink -a identity-ed25519
   ```
5. Relaunch the Mac app (new identity B; phone still revoked → QR path, ignore it).
6. Phone → **Start Service** → Mac auto-connects.

Expected:
- [ ] Phone Event Log: `Peer fingerprint mismatch: QR pinned <A…>…, received <B…>…` and the connection is closed.
- [ ] Mac: connection fails/disconnects (no encrypted session).
- [ ] Cleanup: re-pair via 1.2.

### 1.5 Plaintext rejection (`ERROR 409`)
1. Phone: **Start Service**, idle (no Mac connected is fine either way).
2. From the Mac:
   ```
   printf 'LINK\x00\x01\x00\x02\x00\x00\x00\x01\x00\x00\x00\x1b{"timestamp":1719000000000}' | nc -w 3 <PHONE_IP> 52345 | hexdump -C
   ```

Expected:
- [ ] A raw ERROR frame comes back: `…00 05 …` type 0x0005, payload `{"code":409,"message":"Encrypted transport required"}`, then the connection closes (nc exits).
- [ ] Phone Event Log: `Rejected plaintext frame before encrypted channel was established`.

### 1.6 Drop/reconnect over crypto
1. Connected state (from 1.2 re-pair).
2. Toggle phone Wi-Fi off → on (or toggle Airplane mode).

Expected:
- [ ] Mac detects the loss within ~12–36 s (heartbeat; Doze can delay this — not a bug).
- [ ] Auto-reconnect succeeds with a fresh Noise handshake; PING works again.
- [ ] No decryption errors in the phone Event Log after reconnect (fresh counters).
- [ ] Note: reconnect reuses the same IP only (known C7 limitation) — if the phone's IP changed, reconnect from the Mac manually.

---

## Phase 2 — Feature matrix (regression over the encrypted wire)

Run with the paired/trusted state from Phase 1.

| # | Test | Steps | Expected | ✓ |
|---|---|---|---|---|
| 2.1 | Notifications mirror | Send yourself a message/notification on the phone | Appears in the Mac popover, grouped per app; battery-style caption row intact | ☐ |
| 2.2 | Quick reply | Reply to a `hasQuickReply` notification from the Mac (text field + paper plane) | Phone posts the reply; Mac status: `Sent… → Delivered ✓`; phone Event Log shows the reply fired | ☐ |
| 2.3 | Dismiss on phone | **Dismiss on phone** on a notification | Notification cancelled on the phone | ☐ |
| 2.4 | Clipboard phone→Mac | Copy text on the phone → **Sync Clipboard Now** | Mac caption `Clipboard received…`; paste on Mac works | ☐ |
| 2.5 | Clipboard Mac→phone | **Send clipboard to phone** (and with **Send on copy** checked, Cmd+C something) | Text lands on the phone; `delivered` status on the Mac; no echo loop when auto-send is on | ☐ |
| 2.6 | File phone→Mac | **Send File to Mac** (a few MB) | Progress row → `DELIVERED`; Mac **Save…** → file intact (sizes match) | ☐ |
| 2.7 | File Mac→phone | **Send file to phone…** (or drag & drop a file onto the popover) | `DELIVERED` on the Mac; phone saves to Downloads/PocketLink, `VERIFYING → DELIVERED` row | ☐ |
| 2.8 | File cancel (sender) | Start a large file send → cancel mid-transfer | Both UIs show `CANCELLED`; partial file discarded on the receiver; connection survives | ☐ |
| 2.9 | Share sheet | Android system share → PocketLink (while connected) | File queued and sent after connect | ☐ |
| 2.10 | Battery | Toggle phone charging / power save | Mac battery caption + SF Symbol update | ☐ |
| 2.11 | Mirroring | **Mirror phone screen** on Mac → accept MediaProjection on phone | Mirror window shows the screen; fps stats caption; **Stop mirroring** works from both sides | ☐ |
| 2.12 | Touch injection | With mirroring active, tap/swipe in the mirror window | Phone reacts; requires the Accessibility service enabled in setup | ☐ |
| 2.13 | Sleep/wake | Let the Mac sleep ~30 s, wake it | Clean disconnect on sleep; session auto-resumes on wake; PING healthy again | ☐ |
| 2.14 | Heartbeat kill | Enable airplane mode on the phone for ~1 min → off | Mac detects loss via missed PONGs (no hang), then auto-reconnects | ☐ |

---

## Results

| Phase | Pass | Fail | Notes |
|---|---|---|---|
| 1.1–1.6 crypto | | | |
| 2.1–2.14 features | | | |

Failures → capture: phone Event Log screenshot/copy, Mac `lastDeviceError`
caption, `adb logcat` tail, and the exact step number. Then fix → rebuild →
re-run only the failed items.

## Known limitations (not bugs — do not file)
- Reconnect reuses the same endpoint only (C7); discovery doesn't dedupe mDNS
  + manual entries (C7).
- No rename / revoke confirmation / duplicate-name handling in Trusted
  devices (C8).
- Doze can silently kill TCP; heartbeat-based detection takes 12–36 s.
- Android identity keys are stored unencrypted in `filesDir/`
  (Keystore wrapping is a documented follow-up) — uninstalling resets identity.
- Audio mirroring is parked (B3.5).
