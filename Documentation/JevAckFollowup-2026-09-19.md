# Jev follow-up: acknowledgement assertion audit

The user authorized delegating bounded comparisons to the installed read-only
OpenCode Jev agent. The first delegated batch covered exactly JS-094, JS-095,
JS-096, JS-097, JS-098, JS-100, JS-101 and JS-105 against upstream
`aaf2af36ec8ad05910f357a788e0e358bad32738`. Reconnect work proceeded independently
and passed all seven CI jobs at `7be2fa5` (run 35436799492).

[Exact evaluator inputs and outputs](ReviewEvidence/JevAckEvaluation-2026-09-19.json)
are advisory source-review evidence, not executed test proof. Two Jev calls used
8,530 input and 1,015 output tokens (9,545 total), with 972 ms evaluation time.
The coordinator separately reported USD 0.42655; this is not a combined billing
statement for both providers. No additional agents or recursive reviews ran.

## Earlier reconnect review

The user's [earlier Jev review](JevParityReview-2026-09-19.md) is retained with
its original snapshot and 107-item backlog. That count describes `0be321f`, not
the current tree. Its six reviewed reconnect cases were checked against the
sources: JS-014 now maps a real default-reconnect E2E scenario; JS-016 observes
successful reconnect after a reentrant manual reconnect; JS-017 restarts from
reconnectFailed with a fresh budget and real opening timeouts; JS-018 measures
three increasing actual retry intervals; JS-023/024 assert exactly [1,2] at
reconnectFailed. All these methods passed in run 35436799492.

## Source review and resulting changes

| ID | Source-verified conclusion and action |
| --- | --- |
| JS-094 | Existing timeout and send-buffer tests already covered most behavior. Strengthen the existing send-buffer test to assert zero retained packets *inside* the timeout callback, using the available native test snapshot. No duplicate suite needed. |
| JS-095 | The existing live-server test waited for connection first. Add the original pre-connect `unknown` emit with a 50 ms timeout. |
| JS-096 | Add original zero-timeout `echo(42)` and exactly-one-callback assertion after 200 ms. Also exercise the established-connection case with a following server ACK as a wire-order barrier. Count **all** callbacks: the coordinator's suggested conditional increment would miss an erroneous second successful callback. The original pre-connect test itself does not guarantee a late wire ACK because its packet can expire in the send buffer. |
| JS-097 | Do not accept `ping`/`pong` or default-timeout `echo("a")` as a complete substitute. Add explicit timed callback `echo(42)`, nil error and integer 42, issued while connecting. Scale the positive timeout for CI, documenting the adaptation. |
| JS-098 | Add real-server async `emitWithAck("unknown")` rejection with 50 ms timeout; retain existing unit coverage. |
| JS-100 | Exercise the original pre-connect `unknown` emit with inherited default ackTimeout and no explicit timeout wrapper. |
| JS-101 | Existing real-server modern untimed ACK test covers silent removal and no callback after disconnect. Record that exact method; do not rely on the legacy sentinel API. |
| JS-105 | Add public disconnect immediately behind a real outgoing async timed `echo("a")`; require `.disconnected` before its ten-second timer and an empty ACK registry. |

Static mappings and actual passing executions remain separate. The normal
contract checker validates the mappings and CI verifies the mapped methods
passed. The strict full-parity gate still rejects the remaining unsupported-by-
evidence scenarios; no exclusions or checker acceptance rules were broadened.

## Execution evidence

[CI on 70bd38c](https://github.com/kaeferfreund/socket.io-client-swift/actions/runs/35437122400)
passed all seven jobs: 766 Swift tests, zero failures; Thread Sanitizer; strict
concurrency; four Apple SDK builds; pinned upstream suites; parser differential
and wire proofs. The contract checker also passed against that exact XCTest log.
Eight offline checker regressions passed.

Library-only execution coverage: 6,183/6,589 lines (93.84%), 948/1,060 functions
(89.43%), 2,311/2,650 regions (87.21%). Branch coverage is not reported. These are
one run's execution counters, not assertion-equivalence percentages.

The current inventory has 121 certified runtime declarations, 102 explicit
boundaries and 74 remaining supported declarations without complete assertion
certification. The original 129-item task has therefore advanced by 55 mappings.
The strict completeness gate still fails, as intended. No release was created.
