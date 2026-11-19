# Socket.IO-Client-Swift 17.2.0

Release dated 2026-11-19, distributed through Swift Package Manager with the
immutable [`v17.2.0` tag](https://github.com/kaeferfreund/socket.io-client-swift/releases/tag/v17.2.0).
Requires Swift 6.2 / Xcode 26 or newer; deployment targets remain iOS/tvOS 15, macOS 12 and
watchOS 9. Socket.IO 4 / Engine.IO 4 over polling and WebSocket remain the protocol scope.

## Toolchain floor

- `Package.swift` now declares `swift-tools-version:6.2` instead of `6.4`, so the
  package resolves and builds with Xcode 26.x as well as Xcode 27.
  Upstream: socketio/socket.io-client-swift#1527.
- The package still selects `swiftLanguageModes: [.v6]`. Swift 6 language mode is
  required on every supported toolchain.
- There are no source, API or wire-behavior changes relative to 17.1.0.

## Compatibility notes

Applications on Xcode 27 need no changes and can move from 17.1.0 to 17.2.0 directly.

Applications on Xcode 26.x must resolve 17.2.0 or later. Releases up to and including
17.1.0 declare `swift-tools-version:6.4` and fail to resolve with an older toolchain;
a `from: "17.0.0"` or `from: "17.1.0"` requirement selects 17.2.0 after
**File → Packages → Update to Latest Package Versions** or `swift package update`.

## Validation

The release candidate is validated by the repository's current release workflow:
the native suite and real-server tests, independent SPM consumers, Thread Sanitizer,
strict concurrency, Apple SDK builds, protocol proofs, parser parity, pinned upstream
client suites, documentation checks and repository hygiene. The Swift jobs in that list run on Xcode 27.

The new `swift-tools-floor` job additionally selects the oldest installed Xcode whose
Swift matches the `swift-tools-version` in `Package.swift` (Xcode 26.0, Swift 6.2.0)
and runs the package build, both independent consumers, the README quick start and the
complete unit and real-server suite with it. Thread Sanitizer, strict concurrency,
the Apple SDK destination builds and the decoder differential run on Xcode 27 only.

On Swift 6.2 the test targets emit five Sendable-capture warnings that Swift 6.4 does
not report. The library sources produce no warnings on either toolchain.

SDK compilation is not physical iOS/watchOS runtime validation. The release does not
claim complete JavaScript parity or physical-device background/network-transition
validation.
