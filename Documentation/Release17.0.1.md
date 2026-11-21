# Socket.IO-Client-Swift 17.0.1

Release dated 2026-09-19, distributed through Swift Package Manager with the
immutable [`v17.0.1` tag](https://github.com/kaeferfreund/socket.io-client-swift/releases/tag/v17.0.1).
Requires Swift 6.4 / Xcode 27; deployment targets remain iOS/tvOS 15, macOS 12 and
watchOS 9. Socket.IO 4 / Engine.IO 4 over polling and WebSocket remain the protocol scope.

## Improvements

- Prevent Foundation crashes when connect parameter keys or values contain `<`,
  `>`, backslash or backtick. Encoding now follows `encodeURIComponent`.
  Upstream: socketio/socket.io-client-swift#1421.
- Cancel obsolete per-socket connect deadlines so a successful connection's old
  timer cannot terminate a later reconnect. Upstream: socketio/socket.io-client-swift#887.
- Select the URL path namespace through `defaultSocket`, matching JavaScript.
  Upstream: socketio/socket.io-client-swift#1297.
- Support existing client identity credentials for mutual TLS across polling,
  WebSocket and upgrades, with server trust validation and TLS origin restrictions.
  Upstream: socketio/socket.io-client-swift#857, socketio/socket.io-client-swift#936,
  socketio/socket.io-client-swift#1157.
- Make polling HTTP request deadlines configurable, including handshake, GET and
  POST, through `.requestTimeout(...)`. Upstream: socketio/socket.io-client-swift#681.
- Preserve the [upstream triage report](UpstreamIssueTriage-2026-09-19.md) and its CSV evidence.
- Complete the SPM-only repository cleanup and reorganize installation, configuration
  and troubleshooting documentation. There are no third-party Swift dependencies.

## Compatibility notes

**URL path behavior changes:** `https://example.com/admin` now selects `/admin`
through `defaultSocket`. If the path was incidental and you want root, use
`manager.socket(forNamespace: "/")`. `.path("/socket.io/")` still controls the
transport endpoint independently. Trailing slashes and percent escapes in
namespace paths are preserved.

**Query wire encoding changes:** `!`, `*`, apostrophe and parentheses now remain
unescaped, as in JavaScript. Decoded query values remain equivalent.

**Request timeouts:** Swift takes positive finite seconds, not JavaScript
milliseconds. Omitting the option keeps native Foundation defaults (60 seconds
idle, seven days total), unlike JavaScript's unset timeout. Zero/infinity do not
disable native deadlines. Manager and heartbeat deadlines remain independent.

**mTLS:** supply a `URLCredential` containing an existing client identity. This
release does not import or persist private keys. Server trust and optional
pinning remain active. See [native transport configuration](NativeWebSocketTransport.md).

Swift Package Manager is the only supported distribution. Linux, WebTransport and
its stream codec remain unsupported. These changes do not establish complete
JavaScript parity or physical-device background/network-transition validation.

## Validation

The release page records the exact release commit and both CI runs: the full
candidate run before tagging and the explicitly dispatched tag run. The tag run
resolves the published exact `17.0.1` dependency from GitHub and verifies its commit.
Required checks include the full macOS unit/real-server suite, Thread Sanitizer,
four Apple SDK builds, strict concurrency, parser/protocol proofs, upstream Node
suites, documentation and independent SPM consumers.

SDK compilation is not physical iOS/watchOS runtime validation. The historical
[17.0.0 release record](Release17.md) remains unchanged.
