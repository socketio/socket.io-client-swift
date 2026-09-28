# Why this fork?

[Documentation index](../README.md) · [Project overview](../../README.md) · [Migration](Migration.md)

## The short explanation

This fork started because bugs in the original Swift stack caused problems in our
production applications. Both the official Swift client and its Starscream
WebSocket dependency had stopped receiving new default-branch commits in 2024,
and we needed a path to fixes rather than more application-specific workarounds.
We also needed our web and iOS clients to follow the same supported Socket.IO
behavior and to have access to important features missing from the Swift client.

The goal is to continue that work: fix production-relevant defects, replace
Starscream with native Apple networking, reduce differences from the JavaScript
client, add missing capabilities and make the result more thoroughly testable.
AI-assisted development helps with the investigation and test work; reproducible
checks, not the use of AI itself, are the evidence for correctness.

**The official Swift client already supports Socket.IO 4 and Swift Package Manager.**
Neither is, by itself, a reason to fork. This is an independent community
continuation, not an official Socket.IO release or an endorsement by its maintainers.

## What was compared

Reviewed on **2026-09-19** against these source snapshots:

| Project | Latest default-branch commit observed | Latest published release observed |
| --- | --- | --- |
| Official Swift client | [`42da871`][upstream-head], **2024-10-01** | [`v16.1.1`][upstream-release], **2024-10-01** |
| Starscream | [`c6bfd1a`][starscream-head], **2024-03-07** | [`4.0.8`][starscream-release], **2024-03-07** |

This fork was inspected at [`5f6abcf`][fork-head], before this documentation-only
revision. Source links below are pinned to those snapshots. The maintenance dates
record the default-branch histories and release listings checked on the review
date, not a formal abandonment announcement or a prediction about future work.

The separate [JavaScript parity audit](../../PARITY.md) compares a pinned
`socketio/socket.io` JavaScript implementation, not the official Swift repository.
The official Swift repository is the implementation we are continuing; the
JavaScript client is the behavior reference for the supported protocol features.

## The differences that matter

### 1. Continue development and address production bugs

The original Swift stack caused production problems for us. With no newer commit
on the official client's default branch since October 2024 at the review date,
waiting for an upstream release was not a sufficient maintenance strategy for
our applications. The fork lets us develop fixes in the library and add focused
regressions instead of maintaining a growing set of application-level patches.

The upstream issue tracker also contains unresolved user reports such as
[an acknowledgement-handling crash in 16.1.1][upstream-ack-issue]. That is a user
report, not an independently established root cause or a claim that this fork
fixes every upstream issue. Our own acceptance evidence is the
[native regression and real-server testing](../Development/Testing.md).

### 2. Replace Starscream with native Apple networking

The original client's [package manifest][upstream-package] depends on Starscream.
That dependency had its own maintenance gap, with its latest observed
default-branch commit and release both in March 2024. Recurring problems in the
Starscream-based transport were another reason for us to change the stack rather
than continue carrying that dependency.

Apple already supplies native WebSocket APIs, including
[`URLSessionWebSocketTask`][apple-websocket]. This fork uses that API for WebSocket
and a separate `URLSession` for HTTP long-polling, with no third-party Swift
packages. The Socket.IO and Engine.IO layers remain part of this library:
**a native WebSocket API alone is not a Socket.IO client**.

The [native transport migration](../NativeWebSocketTransport.md) covers TLS,
cookies, queue ownership and removed settings. Replacing the transport removes
the Starscream dependency; it does not imply that Apple's stack or this fork is
bug-free, or establish a measured performance or security advantage.

### 3. Make web and iOS behavior more consistent

Sharing a Socket.IO server does not automatically give the JavaScript and Swift
clients the same lifecycle and delivery semantics. Unexpected differences mean
separate application logic, harder-to-reproduce failures and different user
experiences between the web and native app.

One concrete example is `reconnect`. In the inspected original Swift client,
[`setReconnecting(reason:)`][upstream-client] emits it when the socket enters the
reconnecting state, carrying a reason. The JavaScript manager uses `reconnect`
for a **successful** reconnection, carrying the attempt number. This fork adopts
that success meaning and documents the breaking change in the
[connection lifecycle guide](Connections.md#reconnection). The old manager also
reports remaining attempts for `reconnectAttempt`; the fork follows the
JavaScript attempt-number semantics instead. [Original manager][upstream-manager]

The parity work also covers pending-acknowledgement cleanup on connection loss,
send buffering, retry ordering, transport selection and parser behavior.
[PARITY.md](../../PARITY.md) connects the claims to pinned JavaScript declarations,
native assertions and execution evidence. The aim is shared behavior where the
platforms support it, **not** an identical Swift API or an unqualified claim of
100% JavaScript equivalence. Intentional bounds, API differences and unsupported
features remain explicit.

### 4. Bring missing client features to Swift

The inspected original implementation does not provide connection state recovery,
a per-CONNECT authentication provider, an ordered acknowledgement retry queue or
an async acknowledgement entry point. This fork implements those capabilities:

| Capability | Application benefit | Guide |
| --- | --- | --- |
| Connection state recovery | Reuse a recoverable session and replay missed events when the server supports it. | [Connections](Connections.md) |
| Dynamic authentication | Obtain the current credentials for each connection attempt, including reconnects. | [Connections](Connections.md) |
| Ordered acknowledgement retries | Retry acknowledged operations through a defined queue rather than separate application timers. | [Acknowledgements](Acknowledgements.md) |
| Cancellable async/await acknowledgements | Await an acknowledgement with timeout and cancellation handling in Swift code. | [Acknowledgements](Acknowledgements.md) |

These are concrete additions, not reasons to describe basic Socket.IO 4 or SPM
support as unique to the fork. The source comparison below separates existing
upstream support from the added behavior.

### 5. Use AI assistance and modern validation to inspect more of the implementation

AI-assisted code review, implementation comparison and regression-test development
make it practical for this project to investigate more edge cases and expand its
validation. AI is a development aid, not an authority on protocol correctness;
a plausible explanation or generated test does not establish the desired behavior.

The [CI workflow][fork-ci] makes the checks inspectable: native regression and
real-server tests, mapped JavaScript assertions checked against tests that actually
passed, parser differentials against pinned upstream code, Thread Sanitizer,
strict-concurrency checks, four Apple SDK builds and independent SPM consumers.
The README example is also compiled and initialized as a consumer.

Those techniques are not all new, and we do not claim they were unavailable to
earlier maintainers. The opportunity is to combine them with AI-assisted analysis
to extend this project's verification. Test results are scoped evidence, not a
warranty, a promise of future support or a substitute for validating an application's
own production scenarios. See [the testing guide](../Development/Testing.md).

### Source-level comparison

| Area | Official Swift snapshot | This fork's snapshot |
| --- | --- | --- |
| Server compatibility | Advertises Socket.IO 2.x, 3.x and 4.x support. [README][upstream-readme] | Supports and tests Socket.IO 4.x / Engine.IO 4 only. [Migration][fork-migration] |
| WebSocket implementation | Declares a Starscream dependency starting at 4.0.8. [Manifest][upstream-package] | Uses `URLSessionWebSocketTask` and a separate polling `URLSession`; no third-party Swift dependencies. [Transport][fork-transport], [manifest][fork-package] |
| Swift baseline | Declares tools version 5.4; no explicit Swift 6 language-mode setting in the manifest. [Manifest][upstream-package] | Declares tools version 6.4 and `swiftLanguageModes: [.v6]`. [Manifest][fork-package] |
| Acknowledgements and delivery | Callback-based `emitWithAck(...).timingOut(after:)`; no ordered retry queue or async acknowledgement entry point in the inspected client. [Client][upstream-client] | Callback, async and legacy acknowledgement entry points, ordered retries and cancellation handling. [Client][fork-client], [async emitter][fork-emitter] |
| Session recovery and authentication | Connect payload handling; no recovery `pid`/offset state or per-CONNECT auth-provider API in the inspected client. [Client][upstream-client] | Recovery state and `recovered`, plus a dynamic auth provider for initial connection and reconnects. [Client][fork-client] |

A tools-version declaration is **not** a maximum supported compiler version.
The upstream manifest alone does not prove that an application using a newer
compiler cannot build the package. Our requirement is that the library itself
uses Swift 6 language mode and is checked accordingly. That also does not make
`SocketManager` or `SocketIOClient` generally thread-safe or `Sendable`; access
still belongs to the manager's serial `handleQueue`.

## What this means for an application

**Native transport ownership.** Applications that require Apple's URLSession
networking stack do not need to retain Starscream solely for this client. This
changes transport configuration too: review the [native transport migration](../NativeWebSocketTransport.md)
for TLS, cookies and removed settings.

**Recovery and delivery are explicit.** The [connection guide](Connections.md)
explains recovery and dynamic authentication; the [acknowledgement guide](Acknowledgements.md)
explains timeouts, retries and cancellation. Recovery needs server-side support
and can fail. Retry delivery can produce duplicates, so application protocols
must handle deduplication where necessary. Neither feature provides an
unconditional delivery guarantee.

**Compatibility claims have a defined scope.** [PARITY.md](../../PARITY.md) records
exclusions and deliberate differences. An SDK build is not a device test, line
coverage is not semantic equivalence, and executing upstream JavaScript tests
alone would not validate the Swift implementation.

## When staying with upstream makes sense

An existing application may already be well served by the official client's
transport, API and supported platform range. Older toolchains or legacy server
requirements can also make this fork's narrower support policy unsuitable.
Check the exact release requirements rather than migrating just because a fork
exists.

This fork requires Swift 6.4 / Xcode 27 and iOS 15, macOS 12, tvOS 15 or watchOS 9.
It does not offer WebTransport, JavaScript compression controls or custom
JavaScript transport constructors. Version 17 removes legacy APIs and changes
some reconnect and acknowledgement behavior; **changing the package URL is not
a complete migration plan**. Start with [Migration](Migration.md).

Published releases and development branches are separate choices. Follow
[Getting started](GettingStarted.md) for the published 17.x package, select a
reviewed revision explicitly for unreleased changes, and inspect CI for that
exact revision. Physical-device runtime validation is not established by the
recorded SDK builds.

## Provenance

The direct parent is [howardsun-tw/socket.io-client-swift](https://github.com/howardsun-tw/socket.io-client-swift),
which derives from [socketio/socket.io-client-swift](https://github.com/socketio/socket.io-client-swift).
This project builds on Erik Little's original client and the upstream
contributors' work. See [LICENSE](../../LICENSE) for applicable terms and notices.

[upstream-head]: https://github.com/socketio/socket.io-client-swift/commit/42da871d9369f290d6ec4930636c40672143905b
[upstream-release]: https://github.com/socketio/socket.io-client-swift/releases/tag/v16.1.1
[starscream-head]: https://github.com/daltoniam/Starscream/commit/c6bfd1af48efcc9a9ad203665db12375ba6b145a
[starscream-release]: https://github.com/daltoniam/Starscream/releases/tag/4.0.8
[fork-head]: https://github.com/kaeferfreund/socket.io-client-swift/tree/5f6abcfc8aeb22d73233a719651f9dad13c735e6
[upstream-ack-issue]: https://github.com/socketio/socket.io-client-swift/issues/1509
[apple-websocket]: https://developer.apple.com/videos/play/wwdc2019/712/
[upstream-readme]: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/README.md
[upstream-package]: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Package.swift
[upstream-client]: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Client/SocketIOClient.swift
[upstream-manager]: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift
[fork-package]: https://github.com/kaeferfreund/socket.io-client-swift/blob/5f6abcfc8aeb22d73233a719651f9dad13c735e6/Package.swift
[fork-client]: https://github.com/kaeferfreund/socket.io-client-swift/blob/5f6abcfc8aeb22d73233a719651f9dad13c735e6/Source/SocketIO/Client/SocketIOClient.swift
[fork-emitter]: https://github.com/kaeferfreund/socket.io-client-swift/blob/5f6abcfc8aeb22d73233a719651f9dad13c735e6/Source/SocketIO/Ack/SocketTimedEmitter.swift
[fork-transport]: https://github.com/kaeferfreund/socket.io-client-swift/blob/5f6abcfc8aeb22d73233a719651f9dad13c735e6/Documentation/NativeWebSocketTransport.md
[fork-migration]: https://github.com/kaeferfreund/socket.io-client-swift/blob/5f6abcfc8aeb22d73233a719651f9dad13c735e6/Documentation/SocketIO4Swift6Migration.md
[fork-ci]: https://github.com/kaeferfreund/socket.io-client-swift/blob/5f6abcfc8aeb22d73233a719651f9dad13c735e6/.github/workflows/swift.yml
