# Swift Socket.IO: protocol parity and safety review

**Current follow-up:** later assertion mapping and CI gates in this document and
`JavaScriptParityContracts.json` supersede the historical listener, acknowledgement,
query and CI limitations below. The remaining release gates stay explicit.

**Review date:** 2026-09-18. **PR:** #18, `fix/coderabbit-findings-audit` against `master`.

## Decision

The reviewed fork is **not a complete test-for-test port or an observationally identical implementation of the JavaScript client**. This review fixes concrete defects and strengthens validation; it is not a declaration of zero defects or a production release approval. The outstanding resource-boundary and encoder work below must not be hidden behind a green test count.

The reference is the official `socketio/socket.io` repository at commit **`aaf2af36ec8ad05910f357a788e0e358bad32738`**, including `socket.io-client`, `engine.io-client`, `socket.io-parser` and `engine.io-parser`. Its client package declares version 4.8.3. The commit pins the comparison; it is not a claim that an arbitrary installation labelled 4.8.3 has the same sources. The starting Swift PR head was **`513a484aa5bd30bd2b09112830bcf6326f60b581`**. The integrated default-branch baseline was **`b613ef4c501df7b1ac32911b9a211312f496410b`**.

Source review focused on peer-controlled parsing, native transport/session ownership, HTTP polling, acknowledgement and retry lifetimes, disconnect/reconnect ordering, configuration/TLS, and the credibility of the existing parity evidence. Not every execution path or interleaving is proven. Static code observations, reproduced failures, differential measurements and design recommendations are distinguished below.

## 1. The outstanding CodeRabbit comment

[Comment 5733052285](https://github.com/kaeferfreund/socket.io-client-swift/pull/18#issuecomment-5733052285) alleged that an immediate reconnect could cancel the retiring polling session before its close-only POST. The original PR already captured the session and assigned `session = nil` before invoking client callbacks. Thus the specific claim that this detachment was missing was **not reproduced**.

The ownership contract is now more explicit: `closeOutEngine` captures **both the retiring session and its POST completion group**, detaches the active session, and replaces the active POST group before exposing the close to reentrant client code. The close-only POST waits only for the retiring session's outstanding POSTs. It cannot be blocked by a new session's writes or sent under its SID. The wait for an in-flight POST remains bounded to one second; since the council follow-up (section 7) the retiring session then flushes its queued packets and the close packet as individually bounded requests instead of a close-only POST.

`SocketPollingCloseTest` now includes a held in-flight POST followed by immediate reconnect, alongside the existing `testRetiredCloseUsesOnlyTheOldSessionAfterReconnect`. A second regression verifies that a local POST completion which synchronously enqueues more work cannot open an overlapping POST. These are controlled URLSession/URLProtocol tests, not claims about every network condition.

## 2. Defects fixed during this review

### F1. Peer-controlled parser traps and unsafe binary reconstruction, high severity

The starting parser crashed in isolated subprocesses on short packet strings such as `2`, `2123`, `51-`, and on a binary placeholder with an out-of-bounds `num`. These are Socket.IO payloads that a peer could place inside an Engine.IO MESSAGE. The test harness compiled the real parser/packet source, with only manager and logging conveniences replaced.

`SocketParsable.swift` now uses a forward-only, bounds-checked UTF-8 cursor. Numeric headers are parsed with overflow checks; namespace Unicode is preserved. Mandatory event/ack payloads and attachment-count syntax are validated before indexing. Modern CONNECT_ERROR payloads follow the modern shape; the explicitly selected legacy protocol retains its older error shapes. All six reserved event names are rejected in the relevant event paths, including `newListener` and `removeListener`.

`SocketPacket` validates placeholder types and indices before retaining/reconstructing attachments. Boolean NSNumber bridges no longer masquerade as numeric event names or indices. A malformed header, a second binary header, unexpected binary data, or a text packet interleaved into a pending binary reconstruction terminates the affected parse session rather than indexing invalid storage or leaving ambiguous framing. Empty Engine.IO MESSAGE payloads no longer disappear silently at the manager parser boundary.

New `SocketParserOptions` default to **10 attachments, unlimited binary bytes, unlimited text packet bytes, and JSON depth 512** (the byte limits were 16 MiB and the depth 100 until the council follow-up in section 7). Positive values and a bounded depth setting are required. These limits are deliberately stricter than unlimited acceptance; they are not proof of an end-to-end memory cap. Existing `.webSocketOptions(...)` still separately controls native complete-message/queued-send bounds.

Tests: `SocketProtocolSafetyTest`, extended `SocketParserTest`, manager parser-failure regressions and `scripts/test-parser-safety.sh`.

### F2. Retry queue and acknowledgement ownership, high severity

Ordinary emits routed into the retry queue did not inherit the configured `ackTimeout`, so a missing acknowledgement could leave the queue head blocking later packets indefinitely. Retry attempts also needed stronger identity separation from stale acknowledgement cleanup.

The modern retry path now applies the effective timeout to plain emits as well as err-first callback emits. Each attempt owns a fresh acknowledgement ID. Superseded registrations are retired before resending, and callbacks must match both queue entry and attempt ID. Local write completion fires once for the user operation rather than once for every retransmission. Reserved events are checked before retry enqueueing, so retries cannot bypass event validation. Retry drain happens before the namespace's `connect` listener, preventing a listener from overtaking a queued head.

Disconnect and identity-reset cleanup snapshot the retiring acknowledgement IDs before reentrant callbacks. Deferred cleanup cannot erase an acknowledgement belonging to a replacement connection or identity. Modern no-timeout acknowledgements are removed silently on disconnect, unlike the intentionally separate legacy API. Timeout registrations carry their own identity token; reusing an ID cannot allow its cancelled old timer to fire the new registration.

Same-turn `emit(); disconnect()` is also explicitly tested. Acknowledgements register synchronously when already on the manager's owning queue; dispatch from another queue remains asynchronous. This avoids fixing stale cleanup at the cost of missing the acknowledgement that was just emitted. A custom `SocketData` representation is evaluated once, and the retry wrapper does not consume an unused acknowledgement ID before the actual attempt.

Tests: `SocketRetrySafetyTest`, `JSParityRetryE2ETest`, existing acknowledgement, state-recovery and connect-timeout suites.

### F3. Cancellation before async acknowledgement registration

A cancellation arriving in the check-to-registration window could miss a not-yet-allocated acknowledgement and leave an infinite-timeout async emit suspended. A small lock-protected cancellation/registration state now carries that cancellation into registration on `handleQueue`. Already-cancelled work does not send or register a timer; cancellation after registration uses the same once-only acknowledgement path.

The unchecked Sendable assertion is restricted to this lock-protected state, not applied to the mutable client or manager as a shortcut. This is not a full Swift 6 strict-concurrency migration.

Tests: `testCancelledBeforeRegistrationCannotHangInfiniteAsyncAck` and the existing async cancellation/race suites.

### F4. Polling POST reentrancy and malformed legacy framing

The production POST path now detaches a batch, claims the active POST slot and registers the actual request with the session barrier **before** running user-visible local completions. A completion that emits again cannot enter a second concurrent POST. The old helper remains available for its existing test/API behavior, but production ownership no longer depends on running callbacks while the slot appears idle.

Engine.IO 3 payload lengths now use checked, bounded UTF-16 reads. Negative, overflowing, truncated and split-surrogate lengths produce a controlled error instead of a String index trap. This is separate from Socket.IO packet parsing and is tested independently.

Tests: `SocketPollingCloseTest` and `SocketNativeEngineTest.testMalformedLegacyPollingLengthsAreRejectedWithoutTrapping`.

### F5. Heartbeat deadline correctness and timer bounds

Static review found that the old Engine.IO 4 heartbeat checked `lastCommunication`, which was updated by **all** text/binary traffic. Application traffic could therefore hide missing server PING packets, and a periodic check was not an exact ping-only deadline. The JavaScript reference resets its deadline on OPEN/PING and separately detects expiration when a timer has been delayed.

The Swift engine now owns a cancellable monotonic heartbeat deadline reset by OPEN/PING only. Cancellation plus attempt/token guards prevent old timer callbacks from closing a replacement attempt. `hasPingExpired` detects an expired deadline even before a delayed timer callback executes, schedules the once-only timeout close, and prevents a normal emit from being sent over the stale connection. That emit remains buffered for reconnect. Native volatile writability also accounts for expiry. Other `SocketEngineSpec` conformers receive a source-compatible default property.

Handshake heartbeat intervals are untrusted inputs. Boolean, string, negative and overflowing values and a sum outside the supported timer range are rejected before constructing Dispatch deadlines. Following the council follow-up (section 7), `pingInterval: 0`, fractional milliseconds (floored) and absent timers are accepted exactly as engine.io-client accepts them: the socket opens and, with a zero-length deadline, closes from the heartbeat with `ping timeout`. Acknowledgement timeout conversion likewise treats infinity without scheduling an overflowing timer and bounds finite values.

Tests: `testApplicationTrafficCannotRefreshTheServerHeartbeatDeadline`, `testOnlyPingResetsTheDeadlineAndExpiredChecksCloseOnce`, `testExpiredHeartbeatBuffersInsteadOfSendingOnTheStaleConnection`, and malformed-heartbeat tests. The clock seam is test-only; no sleeps are used to prove the deadline arithmetic.

### F6. Redirect downgrade across more than one hop

The redirect guard previously needed to account for the **current response URL**, not only the original task URL. Otherwise a chain beginning at HTTP and passing through HTTPS could later downgrade. The guard now evaluates the current hop and retains the configured TLS policy; it does not let an external delegate override a server-trust decision.

Test: the multi-hop redirect regression in `SocketNativeTLSConfigurationTest`, together with existing real HTTPS/WSS hostname, expiry, pin and custom-anchor tests.

## 3. Are all JavaScript tests ported?

**No.** The old matrix counted only the 116 Socket.IO client declarations and described generic Swift test files as if they were exact scenario evidence. It omitted Engine.IO and both parsers. Its applicable/covered totals were internally inconsistent. This review replaces that percentage claim rather than carrying it forward.

| Official package | Static runtime test declarations |
| --- | ---: |
| socket.io-client | 116 |
| engine.io-client | 109 |
| socket.io-parser | 34 |
| engine.io-parser | 38 |
| Total | 297 |

There are **14 additional TypeScript compile-time test declarations**. These numbers are generated from AST traversal by `scripts/inventory-upstream-tests.cjs`; they are declarations, not expanded executions. Loops and conditional platform branches can instantiate multiple cases. Server implementation suites are not part of this client-port denominator.

`JavaScriptTestInventory.csv` contains all 311 declaration entries with source file/line, suite, title, review status and candidate Swift evidence. The labels deliberately do not collapse distinct facts:

* **focused-regression:** a related invariant is explicitly tested by this review, sometimes with intentionally stricter Swift input handling; not a claim of literal transplantation.
* **candidate-existing-test:** a previous pointer or relevant test exists, but its full assertion set has not been newly certified against the upstream case.
* **mapping-gap / unmapped:** an exact mapping is missing; this does not prove the behavior itself is missing.
* **known-divergence / api-difference / unsupported-feature / platform-specific / typescript-only:** the reason the entry cannot be counted as an equivalent Swift port is recorded.

The inventory is a reproducible backlog and traceability index, **not a measured semantic-coverage percentage**. Many entries remain unmapped. No full JavaScript upstream `npm test` suite was run in this review. Existing Swift E2E tests run against real Node Socket.IO fixtures, but that is different from running both clients through every identical trace.

Examples of missing proof in the former matrix: async acknowledgement success/disconnect scenarios pointed at a file that tested cancellation/timeouts; URL query-string cases pointed at generic configuration tests; binary `onAnyOutgoing` pointed at a generic listener suite; the throttled-timer case was treated like ordinary offline buffering. The new heartbeat regressions address that last invariant; the other missing mappings are not silently promoted to covered.

Browser File/Blob, IE XMLHttpRequest, Web Workers, Node `autoUnref`, public JS transport constructors and TypeScript inference have platform/API-specific aspects. Their transferable wire behavior may still require native Data/Foundation tests. Compression and WebTransport are **unsupported features**, not merely irrelevant browser tests. Date values also have a representable JSON wire form, so the former blanket dismissal of Date tests was not justified.

## 4. Does Swift behave like the JavaScript original?

For the tested ordinary Socket.IO packet semantics, the evidence is stronger than before. A differential harness transpiles and executes the **actual hash-verified upstream decoder and event emitter**, not a reimplementation of JavaScript parsing. Only debug logging is disabled. The Swift side compiles the actual parser/packet files with small manager/logging shims.

**5,000 seeded generated valid vectors produced zero normalized decoder-output differences.** They include namespaces, Unicode, IDs including zero, JSON primitives/objects/arrays, CONNECT/ERROR/EVENT/ACK packets, and multipart binary event/ack data. Binary packet types and native Data/Buffer representations are normalized for comparison.

**Eight of 29 malformed/noncanonical probes differ.** Three (`2`, `3`, `2123`) are representation only: both decoders accept a payload-less EVENT/ACK, JS with `data === undefined` and Swift with empty data, and both clients then deliver nothing. Five are deliberate: this JavaScript snapshot decodes a CONNECT/CONNECT_ERROR without payload (then fails in `onpacket`, closing with the same `parse error`), a binary header without payload, and an exponential attachment count, all of which the hardened Swift decoder rejects at decode time. The exact inputs and both outputs are in `ReviewEvidence/DecoderDifferential.json`. They remain visible as deliberate strictness, not hidden to produce a perfect match number. This finite corpus is not an exhaustive equivalence proof, and it does not exercise all encoder outputs, network lifetimes or application behavior.

The separate malformed-input smoke harness processes **20,000 deterministic generated strings**, plus explicit former-crash cases and positive controls, without a parser process crash. This is seeded smoke/fuzz-style coverage, not coverage-guided fuzzing or an assurance that all malicious inputs are safe.

### Remaining behavioral differences

`SocketIOClient.setReconnecting` emits Swift `.reconnect` at the **start** of reconnection; the JavaScript manager emits successful `reconnect` later and exposes a different reconnect-event stream. During automatic retry, `SocketManager._engineDidClose` follows its own reconnect path instead of the JavaScript socket's full `onclose`/ack-cleanup sequence. The fixes above protect acknowledgement identities, but do not certify complete event-order equivalence on every automatic reconnect.

The legacy `emitWithAck(...).timingOut(...)` and async timeout overload do not participate in the modern ordered retry queue. The legacy API intentionally retains magic-string timeout and different disconnect behavior. JavaScript Promise acknowledgement behavior must not be declared covered solely because a Swift async overload exists.

The native fork removes `.compress`, `.selfSigned`, `.enableSOCKSProxy` and `.useCustomEngine`, rejects their dictionary keys, and uses explicit `SocketTLSConfiguration` policies. It does not implement WebTransport, JS `io()` manager caching, all URL inference, custom JSON revivers or all JS transport selection options. These are visible API/feature boundaries. Swift's explicit manager/queue ownership is not the same API as the browser/Node single-event-loop client.

## 5. Outstanding release gates and recommended simplifications

### R1. Bound the entire pipeline, not only individual native packets, high priority

**Status (2026-09-19): IMPLEMENTED in round 3, not release-validated.** The
policy below exists as the opt-in `.bufferLimits(SocketBufferLimits)` option and
covers every buffer this paragraph names, with the overflow behaviour and the
full acceptance list tested. See section 9.2. What is **not** done: the defaults
stay unlimited so the client remains JavaScript-equal out of the box, so a
deployment that wants the bound has to set it; the byte accounting is an
estimate of retained payload size, not a process-memory measurement; and none of
it has run on a device. The historical observation below predates the change.

**Static risk, not a measured exhaustion exploit in this review.** `SocketIOClient.sendBuffer`, `retryQueue` and `bufferedRecoveryReplayEvents` remain unbounded. The source explicitly documents the send buffer as unlimited. In addition, native receives can enqueue work onto the manager's DispatchQueue faster than the manager parses it. A per-message WebSocket limit and per-packet parser cap do not bound this accumulated backlog. Polling currently receives its complete response through a URLSession data-task completion, before the parser can enforce its text limit.

Required next implementation: one coherent resource policy covering queued packet count and retained bytes at the application buffer, retry queue, recovery replay and engine-to-manager handoff; a bounded incoming polling body; and a receive permit released after parsing, not merely after dispatch. Define whether overflow fails a new emit or closes the connection, how callbacks complete, and how long a half-reconstructed packet can remain outstanding. Never silently replay partial packets or silently drop reliable emits.

Acceptance: blocked consumer, never-connected socket, never-acked retry head, replay flood, unfinished binary packet, and oversized/chunked HTTP body tests. Measure retained memory and prove release after reset/disconnect. Matching the JavaScript client's unlimited buffer behavior is not a substitute for this safety policy.

### R2. Replace the silent outgoing JSON fallback, high priority

**Status (2026-09-19): CLOSED with documented deviations.** Round 2 removed the
fallback from emit paths; the follow-up added cycle detection and finite
traversal budgets, and the encode differential (1,000 packets read back by the
pinned JavaScript decoder, zero differences) is a CI job. The remaining
differences to `JSON.stringify` — finite depth/node/byte budgets, sorted object
keys, `\/` slash escaping and extended-year `Date` formatting — were reviewed on
2026-09-19 and accepted as documented deviations rather than defects; see
section 8.2. The historical source observation below predates those changes.

**Confirmed source behavior.** `SocketPacket.completeMessage` still returns an empty-array packet when JSON serialization fails. An unsupported custom `SocketData` representation or non-finite number can thus change the intended operation into a different wire packet rather than producing a typed encoding failure. The outgoing binary shredder recursively traverses graphs; the review has not established bounded behavior for deep or cyclic Foundation object graphs.

Required next implementation: one throwing, depth/node/byte-bounded encoder used before any retry/buffer registration or wire send. Define finite-number, Date, custom representation and Foundation collection behavior explicitly; detect cycles without first triggering recursive bridging. Complete the user's local operation and acknowledgement exactly once on an encoding error and emit no partial header. Remove or deprecate the nonthrowing fallback only under a documented API migration.

Acceptance: NaN/infinity, unsupported objects, cyclic NSMutableArray/NSDictionary, deep nesting, multiple binary attachments, custom conversion throwing, and encoding failure during buffered/retried sends. Add JS-vs-Swift encoder differential tests; the decoder comparison does not cover this.

### R3. Unify lifecycle and acknowledgement contracts instead of maintaining parallel paths

**Status (2026-09-19): DEFERRED to after 17.0.0.** This is architecture work
without a demonstrated defect: the acknowledgement paths share ordered retry
delivery and are covered by `SocketClearAcksOnCloseTest`, `SocketRetrySafetyTest`
and the ported JS scenarios; the reconnect-event migration it asks for was
decided and shipped as a documented breaking change (section 8.1). It is not a
publication gate for 17.0.0.

There are multiple acknowledgement APIs/registries and multiple buffering paths. This increases the number of cancellation, identity-reset and reconnect combinations that must remain consistent. Introduce one internal acknowledgement record with explicit timeout/disconnect/retry policy, keep public compatibility adapters at the edge, and express connection/namespace transitions as a small documented state machine.

Decide separately whether the public reconnect-event API should migrate to JavaScript semantics. A silent event rename would break existing consumers. Provide an explicit compatibility/version strategy, then run a differential trace suite for disconnect, retry, middleware refusal, successful recovery, identity change and reconnect exhaustion.

### R4. Finish test traceability and deterministic scheduling

**Status (2026-09-19): traceability CLOSED, scheduling DEFERRED to after
17.0.0.** Every applicable upstream runtime declaration now has a gated
assertion contract that CI checks against the real test log (section 8 and
`JavaScriptParityContracts.json`). Injectable schedulers and a nonblocking
fixture-process harness remain desirable test-infrastructure work without a
demonstrated production defect; they are not a publication gate for 17.0.0.

Treat the 297 upstream runtime declarations as a worklist, not as a count to equal by adding unrelated Swift tests. Each applicable row needs an exact assertion mapping and its transport/protocol parameterization. Missing positive async/query/binary-listener cases should be ported before claiming full client-level coverage.

Use injectable schedulers for backoff, acknowledgement and connection timers, with separate real-network tests using realistic timing budgets. The old 10/50 ms localhost retry tests failed in the starting CI; extending the successful-network time budget removes an accidental scheduling assumption. Deterministic tests retain exact retry counts, fresh IDs and once-only callbacks, rather than weakening those invariants to make CI green.

The test server's blocking `availableData` startup read and undrained stderr pipe deserve a bounded/nonblocking process harness. Otherwise a missing READY message can defeat its intended startup deadline and leave CI waiting. This is test-infrastructure risk, not a production transport bug.

### R5. Validate the native runtime and distribution contract

**Status (2026-09-19): PARTIALLY CLOSED in round 3.** Done: a Thread Sanitizer
CI job over the non-E2E unit suite, a `-strict-concurrency=complete` ratchet
with a per-platform baseline (no mutable class was stamped `@unchecked
Sendable`), pinned fixture dependencies with a committed lockfile and `npm ci`
everywhere, and two source-visible data races fixed
(`SocketAckManager` storage, the acknowledgement id allocator). Both new jobs
were authored on Linux and have not run yet; their first macOS run is the
measurement. Still open: everything below that needs real hardware — device and
simulator runs, background/foreground, network loss and recovery,
Wi-Fi/cellular transitions, IPv6, proxy environments, cancellation while
suspended, and independent Swift package consumer integration against a
release tag. See section 9.3.

Run device/simulator application tests for background/foreground, network loss/recovery, Wi-Fi/cellular transitions, IPv6, proxy environments and cancellation while suspended. macOS unit tests and SDK package builds are not equivalent to runtime validation on iPhone or Apple Watch. Run Thread Sanitizer and strict-concurrency builds separately; do not stamp mutable clients `@unchecked Sendable` to silence warnings.

Pin fixture dependency versions/lockfiles and record resolved versions for reproducible comparisons. Test Swift package consumer integration independently before release. A branch build is not a signed app or a release tag.

## 6. Evidence and reproduction

The initial PR's CI ran **435 Swift tests with two retry failures**. The first hardened intermediate snapshot ran **466 tests with zero failures** in [run 35375584340](https://github.com/kaeferfreund/socket.io-client-swift/actions/runs/35375584340), including real server/TLS tests; its four Apple SDK package builds and wire proofs also passed. That intermediate run preceded the additional heartbeat and identity-reset regressions. Final committed-source validation is recorded in the PR; its run/commit, not the intermediate count, controls the merge decision.

Reproduce on macOS with Swift/Xcode, Node and OpenSSL installed:

```sh
swift test
swift test --sanitize=thread --skip 'E2ETest' --skip 'HarnessSanityTest' --skip 'TestServerProcessTest'
bash scripts/check-strict-concurrency.sh
bash scripts/test-native-distributions.sh
bash scripts/test-parser-safety.sh
cd Tests/TestSocketIO/E2E/Fixtures
npm ci --ignore-scripts --no-audit --no-fund
node --test polling-proof-observer.test.mjs
node upgrade-race-proof.mjs
node max-payload-proof.mjs
```

For the decoder comparison, check out the pinned official JavaScript repository and make TypeScript 5.8.3 available to Node through a test-only installation or `NODE_PATH`. Then, from the Swift repository:

```sh
bash scripts/test-parser-parity.sh /path/to/socket.io decoder-results.json
node scripts/inventory-upstream-tests.cjs /path/to/socket.io /tmp/inventory
```

The comparison script checks the relevant official source hashes before executing them. The inventory script produces raw declarations; its output does not automatically certify or replace the manually reviewed status columns in the CSV. Logs and result artifacts should be retained with the exact Swift commit.

**No merge, release publication, physical-device certification, complete JavaScript test-suite execution, full semantic equivalence or zero-defect guarantee is claimed.**

## 7. Council follow-up (2026-09-18): behavioral changes after this review

A six-model review council (Fable, Codex, Grok, CodeRabbit, GLM 5.3 Flash,
Gemini 3.8 Flash) reviewed the PR after sections 1–6 were written; every
finding was adjudicated against the pinned JavaScript sources before it was
fixed. The fixes below change behavior that the sections above still describe
as strict; where they conflict, this section is current. The decoder
differential in `ReviewEvidence/DecoderDifferential.json` was re-recorded.

### Engine.IO close and upgrade

Ported from `engine.io-client/test/connection.js` and `lib/socket.ts`:

- **`close()` waits for the buffer to drain.** JS closes only after `drain`,
  and socket.io-client's `disconnect()` puts the namespace DISCONNECT packet in
  that same buffer. A graceful polling close therefore POSTs the packets still
  queued — sliced by `maxPayload` exactly like a live flush, one request at a
  time — and then the close packet as a request of its own. It used to send
  only `1` and complete the queued packets as if they had been written, which
  silently dropped the DISCONNECT frame. (`testCloseWaitsForInFlightPostAndCompletesPendingWritesOnce`,
  `testDisconnectFlushesQueueInMaxPayloadBatchesBeforeClosing`.)
- **`close()` defers while upgrading** (`waitForUpgrade()`): nothing can be
  written through a transport paused for an upgrade, so the close waits for
  `upgrade` or `upgradeError` — bounded by the existing probe timeout — and the
  buffer then leaves over whichever transport won. The client used to POST the
  close straight through the paused transport.
  (`testCloseIsDeferredWhileUpgradeIsPaused`,
  `testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade`,
  `testCloseDeferredDuringUpgradeResumesOverPollingOnUpgradeError`.)
- **A `send()` after `close()` produces no packet**, while the close is
  deferred too — JS `sendPacket` returns early once `readyState` is `closing`.
  (`testSendAfterCloseProducesNoPacket`.)
- **Handshake timers are stored as JS stores them.** `pingInterval: 0` with a
  real `pingTimeout` opens the socket, fractional milliseconds are ordinary
  values, and zero/absent timers open and then close from the heartbeat with
  `ping timeout` instead of failing the handshake. Only values that cannot
  become a Dispatch deadline (negative, non-numeric, or an interval+timeout sum
  past 2³¹−1) remain a transport error. (`SocketNativeEngineTest`.)
- **An undecodable Engine.IO packet closes the engine.** engine.io-parser turns
  it into an `error` packet, which `_onPacket` routes through `_onError` →
  `_onClose("transport error")`; the client used to only report `.error` and
  stay attached. (`testEngineDoesErrorOnUnknownMessage`,
  `testEngineClosesOnEveryMalformedEnginePayload`.)

### Socket.IO parser

Ported from `socket.io-parser/test/parser.js`:

- **Payload-less EVENT/ACK packets are not errors.** `2`, `2/nsp,`, `2123`, `3`
  and `399` decode with empty data, exactly as JS's `data === undefined`: the
  event reaches only the any-listeners, and the ack is dropped ("bad ack"). JS
  parses a payload only `if (str.charAt(++i))`. Everything "throw an error upon
  parsing error" rejects stays rejected
  (`testPayloadLessEventAndAckDecodeAsEmptyData`,
  `testTruncatedAndOverflowingHeadersAreRejectedWithoutTrapping`).
- **An acknowledgement id larger than `Int` is not an error.** JS parses it with
  `Number(...)` into a float that matches no handler; Swift keeps the packet
  with the no-ack sentinel, so the EVENT is delivered without an ack and an ACK
  is dropped (`testAckIdBeyondIntIsDeliveredWithoutAnAcknowledgement`).
- **Decoding resumes after a parser failure is reset.** JS `Decoder.destroy()`
  drops the half-built binary packet; here the reconnect in
  `SocketManager.connect()` clears `parserFailed`/`waitingPackets`
  (`testDecodingResumesAfterReconnectClearsTheParserFailure`).

### Deliberate deviations

- **`SocketParserOptions` limits.** JS's `Decoder` has exactly one limit,
  `maxAttachments` (default 10), and `maximumAttachments` matches it. The byte
  limits (`maximumTextPacketBytes`, `maximumBinaryPacketBytes`) default to
  unlimited, while the default nesting limit still differs from JS; set them via
  `.parserOptions(SocketParserOptions(maximumTextPacketBytes: 1 << 20))` to opt
  into hardening against a hostile peer. `maximumNestingDepth` is the one limit
  that stays on by default (512, hard cap 1024): `JSONSerialization` can
  overflow the stack on deeply nested input, which no real payload approaches
  but a malicious one can. An invalid option set is rejected before connecting.
- **A payload-less CONNECT_ERROR (`4`, `4/nsp,`) is a parse error on `.three`.**
  JS decodes it, then throws in `onpacket` reading `packet.data.message`, which
  its manager reports as the same `parse error` close — so the observable
  outcome matches for the socket that owns the namespace. `.two` managers still
  accept it, because the v2 grammar allows a bare ERROR packet.

## 8. Round 2 (2026-09-18): JavaScript-aligned reconnect events and a throwing encoder

Round 1 (section 7) closed the Engine.IO close/upgrade and parser-leniency gaps.
Round 2 updates the reconnect-event stream and removes the silent outgoing JSON
fallback; it does not by itself close review gate **R2**. It also ports the
remaining `socket.io-client` and `engine.io-parser` rows that had no mapping. Where the sections above still describe the old
behaviour, this section is current. Every change is a **breaking** change and is
listed in `README.md` ("Breaking changes in 17.0.0") and `CHANGELOG.md`.

### 8.1 Reconnect events (`socket.io-client/lib/manager.ts`)

Section 4 recorded: *"`SocketIOClient.setReconnecting` emits Swift `.reconnect`
at the start of reconnection; the JavaScript manager emits successful
`reconnect` later and exposes a different reconnect-event stream."* That
divergence is gone. The Swift event stream is now the JS one:

| JS (`Manager`) | Swift | Payload |
| --- | --- | --- |
| `Socket.onclose(reason)` → `disconnect` | `.disconnect` | the real close reason |
| `reconnect_attempt` | `.reconnectAttempt` | 1-based attempt number |
| `reconnect_error` | `.reconnectError` (new) | the reason the attempt failed |
| `reconnect_failed` | `.reconnectFailed` (new) | none |
| `reconnect` | `.reconnect` | the attempt number that succeeded |

- **`.reconnect` now means success.** `SocketManager._engineDidOpen` reads
  `currentReconnectAttempt` before `status = .connected` resets it (JS
  `onreconnect()` reads `backoff.attempts` before `backoff.reset()`), and emits
  `.reconnect(attempt)` before the namespaces are re-joined — so it always
  precedes the `.connect` that follows the server's CONNECT ack.
- **`.reconnectAttempt` carries the attempt, not the remainder.** JS emits
  `backoff.attempts`, which the preceding `backoff.duration()` has already
  incremented, i.e. `1` for the first attempt of a loop.
- **A retried drop reports `.disconnect` with the real reason.**
  `setReconnecting(reason:)` is Swift's `Socket.onclose`: it clears `sid` and
  emits `.disconnect(reason)`, while parking the socket in `.connecting` —
  which is what makes `_engineDidOpen` re-join its namespace — and leaving
  `active` set. The reason used to be delivered as the `.reconnect` payload.
- **Exhaustion emits `.reconnectFailed` and nothing else.** The Swift-only
  `.disconnect("Reconnect Failed")` is gone: the sockets already received their
  real reason when the connection dropped, which is exactly what JS does. The
  sockets are moved out of the `.connecting` parking state *before* the event
  fires, so a handler that calls `connect()` — the JS "should attempt reconnects
  after a failed reconnect" scenario — is not undone by the loop that is ending.
- **A failed attempt emits `.reconnectError`.** A close that arrives while the
  loop is running is JS's `open(fn)` error callback; the next attempt is already
  scheduled by then, so only the event is left to fire. The connect-timeout path
  therefore reports `.connectError("timeout")` *and* `.reconnectError("timeout")`
  during a loop, and only `.connectError("timeout")` on the initial attempt —
  which is what JS's `onError` + `maybeReconnectOnOpen` split produces.
- **Manager events reach every socket.** Swift has no manager-level event bus,
  so `emitAll` delivers `reconnect*` to every socket of the manager, including
  one that was never connected. `.reconnectAttempt` used to be filtered to
  sockets in `.connecting`.

Tests: `SocketReconnectEventsTest` (8 cases, driven by a fake engine that
decides per attempt whether the handshake succeeds), plus the updated
`SocketConnectTimeoutTest` and the `JSParityE2ETest` reconnect scenarios, which
now assert `.reconnectFailed` instead of the removed disconnect reason.

### 8.2 A throwing encoder replaces the silent `[]` fallback (gate R2)

`SocketPacket.completeMessage` returned `message + "[]"` whenever
`JSONSerialization` refused the payload, so a non-finite `Double`, a `Date` or
an unsupported object turned the caller's operation into a *different* wire
packet. JS `JSON.stringify` never does that: it produces the value or throws.

- **One normalization, applied before anything takes ownership.**
  `SocketPacket.jsonSafeEmitData(_:allowBinary:)` runs in every public emit
  entry point — before `_addToQueue`, before the send buffer, before any ack
  registration — and again in the internal emit funnel as the single choke point
  for the paths that build `[Any]` directly (`rawEmitView`, the Objective-C ack
  views). Re-running it preserves values but repeats validation and allocation.
- **`Date` → ISO-8601.** `Date.prototype.toJSON()` is `toISOString()`, so a
  `Date` at any depth becomes `"2024-01-02T03:04:05.678Z"` (UTC, exactly three
  fractional digits). `Date`/`NSDate` now conform to `SocketData`.
- **Non-finite numbers → `null`**, as `JSON.stringify(NaN)` produces. A JSON
  boolean is an `NSNumber` too and is filtered out by the existing
  `isJSONNumber` helper before the finiteness check.
- **Everything else throws `SocketPacketError`** (`unsupportedValue`,
  `nonStringKey`, `nestingTooDeep`, `cyclicPayload`, `tooManyNodes`,
  `payloadTooLarge`, `unserializablePayload`). The `.error`
  client event carries the error; modern error-first and async acknowledgements
  settle with it. Legacy `OnAckCallback` retains its separate no-ack contract.
  No rejected packet is written, buffered or queued.
- **`SocketPacket.encodedPacketString()`** is the throwing encoder;
  `packetString` keeps its signature for code that builds packets by hand, and
  logs when it falls back. No client path can reach that fallback any more.
- **Payload-less packet types encode as JS encodes them.** `encodeAsString`
  appends `JSON.stringify(obj.data)` only `if (null != obj.data)`, and CONNECT /
  DISCONNECT / CONNECT_ERROR carry a single value rather than the argument
  array. `SocketPacket` now renders those as a JSON fragment (`0/woot,{…}`,
  `1/woot,`, `4"Unauthorized"`) instead of wrapping them in an array. Nothing in
  this client encoded those types before — the manager writes CONNECT and
  DISCONNECT as raw strings — so this only makes the encoder able to reproduce
  the reference encoder, which the new differential direction relies on.
- **`JSONSerialization` is never handed an invalid graph.** It raises an
  uncatchable Objective-C exception for one, so validity is checked with
  `isValidJSONObject` before every encode.

**Deliberate deviations.**

- **Sorted object keys.** JS preserves object insertion order; a Swift
  `Dictionary` has none, so the choice is between an arbitrary order and a
  reproducible one. Keys are sorted on output and the binary shredder walks
  dictionaries in the same sorted order, so attachment numbering is stable too.
  JSON object order carries no meaning, and the reproducibility is what makes
  the exact wire strings testable.
  Validated against the pinned `socket.io-parser` encoder on 2026-09-19: JS
  writes array-index-like keys first in ascending numeric order (`"2"` before
  `"10"`), then every other key — including `"-1"`, `"01"` and `"1.5"` — in
  insertion order. Because plain `[String: Any]` input carries no insertion
  order at all, no encoder change can reproduce that for the current API;
  a JS-identical wire string would need an ordered input type (for example
  `KeyValuePairs`) plus a custom JSON writer. **Decision (2026-09-19): keep
  sorted keys and document the difference.** Decoders on both sides treat the
  orders as equal, which the encode differential proves.
- **Escaped slashes.** `JSONSerialization` writes `/` as `\/`; `JSON.stringify`
  leaves it unescaped. Both decode to the same string. Number formatting for
  very large or very small doubles (JS `1e+21`) is also not guaranteed to be
  byte-identical. Same decision as above: documented, not changed.
- **Bounded Foundation normalization (2026-09-19 follow-up).** Foundation
  arrays/dictionaries are traversed by identity through CoreFoundation before
  recursive bridging. Ancestor cycles throw `cyclicPayload`; shared acyclic
  subgraphs remain valid. The normalizer also enforces depth 512, 1,000,000
  nodes (including keys and repeated occurrences) and a conservative 64 MiB
  escaped-JSON/binary budget (64 bytes per attachment placeholder). These
  finite encoding bounds deliberately differ from JS and do not bound queue
  retention or total process memory. Hand-built packets are normalized before
  JSONSerialization too; error logging never describes the rejected graph.
  `SocketPacketEncoderTest` covers cycles, shared containers, public error/ack
  delivery and limit boundaries. Gate **R2 is closed with documented
  deviations** (decision 2026-09-19); the deviations are the budgets above,
  the key order and slash escaping below, and extended-year dates.
- **Extended years.** `Date.toISOString()` writes years outside 0000–9999 in an
  expanded `±YYYYYY` form; the Swift formatter does not.

**The differential now runs in both directions.** `scripts/parser-parity/main.swift`
gained an encode mode and `compare.cjs` 1,000 seeded encode vectors: every
packet type, `/`, `/foo` and `/é🦧` namespaces, ack ids including `0`, and
binary placed at any depth. Each vector is encoded by this client — through
`jsonSafeEmitData` and `packetFromEmit`, the real emit path — and read back by
the pinned upstream decoder, and the decoded packet must equal the source.
**1,000 encode cases, zero differences.** The decode direction and its recorded
malformed-input contract in `ReviewEvidence/DecoderDifferential.json` are
unchanged; that file gained the two new `encodeCases`/`encodeDifferences` keys.

### 8.3 Remaining `socket.io-client` mappings

- **The server URL's query string is used.** `SocketEngine.createURLs` rebuilt
  its transport URLs from scratch and dropped whatever query the `socketURL`
  carried, so `SocketManager(socketURL: …/?token=abc)` never sent `token`. The
  URL's parameters are now the connection query unless `.connectParams` is set;
  JS `lib/index.ts` does `if (parsed.query && !opts.query) opts.query =
  parsed.queryKey`, i.e. an explicit query *replaces* rather than merges.
  Percent-encoded parameters pass through verbatim rather than being escaped a
  second time. (`SocketQueryOptionTest`, and `JSParityE2ETest` against the
  fixture server's `handshake.query`.)
- **Async `emitWithAck`.** `socket.emitWithAck(ev, …)` and
  `socket.timeout(after:).emitWithAck(ev, …)` are new `async throws` APIs. The
  bare form is bounded by `SocketManager.ackTimeout` when configured (JS
  `flags.timeout ?? _opts.ackTimeout`); without one a disconnect throws
  `SocketAckError.disconnected` rather than never resolving, because a Swift
  continuation must be resumed exactly once. The earlier claim that JS leaves this promise pending forever was incorrect: JS `emitWithAck` sets `withError`, and `_clearAcks()` rejects it on disconnect. The follow-up covers the automatic-reconnect route too.
- **`onAnyOutgoing` and binary.** The listener already received the caller's
  `Data` rather than the attachment placeholder; that is now asserted, flat and
  nested.

### 8.4 Engine.IO codec

This client has no standalone engine.io-parser: encoding lives in
`SocketEngine.sendWebSocketMessage` and `SocketEnginePollable` (the
`"<type><payload>"` frame, the `\u{1e}` payload joiner, `createBinaryDataForSend`),
and decoding in `parseEngineMessage` / `parsePollingMessage` / `parseEngineData`,
which dispatch as they decode. `SocketEnginePacketCodecTest` asserts the wire
strings and what the engine hands its client — `encodePacket`/`decodePacket`'s
observable contract — for `"4test"`, the malformed `""` and `"a123"`, the full
`0\u{1e}1\u{1e}2probe\u{1e}3probe\u{1e}4test` payload, raw and base64 binary
(`"bAQIDBA=="`), and the mixed `4test\u{1e}bAQIDBA==` payload. No production
behaviour changed here; the tests record what was already true.

Two consequences of the fused decode-and-dispatch design are asserted
explicitly rather than glossed over: a CLOSE inside a payload ends the session,
so packets after it are not delivered, and the ArrayBuffer/Buffer/typed-array
distinction has a single Swift representation, `Data`. The browser and
typed-array rows of the engine.io-parser inventory are marked
`platform-specific` for that reason.

### 8.5 What round 2 did not do

**Superseded by section 9**: round 3 implemented gate R1, automated the part of
gate R5 that does not need a device, and made the acknowledgement lifetime
across a retried drop JS-exact. The paragraph below records what was still open
at the end of round 2.

Review gates **R1** (one coherent resource policy) and **R5** (device and
distribution validation) are untouched, as are the 57 unmapped
`engine.io-client` rows (URI parsing, cookies, close details, binary over
polling and WebSocket). Acknowledgement lifetime across a retried drop is still
not JS-exact: JS `Socket.onclose` calls `_clearAcks()` on every close, while
this client clears timed acks only on a terminal `didDisconnect`, so an
outstanding timed ack survives an automatic reconnect cycle here. That was left
alone deliberately in this round — it touches the retry queue and the send
buffer, and none of those paths can be exercised end to end on the Linux box
this round was written on.

## 9. Round 3 (2026-09-19): acknowledgement clearing on every close, one resource policy, automatable runtime validation

Round 3 closes the item section 8.5 deliberately left open, implements review
gate **R1**, and automates the part of review gate **R5** that does not need a
device. Where earlier sections describe the old behaviour, this section is
current.

### 9.1 `_clearAcks()` on every close, not only the terminal one

JS `Socket.onclose` ends with `_clearAcks()`, and it runs on **every** close,
including one the manager will retry. Swift ran that cleanup only from the
terminal `didDisconnect`, so `setReconnecting(reason:)` — the retried-drop path
— left the acknowledgement registry untouched. An acknowledgement owned by a
session the transport swallowed could therefore survive a reconnect and later
match an id the new session re-issued, or fire a late timeout against it.

`setReconnecting(reason:)` now runs the same cleanup as `didDisconnect`
(`notifyDisconnectAndClearAcks(reason:)`), with exactly the rules `_clearAcks`
has:

- **An acknowledgement whose packet is still in the send buffer is kept.** That
  packet has not reached the server; it goes out on the next CONNECT and the
  acknowledgement is still owed (JS `sendBuffer.some(packet => …)`).
- **A `withError` registration is settled** with the disconnect error; a plain
  callback is removed **silently** (JS: *"handlers that do not accept an error
  as first argument are ignored here"*). Swift expresses that distinction as
  `notifyOnDisconnect`, which is unchanged.
- **The retry queue's per-attempt acknowledgement is one of those
  registrations.** JS registers a fresh one per attempt from `_drainQueue`, and
  the callback `_addToQueue` appended decides what the close means: with retries
  left, the entry keeps its place in `_queue` with `pending = false`, and
  `onconnect`'s `_drainQueue(true)` re-sends it under a new id; once
  `tryCount > retries`, the entry is discarded and the user's acknowledgement
  settles with the error. Swift's `handleQueueAck` already implements both
  branches, so routing the disconnect error through it reproduces JS exactly.
- **The async `emitWithAck` continuation is resumed with `.disconnected`**, as
  JS rejects the promise through `_clearAcks()`. The Swift continuation is
  resumed exactly once.
- **Connection-state recovery is unaffected.** JS `onclose` does not touch
  `_pid`; only an explicit identity reset does. `_pid`/`_lastOffset` survive the
  close, so the next CONNECT still asks the server to resume.

Tests: `SocketClearAcksOnCloseTest` (7 cases, driven by a fake engine that
answers CONNECT and ACK frames and can kill the session, so the whole
drop → reconnect → re-join → re-drain cycle runs at queue speed), and
`JSParityE2ETest.testPendingAckFailsWhenTheTransportIsKilledAndTheSocketReconnects`,
which kills the server-side transport with a `never_ack` emit outstanding.
Ported from `socket.io-client/test/socket.ts` "should ack with an error upon
disconnection (callback & timeout / callback & ackTimeout / promise)" and "should
not discard an unsent ack (callback)", the "throttled timer" scenario, and the
`retry.ts` retried-head cases.

### 9.2 Gate R1: one resource policy, opt-in, JavaScript-equal by default

New public option `.bufferLimits(SocketBufferLimits)`
(`Source/SocketIO/Util/SocketBufferLimits.swift`). It is its own home rather
than an extension of `SocketWebSocketOptions` or `SocketParserOptions`, because
it is the only cross-cutting layer of the three:

| Option | Bounds |
| --- | --- |
| `.parserOptions` | one incoming Socket.IO packet |
| `.webSocketOptions` | one native WebSocket message, and the native send queue |
| `.bufferLimits` | everything that accumulates *across* packets |

**Every limit defaults to unlimited**, which is what keeps the default
behaviour JavaScript-equal — JS `sendBuffer` and `_queue` have no bound either.
An invalid limit is rejected before connecting, like an invalid
`SocketParserOptions`.

Covered: `SocketIOClient.sendBuffer` (packets and bytes), the `.retries` queue
(packets and bytes), the connection-state-recovery replay buffer (packets and
bytes), the engine-to-manager handoff (packets and bytes, with the receive
permit released **after parsing**, not after dispatch), one incoming polling
HTTP body, and how long a half-reconstructed binary packet may stay outstanding.

**Overflow is explicit and never silent:**

- **Outgoing** — the *new* emit fails locally. Its write completion runs once,
  its acknowledgement settles once with a typed `SocketBufferLimitError`, and
  the `.error` client event carries the same error. Nothing already accepted is
  evicted: dropping a reliable emit the caller believes is queued is precisely
  the silent loss this gate forbids.
- **Incoming** — the connection closes with `"transport error"`, the reason
  engine.io-client's `_onError` → `_onClose` produces. The one exception is the
  half-reconstructed binary packet: that is a decoder failure, so it closes with
  `"parse error"`, the reason `Manager.ondata` reports when the decoder throws.
  Nothing is replayed from a partial packet.

The bounded polling body is accumulated by the session delegate
(`SocketSessionDelegateProxy` is now a `URLSessionDataDelegate`): an announced
`Content-Length` above the cap is refused before a body byte is transferred, and
a chunked body is cancelled as soon as the accumulated bytes cross the cap.
Without a configured cap the transport keeps the previously measured
completion-handler request form — the URL loading system does not call the
data-delegate methods for a task created with a completion handler, so the
unbounded default path is byte-for-byte the old one.

Tests: `SocketBufferLimitsTest` (17 cases) covers the whole R1 acceptance list —
blocked consumer, never-connected socket, never-acked retry head, replay flood,
unfinished binary packet — plus proof that the retained counts and bytes return
to zero after a reset, after an acknowledged retry head and after a buffer
flush, and that the defaults really are unlimited.
`SocketPollingBodyLimitTest` (4 cases) covers the oversized and chunked HTTP
bodies against a session-scoped `URLProtocol` fixture, with a positive control
inside the cap and a control proving the unlimited default still accepts an
oversized body.

**What this is not.** These are queue-retention bounds expressed in estimated
payload bytes (`SocketBufferLimits.retainedBytes`), not a measurement of process
memory and not an allocator cap. The estimate is deliberate: the payload has
already been normalized by `SocketPacket.jsonSafeEmitData`, so it is a finite
graph of `String`/`NSNumber`/`Data`/`NSNull`/collections, and the accounting
answers "do not retain more than N bytes of my payloads".

### 9.3 Gate R5: what is now automated, and what still needs a device

Two new CI jobs in `.github/workflows/swift.yml`:

- **`thread-sanitizer`** runs the non-E2E unit suite with
  `swift test --sanitize=thread` on macOS and fails on any
  `ThreadSanitizer: data race` report. The skip rule is the `*E2ETest` naming
  convention, and a preceding step fails the job if an E2E class stops obeying
  it, so the skip list cannot silently stop covering a suite.
- **`strict-concurrency`** runs `scripts/check-strict-concurrency.sh`, which
  builds with `-strict-concurrency=complete` and compares the warning count to a
  per-platform baseline in
  `Documentation/ReviewEvidence/StrictConcurrencyBaseline.json`. It is a
  ratchet, not a clean-build requirement. The package uses Swift 6 language
  mode; strict-concurrency diagnostics are tracked separately against the
  baseline. A platform with no baseline yet is **reported, not failed** — the run
  prints the count and the line to commit, so the first run measures the number
  instead of producing a red build.

Fixture dependencies are pinned: `Tests/TestSocketIO/E2E/Fixtures/package.json`
names an exact `socket.io` version, `package-lock.json` is committed, and every
install — in CI and in `TestServerProcess.ensureNodeModules()` — uses `npm ci`,
which installs exactly what the lockfile pins instead of re-resolving a range.
The resolved tree is uploaded as a CI artifact.

Two data races were fixed that are visible from the source, both of the shape
Thread Sanitizer reports:

- **`SocketAckManager` storage.** The timed-ack APIs are documented as
  `handleQueue`-only, but two public entry points reach the registry from the
  caller's thread: `SocketIOClient.clearRecoveryState()` snapshots
  `pendingTimedAckIDs`, and the legacy `emitWithAck` chain registers through
  `addAck`. The underlying `Set`/`Dictionary` could therefore be mutated
  concurrently with a `handleQueue` write, which is memory-unsafe rather than
  merely mis-ordered. Storage is now lock-guarded; callbacks are still invoked
  **after** the lock is released, so the documented re-entrancy of
  `cancelTimedAck(_:fireWith:)` cannot deadlock. No ordering changed.
- **The acknowledgement id allocator.** `SocketIOClient.currentAck` was
  incremented from `handleQueue` by `allocateAckId()` and from the caller's
  thread by `createOnAck` (the legacy path), so two registrations could receive
  the same id. `createOnAck` now goes through `allocateAckId()`, which is
  lock-guarded.

Tests: `SocketAckManagerTest.testConcurrentAckIdAllocationNeverRepeats` and
`testConcurrentSnapshotAndRegistrationDoNotCorruptTheRegistry`.

**Still open, and not automatable here.** Device and simulator runs
(background/foreground transitions, network loss and recovery, Wi-Fi/cellular
transitions, IPv6, proxy environments, cancellation while suspended), watchOS in
particular, and independent Swift package consumer integration against a
release tag. These remain manual gates. The two new CI jobs have not been executed in
this round — they were written on a Linux box where `swift test` cannot run —
so their first macOS run is the measurement, including the strict-concurrency
baseline.

### 9.4 Local verification for this round

`swift build` / `swift test` do not work on the Linux box this round was written
on (`@objc`). Verification used a scratch harness that copies `Source/` and
`Tests/TestSocketIO/` outside the repository, strips `@objc`/`@objcMembers`,
constrains `SocketEngineClient` to `AnyObject`, swaps `Foundation.URLSession`
for `FoundationNetworking.URLSession` and adds the `FoundationNetworking`
import, then builds the module, typechecks every test file against it, and runs
the non-E2E suites through a generated `XCTMain`. Excluded there: the E2E
suites (real Node fixtures), the two Security-framework suites, and the `async`
test methods, which swift-corelibs-xctest cannot register through
`testCase(_:)`. macOS CI remains the only proof for those, and for the two new
CI jobs.

### 9.5 What round 3 did not do

The 57 unmapped `engine.io-client` rows and the 7 `socket.io-parser` encoder
rows were untouched in round 3. The package now uses Swift 6 language mode.
Gate **R2** is closed with documented deviations; **R3** (one internal
acknowledgement record and a documented state machine) and the scheduling half
of **R4** (injectable schedulers) are deferred to after 17.0.0 as architecture
work without a demonstrated defect. See the status lines under each gate.
