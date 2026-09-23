# PocketLink

Privacy-first bridge between a Mac and an Android phone. The two clients connect
directly over the local network (or via mDNS discovery) — no backend, no cloud
account, no relay. The Mac mirrors the phone's notifications (with quick replies),
syncs the clipboard, and transfers files in both directions.

## Repository layout

This is a monorepo containing both clients:

| Path | Project | Stack |
|---|---|---|
| [`macos/`](macos/) | macOS menu-bar client | Swift 6 (strict concurrency), SwiftUI + AppKit, Network.framework, CryptoKit — macOS 14+ |
| [`android/`](android/) | Android client | Kotlin, Jetpack Compose + Material 3, Gradle Kotlin DSL |
| `planning.md` | Full engineering plan and roadmap | |
| `next-steps.md` | Current status, known limitations, prioritized next work | |

## Features

- **Discovery & pairing** — Bonjour/mDNS (`_linkmymac._tcp`) discovery with QR-based pairing and a trust store
- **Notifications** — phone notifications mirrored to native Mac notifications, with quick replies that dispatch back to the phone
- **Clipboard sync** — text clipboard between devices (explicit send on the Mac, auto-send on the phone)
- **File transfer** — chunked, SHA-256-verified transfers in both directions, including drag-and-drop on macOS
- **Resilience** — heartbeats, auto-reconnect with capped backoff, foreground service + Wi-Fi lock on Android

The wire protocol (binary framing with magic bytes, message types, and stream IDs
for multiplexing) is shared by both apps and documented in
[`macos/docs/PROTOCOL.md`](macos/docs/PROTOCOL.md) and
[`android/docs/protocol-spec.md`](android/docs/protocol-spec.md).

## Building

Each project keeps its own build tooling and instructions:

- **macOS:** open `macos/PocketLink.xcodeproj` in Xcode, or see
  [`macos/README.md`](macos/README.md) for command-line build and
  `swift test` in `PocketLinkCore/`.
- **Android:** see [`android/docs/build-and-test.md`](android/docs/build-and-test.md)
  (standard Gradle wrapper: `./gradlew` from `android/`).

## Notes

- Each subproject has its own `.gitignore` (Swift/Xcode and Android/Gradle
  respectively); git applies nested `.gitignore` files to their own directory subtree.
- The Mac app is menu-bar-only (`LSUIElement`) and sandboxed with network entitlements.
- Never log private keys, clipboard contents, notification bodies, or file contents.
