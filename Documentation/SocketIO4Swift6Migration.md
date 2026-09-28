# Socket.IO 4 and Swift 6 migration

This is a breaking API/toolchain change, not a new runtime switch.

## Toolchain and deployment

Use Swift 6.4 or newer (Xcode 27 for the Apple SDKs). `Package.swift` requires
`swift-tools-version:6.4` and explicitly selects `swiftLanguageModes: [.v6]`.
Xcode's `SWIFT_VERSION = 6.0` is a language mode, not a compiler version;
`SWIFT_VERSION = 6.4` is not a valid language mode.
Deployment targets remain iOS/tvOS 15 and macOS 12. The watchOS minimum is
raised from 8 to 9 because Xcode 27 rejects a watchOS 8 deployment target.

## Server and configuration

Only Socket.IO 4.x is supported. Remove every `.version(...)` option and every
`"version"` dictionary entry. `SocketIOVersion`, the manager/engine `version`
properties and the obsolete `engineDidSendPing` delegate method are removed.
A dictionary version entry is an explicit configuration error, not silently
ignored. No `.four` option or replacement selector is necessary.

Engine.IO 4 is always used, including when a URL or connect parameter tries to
supply `EIO=3`. Polling uses record separators and `b`-prefixed base64 packets;
WebSocket binary frames are transmitted unchanged. Heartbeats are driven by
server PINGs and answered with PONGs. Upgrade probes still use `2probe`/`3probe`.
The Engine.IO 3 length-prefixed polling parser, binary prefix and client-driven
heartbeat timer have been removed, along with Socket.IO 2 namespace shortcuts.

The Socket.IO 3 and 4 wire protocols are shared. This change does not pretend to
identify a 3.x server from its handshake; 3.x simply is not a supported target.
Missing CONNECT `sid` and malformed legacy CONNECT_ERROR packets are rejected.
Connection State Recovery requires a configured Socket.IO 4.6+ server.

## Removed native compatibility options

Remove `.useCustomEngine`, `.compress`, `.selfSigned` and `.enableSOCKSProxy`.
URLSession is the only backend; compression controls and custom SOCKS routing
are not exposed. Private certificates use `.security(.customTrust(...))` with
explicit trust anchors. Dictionary keys for these options, including the
`customEngine` alias, produce a configuration error even when set to `false`.
The unused engine `compress`, `useCustomEngine`, `enableSOCKSProxy` and
`websocket` properties are removed; use `polling`/`wsConnected` for transport state.

Unsupported upstream tests remain listed with reviewed exclusion reasons in
[the parity inventory](JavaScriptTestInventory.csv). They count as resolved scope
exclusions, not executed Swift tests. Native deflate interoperability tests and
regressions rejecting old protocols/configuration keys remain in the suite.

## Concurrency and asynchronous callbacks

The serial `handleQueue` ownership contract remains. The public manager, client
and engine are not declared `@unchecked Sendable`. Keep application-side access
on the configured serial queue. Internal executor handoffs have narrow audited
wrappers, and URLSession callbacks hop to the owning queue before reading state.
Do not mutate a Foundation payload concurrently with sending or callback use.
The logger facade serializes its own accesses; a custom logger's owner remains
responsible for any external concurrent access to that custom instance.

The async auth-provider overload is now `@Sendable` and returns a `sending`
payload. Capture immutable Sendable values, or obtain a fresh payload from an
actor. Do not return a dictionary containing mutable objects also retained by
another task. The callback-form provider still resolves back on `handleQueue`.

Async acknowledgement methods are `nonisolated(nonsending)` so they inherit
the caller's isolation, including MainActor, and return `sending [Any]`. Received JSON/binary
values are snapshotted on the callback queue and materialized as fresh containers
for the awaiting task. Errors and cancellation still complete once and remove
the pending acknowledgement on its owning queue. This does not turn arbitrary
`[Any]` values into Sendable values for application-created `Task` results.

## Validation

The normal CI selects `xcode-27`, checks the Swift 6.4 toolchain, runs the complete
unit/real-server suite, builds the Swift package for all four Apple SDKs and compares the
parser with the pinned official JavaScript decoder. Historical review evidence
under `Documentation/ReviewEvidence` describes its recorded commit, not this
migration. Socket.IO 2 fixtures and tests are removed, not counted as passing.
