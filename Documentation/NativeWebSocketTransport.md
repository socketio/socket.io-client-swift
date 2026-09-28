# Native WebSocket migration

## Runtime architecture

`SocketEngine` now instantiates `URLSessionWebSocketTransport` for every
WebSocket connection. The sole network backend is `URLSessionWebSocketTask`.
There is no Starscream adapter, dependency, runtime fallback or feature flag.
HTTP polling remains a separate URLSession. SocketManager and SocketIOClient
retain auth, namespaces, acks, reconnect backoff and state recovery.

The native adapter serializes complete text/binary batches, has one in-flight
send and receive, and ignores stale generation/session/task/operation callbacks.
Engine callbacks independently verify the current transport and attempt. HTTP
callbacks verify the concrete polling session before mutating state. Shutdown
is terminal once; old polling sessions and native tasks are explicitly retired.

An RFC6455 open callback does not mark Engine.IO connected. Only its `0{...}`
packet opens the engine. Engine.IO heartbeat/probe packets remain text, not
WebSocket control-frame pings. Upgrade still waits for both GET and POST to
settle. The native FIFO receives `5` before held polling/application packets.
An unsuccessful optional upgrade resumes healthy polling; failure on the active
WebSocket closes the engine and lets the existing manager decide about reconnect.

## Compatibility changes in 17.0

Normal SocketManager/SocketIOClient use does not require a backend selection.
Minimum deployment versions: iOS 15, macOS 12, tvOS 15, watchOS 9. These are
compile baselines, not a claim that every runtime/device has been exercised.
The current fork requires Swift 6.4 with Swift 6 language mode and supports
Socket.IO 4.x / Engine.IO 4 only. See the subsequent
[Socket.IO 4 and Swift 6 migration](SocketIO4Swift6Migration.md).

* `SocketEngine.ws`, `SocketEngineSpec.ws` and the Starscream event delegate
  entry point have been removed. The native transport is deliberately internal.
* `.security(...)` now takes `SocketTLSConfiguration`, not CertificatePinning.
* `.useCustomEngine`, `.compress`, `.selfSigned` and `.enableSOCKSProxy` are
  removed, together with their engine properties and the obsolete `websocket`
  property. Use `wsConnected`/`polling` for transport state and explicit TLS trust
  anchors for private certificates.
* Dictionary keys for removed options (including `customEngine`) fail connection
  validation for every value, including `false`, before any request.
* WebSocket send completions run once per complete packet after all local sends
  finish, or once on failure/cancellation. They are NOT server acknowledgements.
  A partially sent packet is never transparently replayed.
* Native `writable` reflects backpressure and is false while probing/upgrading.
  Its snapshot is synchronized onto engineQueue for reads from the manager queue.
* Invalid security-related dictionary values produce a connection error instead
  of silently dropping a failed type cast.

## TLS

Default `.security(.systemDefault)` leaves normal platform validation active.
Pinning adds a required matching DER leaf certificate to normal system trust:

```swift
let manager = SocketManager(socketURL: URL(string: "https://example.com")!, config: [
    .security(.certificatePinning([leafCertificateDER]))
])
```

A private PKI/development server uses explicit trust anchors, with optional leaf
pins. Hostname, expiry and certificate chain validation still apply:

```swift
.security(.customTrust(anchors: [privateCADER], pins: [serverLeafDER]))
```

Empty pin lists in certificatePinning, empty custom trust-anchor lists, malformed
DER and custom TLS policies on cleartext connections are rejected. Pinning is
identical for polling and WebSocket. External `.sessionDelegate` callbacks cover
authentication not handled by the configured TLS/client identity policy, redirects,
invalidation, completion, metrics and
WebSocket open/close. Server-trust challenges belong exclusively to the TLS policy;
an external delegate cannot weaken it. Redirects cannot downgrade HTTPS/WSS to
HTTP/WS. Custom Apple TLS policies are explicitly unsupported on non-Apple builds.


### Client certificates (mutual TLS)

Provide an existing `SecIdentity` (private key and client certificate), optionally
with intermediate certificates. Both polling and WebSocket, including upgrades
and reconnects, use the same credential:

```swift
let credential = URLCredential(identity: identity, certificates: intermediates,
                               persistence: .forSession)
let manager = SocketManager(socketURL: URL(string: "https://example.com/admin")!, config: [
    .clientCertificate(credential)
])
```

`identity` comes from your keychain or a PKCS#12 import; `intermediates` is an
optional array of `SecCertificate` values. See Apple's
[credential initializer](https://developer.apple.com/documentation/foundation/urlcredential/init(identity:certificates:persistence:))
and [identity import guide](https://developer.apple.com/documentation/security/importing-an-identity).
The library does not import or persist private keys. The credential must contain
an identity and the connection must use HTTPS/WSS. It is supplied only to the
configured host and port, never a different redirect origin. Rejected identities
are not repeatedly offered within the same authentication challenge sequence.
Server trust, hostname validation and optional `.security(...)` pins remain active.
The client-identity host comparison uses Foundation's IDNA representation, ignores
letter case and accepts a single trailing DNS root dot. Unicode and Punycode
spellings of the same host therefore match. Different hosts and ports, malformed
hostnames and insecure challenges are rejected.
Without `.clientCertificate`, an external `.sessionDelegate` can still handle
client-certificate challenges itself.

Removing `.clientCertificate` from `manager.config` clears the configured identity
for subsequent sessions, including when reconnecting with the same engine.
Existing sessions retain the credential captured when they were created.

### URL path and namespace

`SocketManager(socketURL: URL(string: "https://example.com/admin?token=x")!)`
selects `/admin` through `manager.defaultSocket`, matching the JavaScript client.
No path (or `/`) selects the root namespace. Trailing slashes and percent escapes
in namespace paths are preserved. Use `manager.socket(forNamespace: "/")` to
explicitly select root, or another namespace to override the URL selection.

The URL path does not select the HTTP/WebSocket endpoint: use `.path("/socket.io/")`
for that. URL query parameters still reach the transport; `.connectParams(...)`
replaces them and encodes keys and values using `encodeURIComponent` semantics.

`connect(timeoutAfter:withHandler:)` applies to that connection attempt. Its timer
is canceled on success, explicit disconnection, or a replacement `connect()` call,
so it cannot terminate a later reconnect.

When a connecting namespace times out, it emits `disconnect` and runs the normal
acknowledgement cleanup, preserving acknowledgements for unsent buffered packets.
The socket remains active for reconnection. A `connect()` started by a status or
disconnect listener supersedes the old timeout handler and keeps its own deadline.


### Polling request timeout

Use `.requestTimeout(120)` to allow up to 120 seconds for each polling HTTP
request: initial handshake, subsequent GETs, POSTs and retiring-session close
POSTs. The value must be finite and greater than zero; invalid values produce a
configuration error before opening a transport. Configure this option before
connecting; the total timeout is captured when the polling session is created.
Removing the option from `manager.config` restores native request defaults and,
on the next connection, native session timeouts even when the engine is reused.

The explicit value sets both Foundation's idle timeout and total resource
transfer timeout, so receiving occasional bytes cannot extend an HTTP request
indefinitely. A timeout follows the normal transport error/close/reconnect path
and retains `URLError.timedOut` in `SocketTransportError.underlyingError`.
Existing graceful-close deadlines may end retiring requests sooner.

```swift
let manager = SocketManager(socketURL: URL(string: "https://example.com")!, config: [
    .connectTimeout(150),  // Whole Engine.IO connection attempt.
    .requestTimeout(120)  // Each polling HTTP request, including after connecting.
])
```

`requestTimeout` does not change WebSocket timeouts, the manager's
`connectTimeout` (20 seconds by default), or the Engine.IO heartbeat deadline.
Whichever applicable deadline expires first ends the operation.

The JavaScript client's XHR polling transport has the same configurable timeout
concept, measured in **milliseconds**; Swift uses **seconds**. Native defaults
are deliberately preserved when the option is omitted: 60 seconds without new
data and Foundation's seven-day resource timeout. This differs from JavaScript's
unset/zero XHR timeout. Swift requires a positive finite value and does not use
zero or infinity to disable Foundation timeouts. See Apple's
[request timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest)
and [resource timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource)
definitions. Addresses upstream `socketio/socket.io-client-swift#681`.

## Resource limits

`.webSocketOptions(SocketWebSocketOptions(...))` configures complete incoming
message size and outgoing queue bounds. Defaults are 16 MiB per incoming message,
16 MiB of retained outgoing payload, 1024 batches and 4096 outgoing messages.
Zero-length messages still count. Every limit must be positive. Limits are
independent of Engine.IO's polling `maxPayload`. Queue overflow is surfaced as a
transport failure rather than silently dropping a nonvolatile application packet.

`.parserOptions(SocketParserOptions(...))` is a separate, Socket.IO-level policy
and is **not** part of these transport limits. `maximumAttachments` defaults to
10, matching JS `maxAttachments`; the byte limits are opt-in. The nesting-depth
limit remains enabled by default at 512 and may reject packets accepted by the
JavaScript parser. See the [parity scope and deliberate deviations](../PARITY.md).

## Distribution and release

Swift Package Manager is the only supported installation method. `Package.swift`
declares no third-party Swift dependencies. Version 17.0.0 is published from the
`v17.0.0` tag. [Release17.md](Release17.md) records that release and its validation.
Later branch changes are not part of that tag. Development consumers should pin
the reviewed commit and inspect its CI results; new releases follow the
[release checklist](Development/Releasing.md).

## Validation

`swift test` runs the complete existing suite plus native engine/TLS regressions.
`scripts/test-native-transport.sh` filters the deterministic transport tests in
the real package, without third-party Swift packages. It requires the package's
Apple-platform toolchain; it no longer creates a separate older-language Linux
smoke-test package. CI results must be tied to a specific commit.

Coverage includes WebSocket-open vs Engine.IO-open, multipart completion,
unprefixed Engine.IO 4 binary frames, server-driven heartbeat, stale callbacks,
duplicate terminal events, backpressure, failed upgrade fallback, the GET+POST
barrier, option validation, request header/cookie precedence and the manager's
actual connect timeout. Security tests cover explicit anchors,
hostname/expiry/pin failure and real TLS connections in polling and WebSocket
modes. Real-server E2E suites retain auth, acks, namespaces, recovery, parser and
Engine.IO 4 coverage. Removed Engine.IO 3 tests are not counted as passing tests.

No physical iPhone/Apple Watch runtime validation is implied by a passing macOS
suite or platform SDK build. Compression and SOCKS have not been declared
feature-equivalent; the migration deliberately rejects those legacy requests.
