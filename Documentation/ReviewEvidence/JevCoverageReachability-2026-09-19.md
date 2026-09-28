# Advisory Jev review: coverage reachability

Untrusted advisory review, independently checked against current source. No execution or parity certification.

### Evaluated Scope & Symbols

- **`Source/SocketIO/Parse/SocketPacket.swift`**:
  - `SocketPacket.payloadJSON()` (lines 174–182)
  - `SocketPacket.jsonString(from:fragmentsAllowed:)` (lines 192–218)
  - `SocketPacket.jsonSafeEmitData(_:allowBinary:)` (lines 434–440)
  - `SocketEmitNormalizer.normalize(_:depth:path:)` (lines 589–648)
  - `SocketEmitNormalizer.foundationArray(_:depth:path:)` (lines 650–670)
  - `SocketEmitNormalizer.foundationDictionary(_:depth:path:)` (lines 672–698)
- **`Source/SocketIO/Security/SocketSessionDelegateProxy.swift`**:
  - `urlSession(_:dataTask:didReceive:completionHandler:)` (lines 138–159)
  - `urlSession(_:dataTask:didReceive:)` (lines 163–185)
  - `finishBoundedBody(for:error:)` (lines 187–190)
- **`Source/SocketIO/Client/SocketIOClient.swift`**:
  - `SocketIOClient.emit(...)` validation gate (lines 897–913)
  - `SocketIOClient.sendPacket(...)` encoder error handler (lines 956–970)

---

### TypeSafe Jev Advisory Evaluation

The independent typed evaluation returned the following classifications against the source evidence:

| Question ID | Jev Verdict Choice | Probabilities |
| :--- | :--- | :--- |
| `socket_packet_unserializable_custom_data` | `reachable_public_stimuli` | `reachable_public_stimuli: 0.99`, `defensive_impossible_state: 0.01` |
| `json_serialization_catch_and_utf8` | `defensive_impossible_state` | `defensive_impossible_state: 0.71`, `reachable_public_stimuli: 0.28`, `insufficient_evidence: 0.01` |
| `expected_argument_array_cast` | `defensive_impossible_state` | `defensive_impossible_state: 0.84`, `reachable_public_stimuli: 0.13`, `insufficient_evidence: 0.03` |
| `foundation_null_and_non_string_keys` | `mixed_reachability` | `mixed_reachability: 0.79`, `both_reachable: 0.10`, `both_defensive_impossible: 0.10` |
| `session_delegate_missing_task_state` | `reachable_public_stimuli` | `reachable_public_stimuli: 0.81`, `defensive_impossible_state: 0.08`, `insufficient_evidence: 0.11` |
| `client_send_packet_catch` | `defensive_impossible_state` | `defensive_impossible_state: 1.00`, `reachable_public_stimuli: 0.00` |

*(Note: Probabilities are model estimates on the provided source evidence, not empirical coverage or test execution metrics.)*

---

### Detailed Audit of Unexecuted Rejection Branches

#### 1. Unserializable Custom Data / Missing Serialization Support
- **Location**: `SocketPacket.swift` lines 614, 646–647
- **Classification**: **Reachable Public Stimuli**
- **Analysis**:
  - In `SocketEmitNormalizer.normalize`, any custom Swift `struct` or `class` that does not bridge to Foundation JSON types falls through to `case is [AnyHashable: Any]: throw SocketPacketError.nonStringKey` or `default: throw SocketPacketError.unsupportedValue(path: path, type: ...)`.
- **Suggested Minimal Test**:
  ```swift
  struct CustomUnserializableType {}
  XCTAssertThrowsError(try SocketPacket.jsonSafeEmitData([CustomUnserializableType()], allowBinary: false)) { error in
      guard case SocketPacketError.unsupportedValue = error else {
          XCTFail("Expected unsupportedValue, got \(error)")
          return
      }
  }
  ```

#### 2. `JSONSerialization` Catch Block & Non-UTF8 Return
- **Location**: `SocketPacket.swift` lines 209–211 (`catch` on `JSONSerialization.data`) and lines 213–215 (`guard String(data: json, encoding: .utf8)`)
- **Classification**: **Defensive Impossible State** (Skip testing)
- **Analysis**:
  - Prior to line 208, `JSONSerialization.isValidJSONObject` is verified (line 197), and `normalizer.normalize(value)` has already converted non-finite numbers (`NaN`/`Infinity`) to `NSNull` (line 559). Under Foundation runtime specifications, `JSONSerialization.data(withJSONObject:)` does not throw on graphs certified by `isValidJSONObject`.
  - Foundation’s `JSONSerialization.data` is guaranteed by contract to emit valid UTF-8. Producing non-UTF-8 bytes from valid JSON data is impossible without memory corruption.
  - **Recommendation**: Do not remove the guard or attempt unsafe memory corruption to force execution; keep as defensive hardening.

#### 3. Expected Argument Array Cast
- **Location**: `SocketPacket.swift` lines 436–438:
  ```swift
  guard let normalized = try normalizer.normalize(items) as? [Any] else {
      throw SocketPacketError.unserializablePayload("expected an argument array")
  }
  ```
- **Classification**: **Defensive Impossible State** (Skip testing)
- **Analysis**:
  - The argument `items` has concrete type `[Any]`. In `SocketEmitNormalizer.normalize`, the check `Swift.type(of: value) is AnyClass` evaluates to `false` for native Swift arrays. It enters `case let array as [Any]:` (line 624) and constructs and returns `[Any]` (`result`).
  - Thus, if `normalize` does not throw an error, its return value is dynamically and statically `[Any]`. The conditional downcast `as? [Any]` cannot evaluate to `nil`.
  - **Recommendation**: Defensive impossible state. Do not tamper with code guards solely to achieve line coverage.

#### 4. Foundation Null Entries vs. Non-String Dictionary Keys
- **Location**: `SocketPacket.swift` line 663 (`"null Foundation array entry"`) and lines 645, 688 (`nonStringKey`)
- **Classification**: **Mixed Reachability**
  - **Non-String Dictionary Keys (`reachable_public_stimuli`)**:
    An `NSDictionary` with non-`NSString` keys (e.g. `[NSNumber(value: 1): "value"] as NSDictionary`) or a Swift dictionary `[Int: String]` passed into `jsonSafeEmitData` directly triggers `SocketPacketError.nonStringKey`.
    - **Suggested Minimal Test**:
      ```swift
      let invalidDict = NSDictionary(object: "bar", forKey: NSNumber(value: 42))
      XCTAssertThrowsError(try SocketPacket.jsonSafeEmitData([invalidDict], allowBinary: false)) { error in
          guard case SocketPacketError.nonStringKey = error else {
              XCTFail("Expected nonStringKey, got \(error)")
              return
          }
      }
      ```
  - **Null Foundation Array Entry (`unsafe_corruption_only`)**:
    Standard `NSArray` enforces non-nil objects at runtime in both Swift and Objective-C (`insertObject:atIndex:` raises `NSInvalidArgumentException`). A `NULL` pointer from `CFArrayGetValueAtIndex` requires constructing a custom `CFArrayCreate` with NULL callbacks or raw pointer memory injection.
    - **Recommendation**: Skip testing the null CFArray entry; it is a defensive boundary guard against C/CoreFoundation edge-case bridges.

#### 5. Session Delegate Missing Task State Branches
- **Location**: `SocketSessionDelegateProxy.swift` lines 141–146, 165–169, 189–190
- **Classification**: **Reachable Public Stimuli**
- **Analysis**:
  - `boundedBodies` is keyed by `URLSessionTask.taskIdentifier`.
  - Branches where `boundedBodies[taskIdentifier] == nil` are naturally triggered when:
    1. An unmanaged task runs through the session (a task not registered via `boundBody(of:to:completion:)`).
    2. A response/data delegate callback is dispatched after a task was already cancelled or completed (`finishBoundedBody` removes the identifier from the table at line 189).
    3. In `didReceive data`, `body.overflow != nil` occurs if chunked data arrives after the limit was exceeded and `dataTask.cancel()` was called but before session completion.
- **Suggested Minimal Test**:
  - Invoke `delegate.urlSession(session, dataTask: unregisteredTask, didReceive: response) { disposition in XCTAssertEqual(disposition, .allow) }` directly on a `SocketSessionDelegateProxy` instance with an unregistered mock/dummy `URLSessionDataTask`.

#### 6. Client `sendPacket` Catch After Earlier Validation
- **Location**: `SocketIOClient.swift` lines 960–970
- **Classification**: **Defensive Impossible State** (Skip testing)
- **Analysis**:
  - All public emit entry points pass their payloads through `SocketPacket.jsonSafeEmitData(unsafeData, allowBinary: binary)` (lines 904–913). Any encoding incompatibility causes `emit` to fail immediately and return early.
  - When `sendPacket` runs, `data` consists exclusively of normalized JSON-safe Foundation types. As noted in the codebase comment (lines 961–963):
    `// Unreachable from the emit entry points, which validate the payload before anything is buffered, queued or written.`
  - **Recommendation**: Defensive impossible state from public entry points. Do not mock internal pipeline stages to bypass normalization.

---

### Summary & Limitations

- **Actionable Tests to Add**:
  1. Emit payload containing unsupported custom Swift types (`SocketPacketError.unsupportedValue`).
  2. Emit payload containing `NSDictionary` with non-`NSString` keys or `[AnyHashable: Any]` (`SocketPacketError.nonStringKey`).
  3. `SocketSessionDelegateProxy` delegate calls with unregistered/orphaned task identifiers.
- **Defensive Safeguards to Leave Untested**:
  - `JSONSerialization.data` `catch` and non-UTF8 conversion guard in `SocketPacket.jsonString`.
  - `guard ... as? [Any]` cast in `SocketPacket.jsonSafeEmitData`.
  - `CFArrayGetValueAtIndex` null checks in `foundationArray`.
  - `sendPacket` fallback catch block in `SocketIOClient`.
- **Operational Limitations**: Read-only evaluation; no source files were modified, no test runners were executed, and safety guards remain intact.
