# PocketLink — macOS Client

Privacy-first macOS companion for the PocketLink Android app. Connects directly
over the local network; no backend, cloud account, or relay.

- Swift 6 (strict concurrency), SwiftUI + AppKit menu-bar app
- Network.framework, CryptoKit, UserNotifications
- Minimum macOS 14 Sonoma
- Wire protocol: see [docs/PROTOCOL.md](docs/PROTOCOL.md)

## Layout

| Path | Contents |
|---|---|
| `PocketLink/` | App target: `App/` (entry point), `UI/`, `Notifications/`, `Clipboard/`, `Files/`, `Mirroring/` |
| `PocketLinkCore/` | Local Swift package: `LinkProtocol`, `LinkConnection`, `LinkDiscovery`, `LinkPairing`, `LinkSecurity` + `LinkCoreTests` |
| `docs/` | Protocol specification |

## Build & run (Xcode)

1. Open `PocketLink.xcodeproj` in Xcode (Swift 6 toolchain required).
2. Select the **PocketLink** scheme and press Cmd+R.
3. The app appears as a menu-bar item (no Dock icon): status + Quit.

## Build & test (command line)

If `xcodebuild` points at CommandLineTools instead of Xcode:

```
sudo xcode-select -s /Applications/Xcode.app
```

Then:

```
xcodebuild -project "PocketLink.xcodeproj" -scheme "PocketLink" \
  -destination 'platform=macOS' build

cd PocketLinkCore && swift test
```

## Notes

- App Sandbox is enabled with incoming/outgoing network entitlements.
- The app is menu-bar-only (`LSUIElement`).
- First connection attempts on macOS 15+ trigger the Local Network privacy
  prompt; accept it.
- Never log private keys, clipboard contents, notification bodies, or file contents.
