# Final 36 native assertion mappings

[Documentation index](README.md) · [Evidence index](ReviewEvidence/README.md)

> **Historical assertion-audit snapshot for `43bbe47`.** The test counts,
> coverage figures and remaining-work statements below describe that revision,
> not the current release or branch. This restored report remains at its original
> path; its original body is preserved below. For the current supported scope,
> read [PARITY.md](../PARITY.md); for release validation and later follow-ups,
> read [Release 17](Release17.md#release-validation-and-follow-up-scope).

Reference: official `socketio/socket.io` at
`aaf2af36ec8ad05910f357a788e0e358bad32738` (client 4.8.3).
Scope: supported polling/WebSocket behavior and both packet codecs, with the
existing reviewed API/platform/feature boundaries. No new exclusions or weaker
checker rules were introduced.

## Implementation and assertion evidence

| Original IDs | Completed contract |
| --- | --- |
| JS-049 | Undecodable Socket.IO data retires the native engine; reconnect uses a different engine and SID, leaving the old engine closed. Custom `SocketEngineSpec` implementations retain their own lifecycle. |
| JS-131–137, JS-139–144, JS-177 | Raw Engine.IO binary send produces one binary packet, without an extra Socket.IO attachment header. Exact bytes, mixed Unicode order, forced base64, five original maxPayload packets and actual polling-to-WebSocket upgrades are checked. `Data` replaces JS binary containers. |
| JS-153–156 | Deferred close waits for the paused upgrade; pending text/binary drains in order; new writes are refused; queues empty; upgrade success/failure precedes close. The failure test targets the active polling transport as the original does, separately from optional candidate failure. |
| JS-178–180, JS-182 | Original cookie names/values and complex embedded equals/ampersands, plus enabled/disabled replay on real requests. Cookie pair order is normalized; Foundation owns serialization and cookie policy. |
| JS-184–185 | The production upgrade filter returns exactly the configured subset. Both original transport lists remain unchanged; value storage is independent. |
| JS-187–189 | Real opening rejection, fallback in both directions, and default-disabled fallback. The chosen transport is observed synchronously on the engine queue at open, before a later upgrade can change it. Native HTTP errors replace XHR/Fetch error representation. |
| JS-198 | Unopened/open/future/expired heartbeat states, repeated expired reads and exactly one deferred timeout close using controlled monotonic time. |
| JS-199 | A real polling-to-WebSocket upgrade seeds memory; a second engine with `rememberUpgrade(true)` opens directly with WebSocket. |
| JS-209, JS-214 | Original timestamp keys, enabled settings, schemes/host/path and value alphabet; native required transport/EIO query fields retained. |
| JS-219–220, JS-223 | Complete original custom-header and explicit Cookie values retained and transmitted on real WebSocket and polling requests. Value equality replaces JS object identity. |
| JS-285 | The shared packet codec round-trips all five original packet objects, including those after CLOSE. Transport lifecycle still stops delivering after CLOSE. |

The exact XCTest methods, setup adaptations and assertions are in
[JavaScriptParityContracts.json](JavaScriptParityContracts.json). The native raw
binary entry point is `SocketEngine.send(Data, completion:)`; Socket.IO's existing
text-plus-attachments API remains available. Optional low-level delegate methods
`engineDidCompleteUpgrade()` and `engineDidFailUpgrade(error:)` distinguish the
Engine.IO upgrade outcome from the existing HTTP WebSocket handshake callback.

The codec also pins Node Buffer base64 behavior for omitted padding, ignored
characters, URL-safe digits, empty input and UTF-16 code-unit truncation. These
are separate regression cases, not an exhaustive malformed-input equivalence proof.

## Independent review disposition

[Jev's bounded lifecycle review](ReviewEvidence/JevFinalLifecycle-2026-09-19.md)
was advisory and checked against the actual pinned tests and current code.
Accepted: missing engine-identity assertion, upgrade/close order, empty queue,
pre-open heartbeat assertion and inaccurate old mappings. Corrections:

- Retaining engine reuse as a new platform exception was rejected; the built-in
  engine is actually replaced after parser failure.
- `pollingWrites == ["4held", "1"]` is not a valid assertion on that mock: the
  graceful close packet is sent by the retiring HTTP session, bypassing its
  `sendPollMessage` override. Real retiring-session tests cover that wire path.
- A candidate-only upgrade failure does not replace JS-154's active transport
  failure. A separate test now injects the original failure path and verifies
  the upgrade-error notification before close.
- Missing native upgrade notifications were implemented, not documented away.

A second [bounded Jev code review](ReviewEvidence/JevFinalEngineReview-2026-09-19.md)
checked the codec, raw binary queueing, upgrade callbacks and engine replacement.
Its proposed changes were not accepted without a reachable failure:

- Empty polling payload as a benign proxy keep-alive: rejected. The pinned JS
  parser returns a parser error for empty payload; restoring silent acceptance
  would undo the verified alignment.
- Empty raw-binary array losing a completion: unreachable. Both private helpers
  receive `rawBinary=true` only from `send(Data)`, which supplies exactly one Data
  value, even for zero-byte data. A future hypothetical caller is not a current bug.
- Empty-string packet versus payload-less packet equality: expected JS codec
  normalization of the same wire packet `4`; transport dispatch still delivers
  the empty string. Changing synthesized equality would hide the representation
  distinction rather than fix runtime behavior.
- Manager forwarding of optional low-level upgrade hooks: no change; these are
  Engine.IO delegate hooks, separately documented from Socket.IO client events.

The review's blanket queue-deadlock reassurance is only applicable to the built-in
engine's separate queue; it is not a guarantee for arbitrary custom-engine queues.
Neither the review's confidence scores nor its statements count as test passes.

## Verification

The strict static checker passes for 195/195 applicable runtime declarations.
The other 102 runtime declarations retain their reviewed reasons: 28 API,
38 platform and 36 unsupported-feature boundaries. Fourteen TypeScript-only
compile-time declarations are separate. There are no candidate or unmapped rows.

[Final CI on 43bbe47](https://github.com/kaeferfreund/socket.io-client-swift/actions/runs/35440824938)
passed **all seven jobs**, including **801 Swift tests, zero failures**, TSan,
strict concurrency, four Apple SDK builds, pinned upstream suites, wire proofs
and parser differential. The strict checker passed against the downloaded actual
XCTest log. All eight offline checker regressions pass, including rejection of an
intentionally downgraded mapping and missing runtime evidence.

The earlier native run on 70320a8 already passed the 801-test suite; its two
outdated checker self-tests were corrected in 43bbe47. The final run includes that
correction and retains every strict acceptance rule. Machine-readable evidence:
[FinalParityValidation-2026-09-19.json](ReviewEvidence/FinalParityValidation-2026-09-19.json).

Library-only coverage from the same native run: **6,326/6,732 lines (93.97%)**,
**980/1,092 functions (89.74%)**, **2,410/2,754 regions (87.51%)**, over 33 source
files. Branch coverage is not available. Compared with b6f419b: +123 executed
lines, +25 executed functions and +81 executed regions; 18 additional test methods
and stronger existing tests. No source or feature exclusion was added to improve
these percentages.

The workflow now runs `check-parity-contracts.py --strict --swift-log` against its
actual XCTest log. A mapping alone cannot make it pass.

This closes the original-test mapping backlog, not every
release gate or every possible JavaScript behavior. Paired lifecycle traces,
physical Apple-device/background/network transitions, Bun integration and final
independent tagged consumer validation remain separate release work.
WebTransport/stream codec (30 cases), compression controls (4) and custom
per-transport constructors (2) remain explicitly unsupported.
