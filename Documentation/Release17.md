# Socket.IO-Client-Swift 17.0.0

Stable release dated 2026-09-19, distributed through Swift Package Manager using
the immutable [`v17.0.0` tag](https://github.com/kaeferfreund/socket.io-client-swift/releases/tag/v17.0.0).
Swift Package Manager is the only supported installation method.

## Additional parity corrections

When explicitly enabled, `autoConnect(true)` now also connects newly created
namespaces, matching the JavaScript client. The default remains false. Namespace
CONNECT packets and lifecycle callbacks follow subscription order. Engine.IO
framing requires ASCII packet type digits, preserves combining Unicode scalars
in text data, and reports an empty polling payload as a parser error.
Raw Engine.IO binary sends now produce one packet without an attachment header.
The shared codec decodes packet framing independently of transport CLOSE handling.
A parser failure replaces the native engine on reconnect; low-level delegates can
observe completed/failed Engine.IO upgrades separately from the HTTP handshake.

## Release notes

Socket.IO-Client-Swift 17 targets Socket.IO 4 servers using Engine.IO 4 over
HTTP long-polling and WebSocket. It requires Swift 6.4 / Xcode 27, with Swift 6
language mode, iOS/tvOS 15, macOS 12 or watchOS 9.

- Apple's URLSession replaces Starscream; there are no third-party Swift
  dependencies. TLS uses system validation, with explicit pinning/private-anchor
  configuration where required.
- Ordered retries now include callback, async and legacy acknowledgement entry
  points. Async cancellation removes queued/in-flight work. Individual namespaces
  can override acknowledgement timeouts and retry counts.
- Events received before namespace connection are buffered and delivered before
  outgoing buffered events and the connect notification, including binary events.
- Transport lists, `tryAllTransports` and `rememberUpgrade` support polling and
  WebSocket. Opening failures can try the next configured transport.
- Reconnection uses JavaScript-style backoff and event semantics. Pending
  acknowledgements are cleaned up on transport loss, and the last active
  namespace disconnect closes the manager.
- Parser/encoder validation and optional buffer limits protect malformed input
  and retained data. Encoding failures no longer substitute a different packet.

### Migration

Remove `SocketIOVersion` and `.version(...)`; the engine always uses Engine.IO 4.
Remove obsolete `compress`, `selfSigned`, `enableSOCKSProxy` and `useCustomEngine`
options. Obsolete dictionary keys fail configuration validation instead of being
silently ignored. See [the native migration guide](NativeWebSocketTransport.md)
and [Swift 6 / Socket.IO 4 migration](SocketIO4Swift6Migration.md).

Reconnection event payloads and timing changed; consult the
[reconnection semantics](Guides/Connections.md#reconnection).
Automatic server-cookie replay requires `withCredentials(true)` and uses an
isolated engine-owned cookie jar. `autoConnect` remains false by default.
Use the manager and sockets on their serial `handleQueue`; they are not Sendable.

### Scope and limitations

WebTransport **and its stream codec are explicitly unsupported**. This release
targets polling and WebSocket. Custom per-transport constructors and JavaScript's
compression switches/Deflate thresholds are also unsupported. URLSession deflate
interoperability does not imply that those controls exist. Parser safety limits
and documented Swift/platform API differences remain intentional.

All 195 applicable original runtime declarations now have complete native
assertions and passed execution evidence in the 801-test suite. The other 102
runtime declarations retain explicit API/platform/unsupported-feature reasons.
This scoped assertion audit is complete; it is not proof of all possible client
behavior or a device/release certificate. See [PARITY.md](../PARITY.md).

## Release validation and follow-up scope

The 17.0.0 release was validated by all seven then-required CI jobs on its exact commit:
844 native tests and the strict parity checker against their actual log, Thread
Sanitizer, strict concurrency, four Apple SDK package builds, pinned upstream
Node suites, parser differential checks and wire proofs. CI also builds and runs
an independent Swift Package consumer; when dispatched against the release tag,
it resolves version 17.0.0 from GitHub instead of using a local package path.
The release page records the final commit and CI run links. For later releases,
use the [current release checklist](Development/Releasing.md) and all current CI jobs.

All 195 applicable upstream runtime declarations have complete native assertion
mappings. The strict checker remains mandatory; exclusions and contract mappings
are unchanged for publication. Broader paired JS/Swift lifecycle traces remain
follow-up work and are not claimed complete.

Encoder gate R2 is closed with documented deviations. R3 and the scheduling
half of R4 remain deferred architecture work without a demonstrated defect; see
[ProtocolParityReview.md](ProtocolParityReview.md).

Physical iOS/watchOS runtime checks remain outstanding and
are not certified by this release: background/foreground, suspend, network
loss and return, Wi-Fi↔cellular handover, IPv6 and proxy environments.
macOS CI does not replace these proofs. Swift Package Manager is the only
supported installation method; CI builds the package for all four Apple SDKs.

A follow-up multi-model council review was explicitly deferred; the
historical review instructions must not trigger a new paid review on their own.

## Pre-release evidence

- [e06d5be CI](https://github.com/kaeferfreund/socket.io-client-swift/actions/runs/35433419941):
  all jobs passed, including 715 Swift tests and zero strict-concurrency warnings.
- [e63dc0e CI](https://github.com/kaeferfreund/socket.io-client-swift/actions/runs/35433653301):
  all jobs passed after transport ordering/fallback/remembered-upgrade changes.
- [43bbe47 final audit CI](https://github.com/kaeferfreund/socket.io-client-swift/actions/runs/35440824938):
  all seven jobs pass, including 801 Swift tests and the strict checker against
  the actual log. All 195 applicable runtime declarations are covered by complete
  native assertion mappings; library line coverage is 93.97%.
- [69adced coverage follow-up CI](https://github.com/kaeferfreund/socket.io-client-swift/actions/runs/35443462303):
  all seven jobs passed, including 844 Swift tests with zero failures. Latest
  validated library-only line coverage is **98.57% (6,605/6,701 lines)**; see
  [coverage evidence](ReviewEvidence/PollingFailureValidation-2026-09-19.json).


These earlier runs do not certify the final release commit; its CI evidence is linked on the release page.
