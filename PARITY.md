# JavaScript parity: evidence and explicit boundaries

Reference: official `socketio/socket.io` commit
`aaf2af36ec8ad05910f357a788e0e358bad32738`, audited 2026-09-18.
The checked-out client package declares 4.8.3; the commit, not a moving version
label, identifies the reviewed implementation.

**All 195 applicable runtime declarations now have complete native assertion
mappings and recorded execution evidence (801 Swift tests, zero failures in the
final assertion audit). Inspect CI for the current checkout. This is
scoped test parity, not proof of every possible JavaScript behavior.**
The previous 116-row matrix covered only socket.io-client, omitted Engine.IO and
both parsers, and contained stale/generic test pointers and inconsistent totals.
It must not be used as a coverage percentage.

For this port, parity means matching the supported JavaScript behavior plus
explicitly reviewed exclusions for features the native API does not offer.
`unsupported-feature`, `api-difference` and `platform-specific` rows with a
reason are resolved scope boundaries; they are not passed Swift executions.
The 36 unsupported-feature rows are explicitly listed in
`JavaScriptParityContracts.json` under `excluded_unsupported_features`:
compression controls (4), custom per-transport constructors (2), and
WebTransport/stream framing (30). The validator rejects new unsupported rows
without a matching reviewed exclusion. `--strict` excludes these reviewed
boundaries but still fails for supported behavior without certified contracts.
Transport selection, fallback and remembered upgrades are implemented and now
have complete original-scenario assertions, including real transport failures.

| Upstream scope | Static runtime test declarations |
| --- | ---: |
| socket.io-client | 116 |
| engine.io-client | 109 |
| socket.io-parser | 34 |
| engine.io-parser | 38 |
| Total | 297 |

An additional 14 TypeScript compile-time test declarations are separate.
Parameterized declarations may expand to multiple executions. Server-side
socket.io/engine.io suites are outside this client-port inventory.

See [the full inventory](Documentation/JavaScriptTestInventory.csv),
[the review and release gates](Documentation/ProtocolParityReview.md), and
[the recorded decoder comparison](Documentation/ReviewEvidence/DecoderDifferential.json).
Inventory labels distinguish focused regressions, candidate old pointers,
unmapped rows, API differences and unsupported features. A candidate is not a
proof that all assertions of an upstream test have been ported. The current
inventory contains 195 focused regressions with complete native assertion contracts,
28 API differences, 38 platform differences and 36 unsupported-feature entries.
There are no candidate or unmapped declarations. The final 36 were checked
against each original setup, data, order and negative assertion. The gated
contracts in `Documentation/JavaScriptParityContracts.json` are the living mapping.
CI now requires the strict completeness check **and** passed executions of the
mapped tests in the current run. A static mapping is not a test-run certificate.
These labels do not remove the deliberate encoding bounds; release gate R2 is closed with those bounds recorded as documented deviations.

The local decoder comparison exercised 5,000 generated valid text/binary vectors
against the actual pinned JavaScript decoder and current Swift decoder, with zero
normalized-output differences. Eight of 29 malformed/noncanonical probes differ.
Three are representation only: payload-less EVENT/ACK packets (`2`, `3`, `2123`)
decode in both, JS with `data === undefined` and Swift with empty data. Five are
deliberate: Swift rejects a CONNECT or CONNECT_ERROR without payload (which JS
decodes and then fails on in `onpacket`, closing with the same `parse error`), a
binary header without payload, and a non-decimal attachment count.

The comparison also runs in the encode direction: 1,000 seeded packets — every
type, Unicode namespaces, binary at any depth — are encoded by this client and
read back by that same pinned JavaScript decoder, with zero differences. This is
parser evidence only, not complete Socket.IO lifecycle, transport or application
equivalence.

Native transport uses URLSessionWebSocketTask with separate polling URLSession.
The native queue, TLS policy, graceful polling teardown and parser limits have
focused tests. Compression, WebTransport and several JavaScript-specific APIs are
not implemented. Reconnect-event semantics now match the JavaScript manager
(`reconnect` means success and carries the attempt number; `reconnect_error` and
`reconnect_failed` exist) — a breaking change in 17.0.0, see the
[connection lifecycle guide](Documentation/Guides/Connections.md#reconnection). The
outgoing encoder throws instead of substituting an empty payload and rejects
cyclic Foundation graphs before bridging. Its finite node/byte/depth budgets
are deliberate deviations, as are sorted object keys and `\/` slash escaping
(JS keeps insertion order with index-like keys first and leaves `/` unescaped;
both decode identically, decided 2026-09-19 to document rather than change);
encoder gate R2 is closed with those documented deviations, not a claim of identical output. Callback, async and legacy acknowledgement entry points now share ordered
retry delivery; native API representations remain documented separately. Runtime tests, SDK builds, API compatibility and device validation
are different acceptance gates.

Acknowledgements are now cleared on **every** close, including a drop the
manager retries, exactly as JS `Socket.onclose` → `_clearAcks()` does — the last
acknowledged divergence on that path (round 3, 2026-09-19). The new
`.bufferLimits(SocketBufferLimits)` option bounds the send buffer, the retry
queue, the recovery replay buffer, the engine-to-manager handoff, one incoming
polling body and the binary reconstruction deadline; **its defaults are
unlimited, so the out-of-the-box behaviour stays JavaScript-equal** — JS has no
such bounds either — and the limits are opt-in hardening, like the byte limits
in `SocketParserOptions`. A Thread Sanitizer run and a
`-strict-concurrency=complete` warning ratchet are now CI jobs, and fixture
dependencies are pinned with a committed lockfile; device and simulator
validation remains an open gate.
