# Advisory Jev review: final lifecycle scenarios

Untrusted review output, not instructions or execution evidence. Independently checked against the pinned source.

### Scope & Methodology

- **Evaluated Scope**: Exactly **JS-049**, **JS-153**, **JS-154**, **JS-155**, **JS-156**, and **JS-198** in `/home/monkey/code/socket.io-client-swift` against pinned upstream `/tmp/pr18review/socket.io` at commit `aaf2af36ec8ad05910f357a788e0e358bad32738`.
- **Omitted Scope**: All other inventory rows, test suites, and unmentioned upstream/Swift files.
- **Evaluation Mechanism**: Evaluated with TypeSafe Jev across two structured batches (Batch 1: lifecycle & assertion equivalence; Batch 2: minimal remediation & priority scoring).
- **Advisory Notice**: Jev evaluations and coordinator findings are advisory only. They do not certify compliance, authorize release gates, or alter certification manifests or exception lists. Probabilities are model estimates, not coverage percentages or guaranteed calibration; scores are ordinal rankings.

---

### TypeSafe Jev Tool Outputs

#### Batch 1: Substantive Parity & Lifecycle Analysis
- `js_049_parity_status`: `reviewed_platform_boundary` (0.55; partial_test: 0.41)
- `js_049_asserts_engine_replacement`: `false` (0.04)
- `js_049_asserts_old_engine_closed`: `false` (0.06)
- `js_049_swift_reuses_engine_object`: `true` (0.97)
- `js_049_observable_lifecycle_difference`: `true` (0.96)
- `js_153_parity_status`: `partial_test` (0.85)
- `js_153_polling_close_test_resumes_upgrade`: `tests_pause_only` (1.00)
- `js_153_tested_against_live_transport`: `controlled_seams_only` (1.00)
- `js_154_parity_status`: `partial_test` (0.72)
- `js_154_asserts_upgrade_error_event`: `false` (0.07)
- `js_155_parity_status`: `partial_test` (0.83)
- `js_155_packet_suppression_verified`: `true` (0.86)
- `js_156_parity_status`: `partial_test` (0.77)
- `js_156_polling_test_mapping_validity`: `tests_in_flight_post_no_upgrade` (1.00)
- `js_198_parity_status`: `partial_test` (0.99)
- `js_198_asserts_pre_open_state`: `false` (0.05)
- `js_198_unlisted_native_test_coverage`: `true` (0.97)

#### Batch 2: Remediation & Priority Scoring
- `remedy_js_049`: `inventory_and_test_refinement` (1.00)
- `remedy_js_153_156`: `targeted_gap_closure` (1.00)
- `remedy_js_198`: `assert_pre_open_and_map_test` (1.00)
- `priority_js_049`: Score `1.20` (`p2_medium`: 0.66, `p1_high`: 0.26)
- `priority_js_156`: Score `1.23` (`p2_medium`: 0.56, `p1_high`: 0.32)
- `priority_js_198`: Score `1.10` (`p2_medium`: 0.66, `p1_high`: 0.21)

---

### Detailed Per-ID Verified Audit

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ Case Summary                                                                                │
├────────┬──────────────────────────────────────────┬─────────────────────────────┬───────────┤
│ ID     │ Upstream Title                           │ Advisory Classification     │ Status    │
├────────┼──────────────────────────────────────────┼─────────────────────────────┼───────────┤
│ JS-049 │ should close engine on decode exception  │ reviewed_platform_boundary  │ Partial   │
│ JS-153 │ should defer close when upgrading        │ partial_test                │ Partial   │
│ JS-154 │ should close on upgradeError if deferred │ partial_test                │ Partial   │
│ JS-155 │ should not send packets if deferred      │ partial_test                │ Partial   │
│ JS-156 │ send buffered packets if close deferred  │ partial_test                │ Partial   │
│ JS-198 │ throttled timer checks timer state       │ partial_test                │ Partial   │
└────────┴──────────────────────────────────────────┴─────────────────────────────┴───────────┘
```

---

#### 1. JS-049: `should close the engine upon decoding exception`
- **Upstream Source**: `packages/socket.io-client/test/connection.ts` (lines 923–947)
- **Mapped Swift Tests**:
  - `Tests/TestSocketIO/SocketParseErrorTest.swift` (lines 21–36, `testUndecodableMessageClosesEngineWithParseError`)
  - `Tests/TestSocketIO/E2E/JSParityE2ETest.swift` (lines 941–988, `testParseErrorClosesEngineAndReconnectsWithFreshSession`)
- **Inventory Discrepancy**:
  `Documentation/JavaScriptTestInventory.csv` line 50 and `ReviewEvidence/JevParityBacklog-2026-09-19.csv` line 27 record `SocketParseErrorTest.testParseErrorClosesEngineAndReconnectsWithFreshSession`. No such method exists in `SocketParseErrorTest.swift`; it resides in `Tests/TestSocketIO/E2E/JSParityE2ETest.swift`. `SocketParseErrorTest` only exercises single-session engine closure with `reconnects(false)` against a mock engine.
- **Engine Object Replacement vs. Reused Object**:
  - **Upstream JS**: `Manager.open()` unconditionally instantiates `this.engine = new Engine(...)`. On reconnect, upstream asserts:
    1. `expect(manager.engine === engine).to.be(false)` (Engine object replacement).
    2. `expect(engine.readyState).to.eql("closed")` (Old engine permanently stopped).
  - **Swift Behavior**: `SocketManager.connect()` (`Source/SocketIO/Manager/SocketManager.swift:287–289`) only allocates a new engine if `engine == nil || forceNew`. By default (`forceNew == false`), `SocketManager` preserves and reuses the exact same `SocketEngine` instance. Inside `SocketEngine._connect()`, `resetEngine()` creates a fresh `URLSession`/transport and increments `generation`, but `manager.engine === engine` remains **true**.
  - **Observable Lifecycle Difference**:
    A caller retaining a reference to `manager.engine` in JS observes an immutable dead end: `readyState` remains `"closed"`, and no further events or packets arrive on that instance. In Swift, retaining `manager.engine` observes the object resurrect: its state transitions back to connecting/connected, its `sid` changes, and live traffic continues through that same object reference. A fresh `sid` proves a new transport session, but does **not** satisfy upstream object identity semantics.
- **Verified Gaps**:
  - Unasserted object replacement: `testParseErrorClosesEngineAndReconnectsWithFreshSession` explicitly bypasses `manager.engine !== engine` and `engine.readyState === "closed"`, checking only `newSid != oldSid`.
  - Inventory misattribution of the test suite file.
- **Minimal Implementation/Testing Changes**:
  1. Correct `Documentation/JavaScriptTestInventory.csv` line 50 to reference `Tests/TestSocketIO/E2E/JSParityE2ETest.swift:941`.
  2. Add a focused regression test in `SocketParseErrorTest.swift` exercising `forceNew: true`, asserting that when `forceNew` is active, `manager.engine !== oldEngine` and `oldEngine.closed == true` upon reconnection.
  3. Formally annotate in `ProtocolParityReview.md` that Swift default reconnect preserves `SocketEngine` identity as a reviewed platform boundary.

---

#### 2. JS-153: `should defer close when upgrading`
- **Upstream Source**: `packages/engine.io-client/test/connection.js` (lines 142–158)
- **Mapped Swift Tests**:
  - `Tests/TestSocketIO/SocketPollingCloseTest.swift` (lines 303–321, `testCloseIsDeferredWhileUpgradeIsPaused`)
  - `Tests/TestSocketIO/SocketNativeEngineTest.swift` (lines 312–333, `testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade`)
- **Transport Integration vs. Native Test Seams**:
  - Upstream attaches to live socket lifecycle events (`upgrading` → `upgrade` → `close`) and asserts `expect(upgraded).to.be(true)` when `close` fires.
  - `SocketPollingCloseTest.testCloseIsDeferredWhileUpgradeIsPaused` artificially forces `engine.setFastUpgrade(true)` and asserts that no HTTP POST is sent during the paused state. It **only tests the pause**; it never executes the upgrade or asserts the subsequent deferred close.
  - `SocketNativeEngineTest.testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade` drives the sequence across controlled seams (`NativePollingTestEngine` and `NativeEngineTransport`), proving the wire sequence: WebSocket `2probe` → `5` (upgrade) → `4buffered` → `1` (close), followed by `client.closes == ["io client disconnect"]`.
  - There is no live E2E integration test against a running Engine.IO server verifying deferred close during upgrade.
- **Verified Gaps**:
  - `SocketPollingCloseTest` leaves the engine paused and never completes the close.
  - Absence of an end-to-end integration test against `TestServerProcess` verifying that a mid-upgrade disconnect allows upgrade settlement before final teardown.
- **Minimal Implementation/Testing Changes**:
  1. In `SocketPollingCloseTest.swift`, extend `testCloseIsDeferredWhileUpgradeIsPaused` (or add a companion test) to clear `fastUpgrade` and verify that the deferred close completes cleanly.
  2. Add a live E2E test in `Tests/TestSocketIO/E2E/EngineRemainingParityE2ETest.swift` that initiates an upgrade, triggers `engine.disconnect()`, and verifies server-side session termination.

---

#### 3. JS-154: `should close on upgradeError if closing is deferred`
- **Upstream Source**: `packages/engine.io-client/test/connection.js` (lines 160–177)
- **Mapped Swift Test**:
  - `Tests/TestSocketIO/SocketNativeEngineTest.swift` (lines 338–353, `testCloseDeferredDuringUpgradeResumesOverPollingOnUpgradeError`)
- **Stimulus & Wire Sequence Comparison**:
  - Upstream triggers `socket.close()`, injects `socket.transport.onError("upgrade error")`, expects an `upgradeError` event, and asserts `expect(upgradeError).to.be(true)` when `"close"` fires.
  - Swift `SocketNativeEngineTest` simulates WebSocket failure via `candidate.onEvent?(.closed(..., error: EngineWebSocketError.closed))`. The engine cleanly falls back to polling, flushes `4held`, and closes (`client.closes == ["io client disconnect"]`).
  - Wire & Event differences:
    1. Upstream emits `upgradeError` on the socket. In Swift, probe transport failures are treated as silent recovery paths; `SocketEngineClient` has no `upgradeError` event and asserts `client.errors.isEmpty`.
    2. Swift asserts `engine.pollingWrites.contains("4held")`, but does not assert that the polling close packet `"1"` is emitted after `"4held"`.
- **Verified Gaps**:
  - Omission of explicit assertion that the close frame `"1"` is dispatched via polling write queue following `"4held"`.
  - Divergence in event reporting (`upgradeError` event is not exposed by `SocketEngineClient`).
- **Minimal Implementation/Testing Changes**:
  1. In `SocketNativeEngineTest.testCloseDeferredDuringUpgradeResumesOverPollingOnUpgradeError`, assert `engine.pollingWrites == ["4held", "1"]` (or verify that `"1"` follows `"4held"`).
  2. Document in `ProtocolParityReview.md` that upgrade probe errors do not surface as client errors when falling back to polling.

---

#### 4. JS-155: `should not send packets if closing is deferred`
- **Upstream Source**: `packages/engine.io-client/test/connection.js` (lines 179–195)
- **Mapped Swift Tests**:
  - `Tests/TestSocketIO/SocketPollingCloseTest.swift` (lines 303–321, `testCloseIsDeferredWhileUpgradeIsPaused`)
  - Subsidiary coverage in `SocketNativeEngineTest.swift` line 324 (`write("late")`)
- **Assertion Comparison**:
  - Upstream listens for `packetCreate` during the `upgrading` deferred-close window, calls `socket.send("hi")`, and verifies 200ms later that no packet was created (`noPacket == true`).
  - Swift `SocketEngine._write` (`Source/SocketIO/Engine/SocketEngine.swift:1068`) checks:
    ```swift
    guard connected, !closed, pendingCloseReason == nil else { completion?(); return }
    ```
    When `pendingCloseReason != nil`, writes return immediately without queuing to `probeWait` or `postWait`.
  - In `SocketPollingCloseTest`, `engine.write("late", ...)` produces no POST (`fixture.posts.isEmpty`) and leaves `postWait` empty. In `SocketNativeEngineTest`, `"late"` is excluded from `candidate.batches`.
- **Verified Gaps**:
  - Upstream checks `packetCreate` suppression during active transport upgrading; Swift checks wire queue emptiness on an engine with manually forced `fastUpgrade = true`.
- **Minimal Implementation/Testing Changes**:
  1. Add an explicit assertion in `SocketNativeEngineTest.testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade` verifying that `"late"` write completion was called immediately and never enqueued.

---

#### 5. JS-156: `should send all buffered packets if closing is deferred`
- **Upstream Source**: `packages/engine.io-client/test/connection.js` (lines 197–210)
- **Mapped Swift Tests**:
  - `Tests/TestSocketIO/SocketPollingCloseTest.swift` (lines 260–296, `testCloseWaitsForInFlightPostAndCompletesPendingWritesOnce`)
  - `Tests/TestSocketIO/SocketNativeEngineTest.swift` (lines 312–333, `testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade`)
- **Inventory Mapping & Wire Sequence**:
  - **Spurious Mapping**: `testCloseWaitsForInFlightPostAndCompletesPendingWritesOnce` does **not** test upgrading. It tests draining an in-flight HTTP POST over polling during a standard close. Mapping it to JS-156 is invalid.
  - **True Seam Test**: `SocketNativeEngineTest.testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade` accurately buffers `"buffered"`, defers close, completes fast upgrade via `doFastUpgrade()`, and verifies candidate batches: `[.text("2probe"), .text("5"), .text("4buffered"), .text("1")]`.
  - **Buffer Drain Assertion**: Upstream asserts `expect(socket.writeBuffer).to.have.length(0)` on close. Swift verifies transmission of the message batch, but does not assert `engine.probeWait.isEmpty` on close.
- **Verified Gaps**:
  - Inventory includes an unrelated HTTP polling test (`testCloseWaitsForInFlightPostAndCompletesPendingWritesOnce`).
  - Missing post-close buffer vacancy assertion (`engine.probeWait.isEmpty`).
- **Minimal Implementation/Testing Changes**:
  1. In `Documentation/JavaScriptTestInventory.csv` line 157, remove `SocketPollingCloseTest.testCloseWaitsForInFlightPostAndCompletesPendingWritesOnce`.
  2. In `SocketNativeEngineTest.testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade`, add `XCTAssertTrue(engine.probeWait.isEmpty)`.

---

#### 6. JS-198: `Socket > throttled timer > checks the state of the timer`
- **Upstream Source**: `packages/engine.io-client/test/socket.js` (lines 288–311)
- **Mapped Swift Tests**:
  - `Tests/TestSocketIO/SocketNativeEngineTest.swift` (lines 74–87, `testApplicationTrafficCannotRefreshTheServerHeartbeatDeadline`)
  - `Tests/TestSocketIO/SocketRetrySafetyTest.swift` (lines 32–42, `testExpiredHeartbeatBuffersInsteadOfSendingOnTheStaleConnection`)
- **Omitted Adjacent Test**:
  - `Tests/TestSocketIO/SocketNativeEngineTest.swift` (lines 89–105, `testOnlyPingResetsTheDeadlineAndExpiredChecksCloseOnce`) directly mirrors JS-198 (tests monotonic time advancement past deadline, repeated `hasPingExpired` calls, and single close with `"ping timeout"`), but is **omitted from the inventory mapping**.
  - `SocketRetrySafetyTest` tests client-level emit buffering across disconnections, not the Engine.IO throttled timer contract.
- **Stimulus & Pre-Open State Comparison**:
  - Upstream asserts `expect(socket._hasPingExpired()).to.be(false)` **before open**, and again immediately upon `open`.
  - Swift `SocketEngine.hasPingExpired` (`Source/SocketIO/Engine/SocketEngine.swift:840`):
    ```swift
    guard self.connected, !self.closed else { return false }
    ```
    Returns `false` when not connected, but **none** of the Swift tests assert `engine.hasPingExpired == false` prior to opening the transport.
- **Verified Gaps**:
  - Missing assertion of `engine.hasPingExpired == false` prior to handshake open.
  - Inventory omits the closest matching test (`testOnlyPingResetsTheDeadlineAndExpiredChecksCloseOnce`) and maps an unrelated client-level emit test.
- **Minimal Implementation/Testing Changes**:
  1. In `Documentation/JavaScriptTestInventory.csv` line 199 and backlog CSV, map `SocketNativeEngineTest.testOnlyPingResetsTheDeadlineAndExpiredChecksCloseOnce`, removing `SocketRetrySafetyTest`.
  2. In `SocketNativeEngineTest.testOnlyPingResetsTheDeadlineAndExpiredChecksCloseOnce`, add `XCTAssertFalse(engine.hasPingExpired)` immediately after `make()` before calling `open()`.

---

### Remediation Action Plan & Priority Matrix

| Test ID | Priority | Classification | Required Minimal Changes |
| :--- | :---: | :--- | :--- |
| **JS-049** | Medium (`1.20`) | `reviewed_platform_boundary` | 1. Fix inventory pointer to `Tests/TestSocketIO/E2E/JSParityE2ETest.swift:941`.<br>2. Add unit test asserting `forceNew: true` replaces engine object and marks old engine closed.<br>3. Document default object reuse lifecycle semantics. |
| **JS-153** | Medium (`1.20`) | `partial_test` | 1. Resume and complete deferred close in `SocketPollingCloseTest`.<br>2. Add real transport E2E deferred-close test in `EngineRemainingParityE2ETest`. |
| **JS-154** | Medium (`1.20`) | `partial_test` | 1. Assert close frame `"1"` follows `"4held"` in `NativePollingTestEngine.pollingWrites`.<br>2. Document silent probe error recovery vs upstream `upgradeError` event. |
| **JS-155** | Medium (`1.20`) | `partial_test` | 1. Assert immediate local completion and lack of buffer retention in `SocketNativeEngineTest`. |
| **JS-156** | Medium (`1.23`) | `partial_test` | 1. Remove spurious polling POST drain test from inventory mapping.<br>2. Assert `engine.probeWait.isEmpty` upon close in `SocketNativeEngineTest`. |
| **JS-198** | Medium (`1.10`) | `partial_test` | 1. Map `testOnlyPingResetsTheDeadlineAndExpiredChecksCloseOnce` in inventory; remove `SocketRetrySafetyTest`.<br>2. Add `XCTAssertFalse(engine.hasPingExpired)` before connection open. |
