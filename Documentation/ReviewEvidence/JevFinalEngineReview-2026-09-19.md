# Advisory final engine review

Read-only external review, not execution evidence. Recommendations were checked independently; see FinalParityAssertions-2026-09-19.md for dispositions.

### 1. Scope & Review Methodology

- **Target Diff**: `c858193..HEAD` on branch `feat/socketio4-swift6.4` (commits `df43cf0` through `70320a8`).
- **Focus Areas**:
  1. `SocketEnginePacketCodec` (framing, payload decoding, base64 handling)
  2. Raw binary send (`SocketEngine.send(Data, completion:)`) across probing and deferred closing
  3. Optional upgrade delegate callbacks (`engineDidCompleteUpgrade`, `engineDidFailUpgrade(error:)`)
  4. Native-engine replacement on parser error (`SocketManager.connect()`, `addEngine()`, `parserFailed`)
- **Omitted Scope**: Unrelated diffs, CI workflows, documentation syncs, custom query encoding, non-engine transport configurations.
- **Evaluation Mechanism**: Exactly one TypeSafe Jev evaluation call (8 structured questions against shared repository state). No write tools or CI triggers were used.
- **Advisory Notice**: Jev evaluations and coordinator findings are advisory only. They do not certify compliance, authorize release gates, or guarantee runtime success. Probabilities are model estimates, not coverage percentages.

---

### 2. TypeSafe Jev Tool Outputs

```json
{
  "answers": {
    "q1_codec_framing": {
      "type": "choice",
      "choice": "framing_sound",
      "probabilities": { "framing_sound": 0.65, "framing_defect": 0.34, "insufficient_evidence": 0.01 }
    },
    "q2_empty_payload": {
      "type": "choice",
      "choice": "empty_payload_defect",
      "probabilities": { "empty_payload_defect": 0.39, "empty_payload_sound": 0.35, "insufficient_evidence": 0.26 }
    },
    "q3_raw_binary_probing": {
      "type": "choice",
      "choice": "probing_send_sound",
      "probabilities": { "probing_send_sound": 0.96, "probing_send_defect": 0.03, "insufficient_evidence": 0.01 }
    },
    "q4_closing_suppression": {
      "type": "choice",
      "choice": "closing_suppression_sound",
      "probabilities": { "closing_suppression_sound": 1.00, "closing_suppression_defect": 0.00, "insufficient_evidence": 0.00 }
    },
    "q5_upgrade_callbacks_order": {
      "type": "choice",
      "choice": "upgrade_callbacks_sound",
      "probabilities": { "upgrade_callbacks_sound": 0.98, "upgrade_callbacks_defect": 0.02, "insufficient_evidence": 0.00 }
    },
    "q6_manager_upgrade_boundary": {
      "type": "choice",
      "choice": "manager_boundary_sound",
      "probabilities": { "manager_boundary_sound": 0.72, "manager_missing_forwarding": 0.23, "insufficient_evidence": 0.05 }
    },
    "q7_engine_replacement": {
      "type": "choice",
      "choice": "replacement_sound",
      "probabilities": { "replacement_sound": 0.95, "replacement_defect": 0.04, "insufficient_evidence": 0.01 }
    },
    "q8_add_engine_cleanup": {
      "type": "choice",
      "choice": "cleanup_sound",
      "probabilities": { "cleanup_sound": 0.87, "cleanup_defect": 0.11, "insufficient_evidence": 0.02 }
    }
  }
}
```

---

### 3. Detailed Findings & Independent Verification

#### Focus Area 1: `SocketEnginePacketCodec`

1. **Empty Polling Response Terminates Engine as Parser Error (Disputed / Potential Regression)**
   - **Finding Status**: *Uncertain / Behavioral Risk* (Jev split: `empty_payload_defect` 0.39 vs `empty_payload_sound` 0.35).
   - **Symbol**: `Source/SocketIO/Engine/SocketEnginePacketCodec.swift`: `SocketEnginePacketCodec.decodePayload(_:)` (lines 54–62) and `Source/SocketIO/Engine/SocketEnginePollable.swift`: `parsePollingMessage(_:)` (lines 327–338).
   - **Concrete Failing Sequence**:
     1. Prior to this diff, `parsePollingMessage(_:)` began with `guard !str.isEmpty else { return }`, which silently ignored empty HTTP long-polling response bodies.
     2. In the current diff, `guard !str.isEmpty` was removed to align with unit test `SocketEnginePacketCodecTest.testMalformedPollingPayloadReportsParserErrorAndCloses` (which expects `""` to report `"parser error"` and close the engine with `"transport error"`).
     3. When a reverse proxy, load balancer, or server returns an HTTP 200 with an empty body (`""`), `decodePayload("")` evaluates `"".components(separatedBy: "\u{1e}")` as `[""]`.
     4. `decode(.text(""))` fails at `guard let first = bytes.first else { return .failure(.parserError) }`.
     5. `dispatchPollingPayload` encounters `.failure` and invokes `checkAndHandleEngineError("")` -> `didError(reason: "parser error")`, aborting an otherwise healthy polling session.
   - **Minimal Fix**:
     If live empty polling responses should be treated as benign keep-alives / no-ops rather than fatal protocol errors, restore the guard in `Source/SocketIO/Engine/SocketEnginePollable.swift`:
     ```swift
     func parsePollingMessage(_ str: String) {
         guard !str.isEmpty else { return }
         DefaultSocketLogger.Logger.log("Got poll message: \(str)", type: "SocketEnginePolling")
         if let engine = self as? SocketEngine { engine.dispatchPollingPayload(str) }
         ...
     }
     ```

2. **Payload-less Message Packet Asymmetry under Equatable**
   - **Finding Status**: *Verified Correctness Nuance* (Jev `framing_sound`: 0.65 vs `framing_defect`: 0.34).
   - **Symbol**: `Source/SocketIO/Engine/SocketEnginePacketCodec.swift`: `SocketEnginePacketCodec.decode(_:)` (line 49).
   - **Concrete Sequence**:
     - `SocketEnginePacket(type: .message, data: .text(""))` encodes to `"4"`.
     - `decode(.text("4"))` executes `let data: EngineWebSocketMessage? = bytes.count == 1 ? nil : .text(...)`, returning `SocketEnginePacket(type: .message, data: nil)`.
     - Comparing the original packet to the decoded packet via `SocketEnginePacket.==` evaluates to `false` because `.text("") != nil`.
     - *Runtime Impact*: When `dispatchDecodedPacket` handles this packet, `if case .text(let value) = packet.data { text = value } else { text = "" }` normalizes `nil` to `""`, so client message dispatch is unaffected.

---

<h4>Focus Area 2: Raw Binary Send Across Probing and Closing</h4>

1. **Uninvoked Completion on Empty Binary Array in Polling Mode**
   - **Finding Status**: *Verified Correctness Defect* (Edge Case).
   - **Symbol**: `Source/SocketIO/Engine/SocketEngine.swift`: `sendPreparedWrite(_:withType:withData:rawBinary:completion:)` (lines 1089–1098).
   - **Concrete Failing Sequence**:
     1. An internal caller invokes `_write("", withType: .message, withData: [], rawBinary: true, completion: completion)`.
     2. While polling is active, `frames = data.map { ... }` produces an empty array `[]`.
     3. The loop `for frame in frames { ... }` does not execute; nothing is appended to `postWait`.
     4. `completion` is neither enqueued nor called. The caller’s completion handler hangs permanently.
     *(Note: Public `SocketEngine.send(Data)` passes `withData: [data]`, which always has length 1 even when data is 0 bytes; however, internal writes or extensions allowing multiple data buffers are vulnerable).*
   - **Minimal Fix**:
     In `Source/SocketIO/Engine/SocketEngine.swift`:
     ```swift
     if rawBinary {
         if data.isEmpty { completion?(); return }
         let frames = data.map { ... }
     ```

2. **Probing and Deferred Close Correctness**
   - **Finding Status**: *Verified Sound* (Jev `probing_send_sound`: 0.96, `closing_suppression_sound`: 1.00).
   - **Sequence Verification**:
     - `engine.send(data)` during `probing == true`: Safely enqueued in `probeWait` as `("", .message, [data], true, completion)`.
     - On successful upgrade: `doFastUpgrade()` sets `probing = false`, sends the upgrade frame `"5"`, drains `postWait`, and calls `flushProbeWait()`, which encodes `data` with `supportsBinary: true` (unprefixed binary WebSocket frame).
     - On upgrade failure: `websocketDidDisconnect()` resets `probing = false`, falls back to polling, and flushes `probeWait` with `supportsBinary: false` (`"b" + base64`), maintaining FIFO sequence before polling requests.
     - During deferred close (`pendingCloseReason != nil`): `_write` immediately checks `guard connected, !closed, pendingCloseReason == nil else { completion?(); return }`, preventing packet generation and invoking local completion immediately.

---

<h4>Focus Area 3: Optional Upgrade Callbacks</h4>

1. **Callback Sequence and Idempotence**
   - **Finding Status**: *Verified Sound* (Jev `upgrade_callbacks_sound`: 0.98).
   - **Symbols**:
     - `Source/SocketIO/Engine/SocketEngineClient.swift`: `engineDidCompleteUpgrade()`, `engineDidFailUpgrade(error:)`
     - `Source/SocketIO/Engine/SocketEngine.swift`: lines 332–335, 650, 1137–1139.
   - **Sequence Verification**:
     - `engineDidCompleteUpgrade()` fires in `doFastUpgrade()` before flushing queues and settling deferred close. In `testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade`, `client.upgradeEvents` records `["upgrade", "close"]` in exact order.
     - `engineDidFailUpgrade(error:)` fires on candidate failure in `websocketDidDisconnect()` before deferred close (`["upgradeError", "close"]`).
     - `engineDidFailUpgrade(error:)` fires in `closeOutEngine()` when `wasUpgrading == true` (active polling transport failure). A subsequent candidate failure frame is suppressed because `closed == true`.

2. **Omission in `SocketManager` as an Architectural Boundary**
   - **Finding Status**: *Verified Architectural Boundary* (Jev `manager_boundary_sound`: 0.72 vs `manager_missing_forwarding`: 0.23).
   - **Symbol**: `Source/SocketIO/Manager/SocketManager.swift`.
   - **Assessment**:
     `SocketManager` conforms to `SocketEngineClient` but leaves `engineDidCompleteUpgrade` and `engineDidFailUpgrade` unimplemented. `SocketManager` forwards `.websocketUpgrade` (HTTP headers) to `SocketIOClient`, but Socket.IO protocol specification does not expose low-level Engine.IO upgrade state transitions. Marking them optional in `SocketEngineClient` allows specialized test harnesses and custom delegates to inspect transport transitions without breaking `SocketManager`.

---

<h4>Focus Area 4: Native-Engine Replacement After Parser Error</h4>

1. **Selective Replacement Guard**
   - **Finding Status**: *Verified Sound* (Jev `replacement_sound`: 0.95).
   - **Symbol**: `Source/SocketIO/Manager/SocketManager.swift`: lines 287–293.
   - **Assessment**:
     ```swift
     if engine == nil || forceNew || (parserFailed && engine is SocketEngine) {
         addEngine()
     }
     ```
     When an undecodable packet triggers `engineDidReceiveUndecodableData`, `parserFailed = true` is set. On reconnection, `addEngine()` replaces the built-in `SocketEngine`. Custom `SocketEngineSpec` conformers (`!(engine is SocketEngine)`) are preserved so user-supplied engines manage their own lifecycle.

2. **Old Engine Teardown Safety in `addEngine()`**
   - **Finding Status**: *Verified Sound* (Jev `cleanup_sound`: 0.87).
   - **Symbol**: `Source/SocketIO/Manager/SocketManager.swift`: lines 265–276.
   - **Assessment**:
     ```swift
     private func addEngine() {
         engine?.engineQueue.sync {
             self.engine?.client = nil
             self.engine?.disconnect(reason: "io client disconnect")
         }
         engine = SocketEngine(client: self, url: socketURL, config: config)
     }
     ```
     Detaching `client = nil` synchronously on `engineQueue` guarantees that when `_disconnect` completes on `engineQueue`, the old engine cannot dispatch callbacks into `SocketManager`.
     *Deadlock analysis*: `engineQueue` is a dedicated serial queue that never synchronously invokes `handleQueue`; therefore, calling `engineQueue.sync` from `handleQueue` or the caller thread is free of lock-inversion deadlock.

---

### 4. Summary of Concrete Recommendations

| Area | Symbol | Failure Condition | Severity / Status | Recommended Fix |
|---|---|---|---|---|
| **Codec / Polling** | `SocketEnginePollable.parsePollingMessage` | Empty HTTP 200 polling payload triggers fatal parser error and engine termination | Medium / Uncertain | Guard `!str.isEmpty` before passing to `dispatchPollingPayload` if reverse proxies may emit empty bodies. |
| **Raw Binary Send** | `SocketEngine.sendPreparedWrite` | Empty `data: []` with `rawBinary: true` in polling mode leaks completion without calling it | Low / Edge Case | Add `if data.isEmpty { completion?(); return }` at the start of `rawBinary` handling. |
| **Upgrade Callbacks** | `SocketEngineClient` | Optional upgrade methods not implemented on `SocketManager` | Sound / By Design | Maintain optional `@objc` protocol declaration; documented as low-level engine hook. |
| **Engine Replacement** | `SocketManager.connect` | Built-in engine replacement on parser failure | Sound / Verified | Retain `parserFailed && engine is SocketEngine` check. |
