# LinkMyMac-Style App — Full Engineering Plan

## Step 0: Tooling & Foundational Decisions

### Recommended Stack


|Layer	| macOS | Client | Android | Client |
|---|---|---|---|---|
|Language|Swift 6 (Strict Concurrency enabled)|Kotlin 2.x|
|Minimum OS|	macOS 14 Sonoma (for modern MenuBarExtra & Network.framework)	| Android 10 (API 29); recommended target API 34+| 
|UI|	SwiftUI + AppKit (NSApplication, NSStatusItem)|	Jetpack Compose + Material 3|
|Networking|	Apple Network.framework (NWListener, NWConnection)|	Ktor Client (or raw Java NIO / Netty sockets)
|Cryptography|	Apple CryptoKit (Curve25519, ChaChaPoly, SHA-256)|	Google Tink or BouncyCastle (X25519, ChaCha20-Poly1305)
|Key Storage|	macOS Keychain Services (kSecClassKey)| Android Keystore (AndroidKeyStoreProvider)
|Serialization|	Swift Codable for control; raw binary buffers for data|kotlinx.serialization for control; ByteBuffer for data

Plain textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol BuffersPythonRRubySass (Sass)Sass (Scss)SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML

### Core Wire Framing Standard

Do not use raw JSON over raw TCP without length framing — packets will fragment and merge unpredictably. Define this 8-byte fixed binary header across both apps:

Plain textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol BuffersPythonRRubySass (Sass)Sass (Scss)SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML `0                   1                   2                   3     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+    |          Magic (2B)           |           Type (2B)           |    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+    |       Stream ID (2B)          |        Reserved (2B)          |    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+    |                         Payload Length (4B)                   |    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+    |                     Payload Data (N bytes)...                 |    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+`  

*   **Magic:** 0x4C4D (ASCII for LM — LinkMac) to discard garbage traffic immediately.
    
*   **Type:** Control codes (0x0001 auth, 0x0002 ping, 0x0020 clipboard, 0x0030 file chunk, etc.).
    
*   **Stream ID:** Allows multiplexing so a 4 GB file transfer (Stream 2) does not stall a 50-byte clipboard sync (Stream 1).
    

Phase 1: Local Discovery, Pairing & Secure Channel
--------------------------------------------------

### Step 1.1: Mac Listener & Bonjour Advertising

1.  Configure an NWListener in Swift over .tcp. Set listener.port = .any (ephemeral port).
    
2.  Configure Bonjour service advertisement on the listener:
    
    *   Type: \_linkmymac.\_tcp
        
    *   Domain: local.
        
    *   TXT records: deviceId=, v=1.
        
3.  In macOS Info.plist, declare:
    
    *   NSBonjourServices: array containing \_linkmymac.\_tcp.
        
    *   NSLocalNetworkUsageDescription: explain why the app needs local network access.
        

### Step 1.2: Android Discovery Agent

1.  Use Android's NsdManager.
    
2.  Implement NsdManager.DiscoveryListener targeted at \_linkmymac.\_tcp.
    
3.  Upon discovering a matching service, call NsdManager.resolveService() to extract the Mac's local IPv4/IPv6 address and port.
    
4.  **Pitfall:** NsdManager.resolveService() is not thread-safe and can crash if called concurrently. Wrap resolve requests in a sequential FIFO queue (e.g., Kotlin Coroutines Channel).
    

### Step 1.3: Cryptographic Pairing (QR Code Exchange)

1.  **Mac:**
    
    *   On first boot, generate an X25519 key pair (ECDH) and an Ed25519 key pair (signing). Save private keys in Keychain.
        
    *   Generate JSON: { "ip": "<​LanIP>", "port": , "pubKey": "<​Base64>", "id": "<​UUID>" }.
        
    *   Render as NSImage via CIFilter.qrCodeGenerator().
        
2.  **Android:**
    
    *   Integrate CameraX + ML Kit Barcode Scanning to scan the Mac screen.
        
    *   Generate its own X25519/Ed25519 key pairs in Android Keystore.
        
    *   Connect to the scanned IP:Port. Perform authenticated key exchange (Noise Protocol XX pattern or mutual TLS with self-signed pinned certs).
        
    *   Compute shared secret, verify signatures, and save the Mac's public key fingerprint in encrypted SharedPreferences/DataStore.
        
3.  **Outcome Check:** Close both apps, reopen. Android auto-discovers Mac via mDNS, initiates socket, performs handshake verifying stored public keys, and transitions to CONNECTED without the camera.
    

Phase 2: Connection Resilience & Background Keep-Alive
------------------------------------------------------

### Step 2.1: Android Foreground Service & Battery Survival

1.  Create ConnectionService: LifecycleService().
    
2.  Start with startForeground() passing a low-priority, ongoing notification (IMPORTANCE\_LOW).
    
3.  Acquire a WifiLock via WifiManager.createWifiLock(WifiManager.WIFI\_MODE\_FULL\_HIGH\_PERF, "LinkMac:WifiLock").
    
4.  Prompt the user to whitelist the app from battery optimization via Settings.ACTION\_REQUEST\_IGNORE\_BATTERY\_OPTIMIZATIONS.
    
5.  Implement a 10-second heartbeat loop: send Ping (0x0002), expect Pong within 5 seconds. If missed twice, tear down and re-enter discovery/reconnect state.
    

### Step 2.2: macOS Sleep & Wake Handling

1.  Subscribe to NSWorkspace.willSleepNotification and NSWorkspace.didWakeNotification.
    
2.  On sleep: send a clean disconnect packet (0x0005), suspend NWListener.
    
3.  On wake: restart NWListener, re-publish Bonjour.
    

Phase 3: Fast Sync (Clipboard & Battery)
----------------------------------------

### Step 3.1: Universal Clipboard

1.  Define schema: { "type": "text/plain", "content": "..." }.
    
2.  **Mac → Android:** Poll NSPasteboard.general.changeCount. On change, send packet 0x0020. Cache last transmitted hash to avoid re-broadcast loops.
    
3.  **Android → Mac:** Register ClipboardManager.OnPrimaryClipChangedListener.
    
    *   **Caveat:** Android 10+ blocks background clipboard reading — only readable in foreground or as default IME.
        
    *   _Workaround:_ Quick Settings Tile ("Send Clipboard to Mac") or intercept via notification action.
        

### Step 3.2: Battery Sync

1.  Register a dynamic BroadcastReceiver for Intent.ACTION\_BATTERY\_CHANGED.
    
2.  Read BatteryManager.EXTRA\_LEVEL, EXTRA\_SCALE, EXTRA\_PLUGGED.
    
3.  On ≥1% change or charging toggle, send packet 0x0010.
    
4.  Render SF Symbol battery indicator in the macOS menu bar popover.
    

Phase 4: Notification Interception & Native Replies
---------------------------------------------------

### Step 4.1: Android Notification Listener

1.  Extend NotificationListenerService.
    
2.  Bind with android.permission.BIND\_NOTIFICATION\_LISTENER\_SERVICE in manifest.
    
3.  Guide user to grant access via ACTION\_NOTIFICATION\_LISTENER\_SETTINGS.
    
4.  In onNotificationPosted(sbn):
    
    *   Filter out sbn.isOngoing and your own app's notification.
        
    *   Extract title (EXTRA\_TITLE), body (EXTRA\_TEXT), and app icon (compress to PNG/WebP bytes).
        
    *   Check sbn.notification.actions for remoteInputs to detect quick-reply support; cache the PendingIntent keyed by a generated notification UUID.
        
    *   Send packet 0x0015.
        

### Step 4.2: macOS Native Display & Reply Dispatch

1.  On packet 0x0015, build a UNMutableNotificationContent.
    
2.  Attach icon via UNNotificationAttachment.
    
3.  If canReply == true, set category with UNTextInputNotificationAction.
    
4.  Submit via UNUserNotificationCenter.current().add(request).
    
5.  In the delegate, handle text reply responses and send action packet 0x0016 back to Android with notifId and replyText.
    
6.  On Android, look up the cached PendingIntent/RemoteInput, build the reply bundle via RemoteInput.addResultsToIntent(), and fire pendingIntent.send().
    

Phase 5: High-Performance File & Photo Transfer
-----------------------------------------------

### Step 5.1: File Streaming Protocol

1.  **Init (0x0030):** { "fileId": "<​UUID>", "name": "video.mp4", "size": 1548201, "sha256": "..." }.
    
2.  **Data (0x0031):** Fixed 64 KB binary chunks framed with fileId and chunkIndex.
    
3.  **Ack/Done (0x0032):** Receiver verifies SHA-256, then atomically renames from .tmp to final name.
    

### Step 5.2: macOS Drop Zone

1.  Use SwiftUI .onDrop(of: \[.fileURL\], isTargeted: ...).
    
2.  Stream via FileHandle in 64 KB slices without blocking the main actor.
    

### Step 5.3: Android Storage Handling

1.  Target MediaStore.Downloads or app-specific external files directory to avoid MANAGE\_EXTERNAL\_STORAGE.
    
2.  Implement ACTION\_SEND/ACTION\_SEND\_MULTIPLE intent filters to accept shared photos/files from Gallery.
    

Phase 6: USB Bridge Fallback (Zero-Config Cable Mode)
-----------------------------------------------------

1.  **Mac:**
    
    *   Bundle a static adb binary inside the app (Contents/Resources/adb).
        
    *   Detect USB device connections via IOKit or polling adb devices.
        
    *   Run adb forward tcp:54321 tcp:54321 and connect to 127.0.0.1:54321.
        
2.  **Android:** No change needed — listening on 0.0.0.0:54321 accepts loopback connections forwarded over USB.
    
3.  **Mac Transport Manager:** Prioritize USB for high-throughput traffic when plugged in; fall back to Wi-Fi when unplugged.
    

Phase 7: Screen Mirroring (Advanced Milestone)
----------------------------------------------

Do not attempt until Phases 1–5 are stable.

1.  **Android Screen Capture:**
    
    *   Request consent via MediaProjectionManager.createScreenCaptureIntent().
        
    *   Feed VirtualDisplay into MediaCodec (video/avc, low-latency baseline profile, immediate I-frames).
        
2.  **Streaming:** Read NAL units (SPS, PPS, keyframes, deltas), stream as packet type 0x0040 on a dedicated channel.
    
3.  **macOS Display:** Feed NAL units into AVSampleBufferDisplayLayer for hardware-accelerated, low-latency rendering.
    
4.  **Touch Injection:**
    
    *   Capture mouse events in the Mac display window, normalize to (0.0–1.0) coordinates, send via 0x0041.
        
    *   Android executes via AccessibilityService.dispatchGesture().
        

Critical Pitfalls & Things to Avoid
-----------------------------------

1.  **Google Play Store Policy Traps:** Avoid MANAGE\_EXTERNAL\_STORAGE and BIND\_ACCESSIBILITY\_SERVICE if targeting Play Store — restrict storage to MediaStore/Downloads, and make remote control optional/side-loaded.
    
2.  **Android Sleep/Doze Death:** TCP sockets disconnect silently during Doze with no FIN/RST. Always use application-level heartbeats (10–15s) to detect half-open sockets.
    
3.  **Local Network Privacy on macOS:** macOS 15+ shows local network permission prompts more often. Binding sockets before approval fails silently — show onboarding explaining the permission need.
    
4.  **UI Blocking on Large Transfers:** Never process network chunks on the main thread/actor. Use a dedicated background queue on macOS and Dispatchers.IO with non-blocking channels on Android.
    

Execution Timeline
------------------

SprintFocusDeliverable**Sprints 1–2**Networking & PairingAuto-discovery via Bonjour/mDNS, QR pairing, mutual auth, stable heartbeat.**Sprint 3**Quick WinsUniversal clipboard (text) and battery/charging sync.**Sprints 4–5**NotificationsNotification forwarding, app icons, and interactive notification replies.**Sprints 6–7**File TransferChunked file transfer, checksum validation, and Android share sheet.**Sprint 8**USB TunnelADB/USB port forwarding fallback for zero-latency/offline use.**Sprints 9–11**Media & MirroringMediaProjection → MediaCodec → Metal video window + touch injection.**Sprint 12**Polish & PackagingmacOS notarization, Android permission onboarding flows, background power tuning.

Recommended Implementation Order
--------------------------------

*   **Week 1:** Phase 1 — Bonjour discovery, QR generation & scan, raw TCP handshake.
    
*   **Week 2:** Phase 2 — Android Foreground Service, Heartbeats, Auto-reconnect on LAN.
    
*   **Week 3:** Phase 3 — Clipboard loop-detection & Menu Bar battery sync.
    
*   **Week 4:** Phase 4 — Android notification listening & Mac interactive replies.
    
*   **Week 5:** Phase 5 — Chunked file sending & macOS drag-and-drop.
    
*   **Week 6:** Phase 6 — Bundled ADB & automatic USB port-forwarding.
    
*   **Week 7+:** Phase 7 — Screen mirroring via MediaProjection and AVSampleBufferDisplayLayer.
