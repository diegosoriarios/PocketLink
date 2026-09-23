# Build and Test Instructions

## Prerequisites
- Android Studio Ladybug (2024.2+) or newer
- JDK 17 or JDK 21
- Android SDK Platform API 34+ (min API 29)
- Python 3.8+ (for running the standalone desktop test script)

## Building the Project

From the project root `/Users/diego/Documents/linkmyapp/android`:

### Assemble Debug APK
```bash
./gradlew :app:assembleDebug
```

### Clean and Build
```bash
./gradlew clean :app:build
```

## Running Unit Tests

Run all unit tests:
```bash
./gradlew test
```

Run specific test classes:
```bash
./gradlew test --tests "com.diego.pocketlink.protocol.ProtocolEncoderDecoderTest"
./gradlew test --tests "com.diego.pocketlink.connection.ConnectionManagerTest"
./gradlew test --tests "com.diego.pocketlink.discovery.NsdDiscoveryTest"
./gradlew test --tests "com.diego.pocketlink.clipboard.ClipboardLoopSuppressionTest"
./gradlew test --tests "com.diego.pocketlink.battery.BatteryStatusTest"
./gradlew test --tests "com.diego.pocketlink.notifications.NotificationFilterTest"
./gradlew test --tests "com.diego.pocketlink.files.FileChecksumTest"
```

## Testing Milestone 5 — Chunked File Transfer & Verification

1. **Storage Access Framework & MediaStore**:
   - Outgoing files are picked safely using `ActivityResultContracts.GetContent()`.
   - Incoming files are written safely to the system `Downloads/PocketLink` folder using `MediaStore` (no broad storage permissions required).

2. **Chunking & SHA-256 Integrity Verification**:
   - Files are sliced into 64 KB chunks framed with a 12-byte binary header (`[fileIdHash: 4B][offset: 8B]`).
   - A streaming `MessageDigest("SHA-256")` calculates the hash during chunk streaming and verifies integrity upon final chunk receipt before sending `FILE_ACK` (`0x0042`).

3. **Progress Tracking & Cancellation**:
   - The UI shows real-time progress (`LinearProgressIndicator`) with percentage and byte counts.
   - User can tap **Cancel Transfer** to abort chunk streaming immediately.
