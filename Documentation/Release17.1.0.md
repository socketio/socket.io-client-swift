# Socket.IO-Client-Swift 17.1.0

Release dated 2026-09-21, distributed through Swift Package Manager with the
immutable [`v17.1.0` tag](https://github.com/kaeferfreund/socket.io-client-swift/releases/tag/v17.1.0).
Requires Swift 6.4 / Xcode 27; deployment targets remain iOS/tvOS 15, macOS 12 and
watchOS 9. Socket.IO 4 / Engine.IO 4 over polling and WebSocket remain the protocol scope.

## Fixes

- A reused `SocketEngine` now clears omitted optional configuration values. Removing
  `.clientCertificate(...)` or `.requestTimeout(...)` from `manager.config` takes
  effect when the next session is created; an old session keeps only the settings it
  captured when it was created.
- A per-socket connect timeout now follows the normal disconnect lifecycle. It emits
  `.disconnect`, settles acknowledgements according to the close rules, preserves
  acknowledgements for packets that have not reached the transport, and leaves the
  namespace active for automatic reconnection.
- A connect started from a status or disconnect callback supersedes the timed-out
  attempt. A timeout work item that has already started cannot run the old handler or
  tear down the replacement attempt.
- Client-certificate challenge host checks use Foundation's IDNA representation.
  Unicode and Punycode forms, letter case and one trailing DNS root dot are treated
  as equivalent. Different ports, hosts, malformed names and insecure challenge
  origins remain rejected.

## Compatibility notes

There are no new required API changes. Applications that observe `.disconnect` during
an unsuccessful per-socket connect now receive the event consistently, and the socket
remains active so the manager can reconnect it. To stop reconnecting, call
`socket.disconnect()` as before.

Configuration removal applies to sessions created after the new configuration is
applied. It does not retroactively change an already-running URLSession or WebSocket.

## Validation

The release candidate is validated by the repository's current release workflow:
the native suite and real-server tests, independent SPM consumers, Thread Sanitizer,
strict concurrency, Apple SDK builds, protocol proofs, parser parity, pinned upstream
client suites, documentation checks and repository hygiene. The host canonicalization
unit tests also run on Linux; client-identity and URLSession challenge tests require
the Apple Security and URLSession implementations.

SDK compilation is not physical iOS/watchOS runtime validation. The release does not
claim complete JavaScript parity or physical-device background/network-transition
validation.
