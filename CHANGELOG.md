## 17.1.0 — 2026-09-21

- Reset omitted `.clientCertificate` and `.requestTimeout` options when a manager applies a new configuration to a reused engine, so removed credentials and request deadlines do not leak into later sessions.
- Complete per-socket connect-timeout cleanup: a timed-out namespace now emits `.disconnect`, settles acknowledgements using the normal close rules, preserves unsent buffered acknowledgements, and remains eligible for automatic reconnection.
- Protect reentrant replacement connects with a connection generation, so a timeout work item that has already started cannot finish by interrupting a newer attempt.
- Match client-certificate challenge hosts using Foundation's IDNA form, including Unicode/Punycode spellings, case-insensitivity and one trailing DNS root dot, while continuing to reject different or malformed origins.
- Add regression coverage for configuration removal, timeout cleanup and reentrant reconnects, host canonicalization and client-certificate challenge decisions.
- See [17.1.0 release notes](Documentation/Release17.1.0.md) for behavior changes and validation scope.

## 17.0.1 — 2026-09-19

- Fix Foundation URL construction crashes from `<`, `>`, backslash and backtick in connect parameters; encode keys and values with JavaScript `encodeURIComponent` semantics (socketio/socket.io-client-swift#1421).
- Cancel per-socket connection timeouts after success, disconnection or replacement so stale deadlines cannot interrupt reconnects (socketio/socket.io-client-swift#887).
- Derive `defaultSocket`'s namespace from the manager URL path; explicitly select `/` with `socket(forNamespace:)` when required (socketio/socket.io-client-swift#1297).
- Add `.clientCertificate(URLCredential)` for mutual TLS across polling, WebSocket and upgrades, scoped to the configured TLS origin (socketio/socket.io-client-swift#857, socketio/socket.io-client-swift#936, socketio/socket.io-client-swift#1157).
- Add `.requestTimeout(Double)` in seconds for polling handshake, GET and POST requests, covering idle and total transfer time while preserving native defaults when omitted (socketio/socket.io-client-swift#681).
- Add regression tests, real-server TLS/timeout fixtures and the upstream triage report with evaluation evidence.
- See [17.0.1 release notes](Documentation/Release17.0.1.md) for behavior changes and validation scope.
- Swift Package Manager is the only supported installation method. Carthage, CocoaPods and the Xcode project are removed.
- Remove completed review-audit notes that are superseded by `PARITY.md` and the gated inventory.

## 17.0.0 — 2026-09-19

- Share ordered retries across callback, async and legacy acknowledgement APIs; support cancellation and per-socket timeout/retry overrides.
- Buffer pre-connect incoming events generally, preserving receive/send/connect ordering and clearing failed connection state.
- Add polling/WebSocket transport lists, `tryAllTransports` and `rememberUpgrade`.
- Publish stable Swift Package Manager version `17.0.0` with immutable tag `v17.0.0`.
- Keep WebTransport/stream codec explicitly unsupported. All 195 applicable upstream runtime declarations have native assertion mappings; see [release notes and validation scope](Documentation/Release17.md).

The entries below record development history leading up to 17.0.0. Earlier entries describe intermediate behavior; the release notes and current migration guides describe the final public API.

## Native configuration cleanup (2026-09-19)

- Remove obsolete `compress`, `selfSigned`, `enableSOCKSProxy` and `useCustomEngine` typed options, unused engine properties and mock requirements. Removed dictionary keys now fail validation for all values, including `false`.
- Remove obsolete configuration tests, the Engine.IO 3 ping stub, historical migration guides and generated 16.x API pages. Keep native deflate interoperability and old-protocol rejection regressions.
- Treat the 43 explicitly reviewed unsupported-feature test IDs as resolved parity exclusions, with required reasons. Supported behavior still requires executable parity evidence; no 100% coverage claim.

## Native transport parity follow-up (2026-09-19)

- Add explicit, private-cookie `withCredentials`, WebSocket `forceBase64` and `addTrailingSlash` options.
- Migration: server-cookie replay defaults to off and no longer uses the application-wide cookie jar. Explicit cookie/header configuration is preserved.
- Carry bounded native HTTP and WebSocket error details through error/close notifications. Snapshot close codes before URLSession cancellation can erase them.
- Add raw Engine.IO wire, cookie isolation/upgrade, Unicode, binary parser and error regressions. Make polling fixture observation passive and replace blocking waits in the async acknowledgement test.
- Classify all 44 previously unmapped declarations: 29 have reviewed native regression contracts and 15 have explicit API/platform boundaries. Zero unmapped entries is not full upstream assertion parity.

## Unreleased: client parity follow-up

- Fix same-turn incoming/outgoing multi-listener registration/removal and modern catch-all lifecycle filtering; preserve legacy `onAny`.
- Clear sent modern acknowledgements on automatic reconnect, preserving buffered acks and reentrant successor registrations.
- Drain ordered retries synchronously on the owner queue.
- Treat explicit empty connection queries as overrides and protect engine-owned query keys.
- Add exact ordering/binary/URI/remote-close regressions, bounded fixture startup, pinned dependencies, two-way encoder evidence and executable parity-contract checks.
- Export library code coverage and run the pinned upstream Node client suites; no full-platform or 100% parity claim.

## 17.0.0-native.1 (unreleased)

- Replace the WebSocket backend with URLSessionWebSocketTask; remove the third-party dependency from every build definition.
- Integrate ordered native sends, once-only completion/close handling, stale-callback isolation and real writable/backpressure state.
- Preserve the polling GET+POST upgrade barrier, maxPayload batching, manager timeouts and reconnect behavior.
- Add shared explicit TLS policy, certificate pinning/private anchors and fail-closed configuration migration.
- Breaking: remove concrete `ws` API; migrate `security`; reject unsupported compression, trust-all and SOCKS options. See `Documentation/NativeWebSocketTransport.md`.

# Unreleased

## Breaking changes (17.0.0)

- **Reconnect attempts wait for their backoff before running, and the defaults are the JavaScript ones.** `SocketManager` used to start the first reconnect attempt immediately after a drop and only spaced the *following* attempts by `reconnectWait`; because a successful handshake reset the attempt counter, a connection that dropped right after every handshake (for example a WebSocket that dies during the transport upgrade) reconnected in a tight loop. JS `Manager.reconnect()` waits `backoff.duration()` first, then emits `reconnect_attempt` and opens. The manager now does the same with a cancellable timer, `reconnectWait` defaults to 1 s (JS `reconnectionDelay`, was 10), `reconnectWaitMax` to 5 s (JS `reconnectionDelayMax`, was 30), the backoff factor is 2 (was 1.5) and the jitter goes in both directions (JS `backo2`). `disconnect()` cancels a pending attempt (JS `skipReconnect`).
- **The manager closes when its last active socket disconnects** (JS `Manager._destroy` → `_close()`): the engine is released and a running reconnect loop stops. Previously the loop kept running with nothing to re-join. A socket that never connected no longer receives a `.disconnect` from that close, matching JS where only subscribed sockets hear `Manager.onclose`.
- **A WebSocket failure is reported with its native detail.** `websocketDidDisconnect` dropped the error, close code and close reason of a WebSocket that failed under an established connection and only reported `.disconnect("transport error")`. The `.error` client event now carries `domain/code: description`, the underlying error, the close code and the close reason before the close, as engine.io-client's `_onError` emits `error` before `_onClose`. The native transport logs the same detail (`URLSessionWebSocketTransport` "WebSocket finish: …") when it tears a connection down.

- **Reconnect events now mean what they mean in JavaScript.** `.reconnect` used to fire when reconnection *started*, carrying the disconnect reason; it now fires when a reconnection *succeeded*, carrying the 1-based number of the attempt that succeeded (JS `Manager.onreconnect` → `reconnect`). `.reconnectAttempt` used to carry the number of attempts *remaining*; it now carries the 1-based number of the attempt being made (JS `reconnect_attempt` with `backoff.attempts`). Two events are new: `.reconnectError` with the reason of a failed attempt (JS `reconnect_error`) and `.reconnectFailed` with no payload when the budget is exhausted (JS `reconnect_failed`). The Swift-only `.disconnect("Reconnect Failed")` is gone. A transport drop that will be retried now reports `.disconnect` with the real reason and clears `sid`, exactly as JS `Socket.onclose` does, while the socket stays `active` so its namespace is re-joined. Swift has no manager-level event bus, so these manager events are emitted on every socket of the manager. Ported from `socket.io-client/test/connection.ts` "should fire reconnect_* events on manager", "should fire reconnecting (on manager) with attempts number when reconnecting twice", "should reconnect by default", "should attempt reconnects after a failed reconnect" and "should not try to reconnect and should form a connection when connecting to correct port with default timeout".
- **An emit whose payload cannot be represented as JSON now fails instead of sending a different packet.** `SocketPacket.completeMessage` used to fall back to an empty payload (`2[]`) when `JSONSerialization` refused the data, turning the caller's operation into a different wire packet. Encoding now runs before anything is buffered, queued or written and throws a typed `SocketPacketError` (`unsupportedValue`, `nonStringKey`, `nestingTooDeep`, `unserializablePayload`): the `.error` client event carries it, modern error-first and async acknowledgements settle exactly once with it (legacy `OnAckCallback` retains its no-ack contract), and no packet leaves. `SocketPacket.encodedPacketString()` is the throwing encoder; `packetString` keeps its signature for code that builds packets by hand. JS `JSON.stringify` behaves the same way — it either produces the value or throws.
- **`Date` is a `SocketData` and encodes as the string JS produces.** `Date.prototype.toJSON()` is `toISOString()`, so a `Date` in an emit — at the top level or nested in dictionaries and arrays — is written as `"2024-01-02T03:04:05.678Z"` (UTC, three fractional digits). Ported from `connection.ts` "should emit date as string", "should emit date in object" and "should receive date with ack". Years outside 0000–9999, which JS writes in its expanded `±YYYYYY` form, are not reproduced.
- **Non-finite numbers encode as `null`**, as `JSON.stringify(NaN)` and `JSON.stringify(Infinity)` do. `JSONSerialization` rejects them outright, so they used to make the whole payload unencodable.
- **`Data` emitted through `rawEmitView` is now an error.** That view deliberately does not shred binary into attachments, so `Data` has no wire form there; it used to be silently replaced by an empty payload.
- **A query string in the server URL is now used.** `SocketEngine` rebuilt its transport URLs from scratch and discarded whatever query the `socketURL` carried, so `SocketManager(socketURL: URL(string: "https://example.com/?token=abc")!)` never sent `token`. The URL's parameters are now the connection query, unless `.connectParams` is set — JS `socket.io-client/lib/index.ts` does `if (parsed.query && !opts.query) opts.query = parsed.queryKey`, i.e. an explicit query replaces rather than merges. Percent-encoded parameters are passed through verbatim. Ported from `socket.ts` "query option" (all four titles).
- **JSON object keys are written in sorted order.** A Swift `Dictionary` has no insertion order for the encoder to preserve, so the choice was between an arbitrary order and a reproducible one; JSON object order carries no meaning. Binary attachments are numbered in that same sorted traversal, so the same payload always produces the same wire bytes.
- **A pending acknowledgement is settled by a transport drop that reconnects**, where it used to survive untouched. An error-first callback and an `async emitWithAck` now receive `SocketAckError.disconnected` at the close instead of staying pending across the reconnect. See the matching entry under *Fixes* for the full `_clearAcks` rules.

## Fixes

- **Acknowledgements are now cleared on every close, not only the terminal one.** JS `Socket.onclose` ends with `_clearAcks()` and runs on every close, including one the manager will retry; Swift ran that cleanup only from the terminal `didDisconnect`, so a transport drop that reconnects left the registry untouched. An acknowledgement owned by the swallowed session could survive the reconnect and later match an id the new session re-issued, or fire a late timeout against it. The retried-drop path (`setReconnecting(reason:)`) now applies the same `_clearAcks` rules: an acknowledgement whose packet is still in the send buffer is kept (that packet goes out on the next CONNECT), a `withError` registration settles with the disconnect error, a plain callback is dropped silently, the async `emitWithAck` continuation is resumed with `.disconnected`, and the retry queue's per-attempt acknowledgement is retired without dropping the head — it keeps its place and its retry budget and is re-sent under a fresh id, unless `tryCount > retries`, in which case JS discards it and settles the user's acknowledgement. Connection-state recovery is untouched: `_pid`/`_lastOffset` survive the close, as in JS. Ported from `socket.io-client/test/socket.ts` "should ack with an error upon disconnection (callback & timeout / callback & ackTimeout / promise)", "should not discard an unsent ack (callback)", the "throttled timer" buffering scenario and the `retry.ts` retried-head cases (`SocketClearAcksOnCloseTest`, `JSParityE2ETest.testPendingAckFailsWhenTheTransportIsKilledAndTheSocketReconnects`).
- **Two data races that Thread Sanitizer would report are fixed** (review gate R5). `SocketAckManager`'s storage is now lock-guarded: the timed-ack APIs are documented as `handleQueue`-only, but `SocketIOClient.clearRecoveryState()` snapshots `pendingTimedAckIDs` from the caller's thread and the legacy `emitWithAck` chain registers through `addAck`, so the underlying `Set`/`Dictionary` could be mutated concurrently with a `handleQueue` write — memory-unsafe, not merely mis-ordered. Callbacks are still invoked after the lock is released, so the documented re-entrancy of `cancelTimedAck(_:fireWith:)` cannot deadlock, and no ordering changed. The acknowledgement id allocator was incremented from `handleQueue` by `allocateAckId()` and from the caller's thread by `createOnAck`, so two registrations could receive the same id; `createOnAck` now goes through the lock-guarded allocator.
- Reject cyclic Foundation arrays/dictionaries before recursive bridging or logging, with `SocketPacketError.cyclicPayload`. Shared acyclic containers remain supported. Outgoing normalization now enforces depth 512, 1,000,000 nodes including keys/repeated occurrences, and a conservative 64 MiB escaped-JSON plus binary budget (including 64 bytes per attachment placeholder). These per-encoding bounds are deliberate JS deviations, not queue or process-memory caps. The earlier Round 2 typed-error guarantee did not cover cyclic Foundation containers; this follow-up adds that protection. Review gate R2 remains open for full encoder parity and release validation.
- Restore explicit manager namespace removal while retaining the JavaScript-compatible client socket cache for manual reconnect and active timeout subscriptions. Retire polling sessions on successful WebSocket handoff without invalidating the engine, and synchronize acknowledgement/polling teardown regressions using registration and injected deadlines.

- **The WebSocket upgrade no longer sends a client NOOP packet.** After the `3probe` reply the engine enqueued an Engine.IO NOOP (`6`) "over polling"; because POSTs are already blocked at that point it stayed in the send queue and was flushed over the WebSocket right after the upgrade packet, so the server saw `5` then `6`. engine.io-client never sends a NOOP (the server sends one over the pending polling GET to release it). Node's engine.io ignores the stray packet, but `@socket.io/bun-engine` treats any packet other than pong/message as a parse error and closes the connection, which made every upgrade against a Bun-backed server fail right after "Switching to WebSockets" and reconnect in a loop. Found on a device against a Bun server; the polling test double had masked the packet. Ported checks: exactly `2probe`, `5`, then buffered data over the new transport, and an upgrade with no polling request outstanding completes immediately.
- A graceful polling disconnect now flushes the packets still queued before sending the close packet, instead of discarding them. JS `close()` waits for `drain` — every buffered packet flushed, sliced by `maxPayload` — before the transport is told to close, and `socket.disconnect()` puts the namespace DISCONNECT frame into that very buffer, so the old behavior silently dropped it. The retiring session POSTs the queue in `maxPayload`-sized batches, one request at a time (Engine.IO permits only one POST per session), then the close packet as a request of its own; each packet's write completion fires when its batch reaches the wire. An in-flight POST is still awaited first and bounded by the one-second teardown deadline, and every request the retiring session starts itself is bounded individually from the moment it goes out — so a slow earlier POST can no longer cancel the close that follows it. Shutdown remains isolated from replacement sessions.
- A close issued while the transport is paused for a WebSocket upgrade is now deferred until the upgrade settles, JS-aligned with `waitForUpgrade()` in `engine.io-client/lib/socket.ts`. Nothing can be written through a paused transport, so the close waits for `upgrade` (then the buffer and the close go out over the WebSocket) or `upgradeError` (then over polling), bounded by the existing probe timeout. While a close is pending, a new `send()` produces no packet, as JS `sendPacket` returns early once `readyState` is `closing`. Ported from `engine.io-client/test/connection.js` — "should defer close when upgrading", "should close on upgradeError if closing is deferred", "should not send packets if closing is deferred", "should send all buffered packets if closing is deferred" and "should not send packets if socket closes".
- Payload-less EVENT and ACK packets (`2`, `2/nsp,`, `2123`, `3`, `399`) are no longer a fatal parse error. JS `Decoder.decodeString` only parses a payload `if (str.charAt(++i))` and returns a packet with `data === undefined`; `onevent` then emits nothing (only any-listeners see the empty event) and `onack` logs "bad ack". Binary headers still require a payload, since their placeholders cannot exist without one. Everything socket.io-parser's own "throw an error upon parsing error" rejects stays rejected.
- An acknowledgement id too large for `Int` no longer kills the connection. JS parses ids with `Number(...)`, which yields a float no handler can match, so the EVENT is delivered without an acknowledgement and an ACK is dropped; Swift now keeps the packet with the no-ack sentinel instead of throwing.
- `SocketParserOptions` no longer imposes limits JS does not have. `maximumAttachments` keeps the JS default of 10; `maximumTextPacketBytes` and `maximumBinaryPacketBytes` now default to unlimited and are opt-in hardening. `maximumNestingDepth` stays enabled (default 512, hard cap 1024) as a deliberate deviation: `JSONSerialization` can overflow the stack on deeply nested input. See the "Deliberate deviations" section of `PARITY.md`.
- Handshake heartbeat timers are accepted as JS accepts them: `pingInterval: 0` with a real `pingTimeout` opens the socket, fractional milliseconds are floored to whole milliseconds, and zero or absent timers open the socket and then close it from the heartbeat with `ping timeout`. Only values that cannot become a Dispatch deadline — negative, non-numeric, or an interval+timeout sum past 2³¹−1 — remain a transport error.
- An Engine.IO packet with an unknown type prefix now closes the engine with `transport error` instead of only reporting `.error`. engine.io-parser decodes it into an `error` packet, which `_onPacket` routes through `_onError` → `_onClose("transport error")`. A JSON body that names no error (`{}`) closes as well, matching engine.io-parser's "should fail to decode a malformed payload".
- `stopPolling()` now marks the session invalidated and detaches it, with a fresh POST barrier. It used to invalidate the `URLSession` while leaving it in place, so a later `doPoll()` would hand an invalidated session to `dataTask` — an Objective-C exception on Darwin.
- An invalid `parserOptions` value in a dictionary configuration now reports `invalid value for parserOptions; expected SocketParserOptions` instead of the unrelated legacy-TLS migration message.
- `emit(_:with:ack:)` without an `ackTimeout` no longer drops the callback when the manager has been released: it fires `SocketAckError.disconnected`, like `emitTimed` already did.
- Audit of published CodeRabbit findings across PRs #1–#17: strengthen server-ID, active-cache and reconnect tests; prevent overlapping timeout polls in the maxPayload wire proof; correct timeout/cache-buster/disconnect documentation.
- The `.disconnect` payload now carries the JS reason strings (`io server disconnect`, `io client disconnect`, `transport close`, `transport error`, `ping timeout`, `parse error`), JS-aligned with `socket.on("disconnect", reason => ...)` in `socket.io-client/lib/socket.ts` and engine.io-client's `onclose`. Previously the client surfaced ad-hoc strings (`Got Disconnect`, `Namespace leave`, `Disconnect`, `Manager Deinit`, engine error texts, `Ping timeout` with a capital P, or the raw engine.io close frame). A failed transport now reports `transport error` while the detailed error text stays in the `.error`/`.connectError` payload, and a clean close reports `transport close` regardless of the close-frame reason. One Swift-specific reason is kept deliberately: `"timeout"` (connect-timeout close; JS surfaces `connect_error` only). The Swift-only `"Reconnect Failed"` reason was removed in 17.0.0 in favour of the JS `reconnect_failed` event — see the breaking changes above.
- An undecodable packet now closes the engine with reason "parse error" (sockets get `.disconnect("parse error")`, reconnection starts if enabled) instead of being dropped silently; JS-aligned with `Manager.ondata`/`onclose` in `socket.io-client/lib/manager.ts`. Found by porting the JS client's own scenario "should close the engine upon decoding exception".
- By default every long-polling request (handshake GET, polls, POSTs) now carries a unique `t=` cache-busting query parameter (`.timestampRequests(false)` disables it), JS-aligned with `Polling.uri()` in engine.io-client; the WebSocket URL carries it only when explicitly enabled. New options `.timestampRequests(Bool)` / `.timestampParam(String)` with JS defaults (polling stamped, WebSocket not; param name `"t"`). Previously the client relied on `URLRequest.cachePolicy = .reloadIgnoringLocalCacheData`, which only bypasses the local cache — proxies, CDNs, and corporate caches in between could still serve a stale response to a long-poll.
- A CONNECT packet without a `sid` on a `.three` manager now fires `.connectError` with the JS message about reaching a Socket.IO server in v2.x instead of connecting, JS-aligned with `onpacket` in `socket.io-client/lib/socket.ts`; `.two` managers are unaffected since the v2 protocol carries no sid. Found by porting the JS client's own scenario "should emit a connect_error event when reaching a Socket.IO server in v2.x".
- A namespace the server refused (CONNECT_ERROR) is no longer rejoined on the next engine open. `SocketManager` re-sent CONNECT for any socket still in `.connecting`, so a server rejecting an expired token was asked again on every reconnect, indefinitely. The rejoin now requires `socket.active`, which is what that flag was introduced for. JS `destroy()`s the socket on CONNECT_ERROR and waits for an explicit `connect()`. Found by porting the JS client's own `should not try to reconnect after a middleware failure`.
- Emits made while disconnected are no longer lost: they are buffered and flushed in order on the next CONNECT, with the outgoing any-listeners firing at flush time as they do in JS `emitBuffered()`. Acks behave as in JS `_clearAcks`: an ack whose packet is still buffered survives the disconnect, while a timed-out ack drops its packet from the buffer so a reconnect does not deliver an emit the caller already gave up on. The legacy `emitWithAck(...).timingOut(after:)` path keeps its documented behavior. `clearRecoveryState()` discards the buffer instead of keeping it: that is the identity-swap path, where delivering the previous user's queued events into the successor session would leak them across identities.
- The polling transport is paused before the WebSocket upgrade. Previously only the outstanding long-poll was awaited; a POST still on the wire reached the server after it had switched transports, which answers it with HTTP 400 and drops the packet without surfacing an error. JS-aligned with `pause()` in engine.io-client's polling transport.
- Polling POSTs now respect the `maxPayload` the server advertises in the handshake. Previously the whole queue went out in one request; above the limit the server answers HTTP 413 and discards every packet it carried, while the session stays open. The batch is now cut at the limit and the rest follows in the next POST, JS-aligned with `getWritablePackets()` in engine.io-client. A single packet larger than the limit is still sent on its own, as in the reference client. engine.io v3 is unaffected — those servers advertise no limit.
- New `SocketEnginePollable.maxPayload: Int?` — additive protocol requirement with a `nil` default, so existing conformers keep the previous unbounded behavior.
- With `.autoConnect(true)`, `socket(forNamespace:)` now re-connects a cached socket that is no longer active, JS-aligned with `Manager.socket()`; without `autoConnect` nothing changes.
- After the reconnect budget is exhausted, a later `connect()` starts a fresh reconnection cycle with a fresh budget (previously the manager stayed flagged as reconnecting forever). JS-aligned with `Manager.reconnect()`; found via the JS scenario "should attempt reconnects after a failed reconnect".
- The engine now ignores responses and packets that belong to a previous session and reports its close only once; previously a handshake completing after a timeout-close re-opened the reused engine with a stale sid, so the manager saw two "opened" sessions and started a spurious reconnect cycle (JS-aligned: engine.io-client uses a fresh transport per attempt). Found via the JS scenario "should attempt reconnects after a failed reconnect".

## Features

- **New `.bufferLimits(SocketBufferLimits)` option — one resource policy for every queue this client retains data in** (review gate R1). **Every limit is off by default**, which keeps the default behaviour JavaScript-equal: JS `sendBuffer` and `_queue` are unbounded too. Setting one opts into a hard bound with an explicit, never-silent failure. It is the pipeline-wide layer of three: `.parserOptions` bounds one incoming packet, `.webSocketOptions` bounds one native WebSocket message and the native send queue, and `.bufferLimits` bounds everything that accumulates across packets — `SocketIOClient.sendBuffer` (packets and bytes), the `.retries` queue (packets and bytes), the connection-state-recovery replay buffer (packets and bytes), the engine-to-manager handoff (packets and bytes, with the receive permit released *after parsing*, not after dispatch), one incoming long-polling HTTP body, and how long a half-reconstructed binary packet may stay outstanding. Overflow on an **outgoing** buffer fails the *new* emit locally — its write completion runs once, its acknowledgement settles once with a typed `SocketBufferLimitError`, the `.error` client event carries the same error, and nothing already accepted is evicted. Overflow on an **incoming** buffer closes the connection with `"transport error"` (engine.io-client's `_onError` → `_onClose`), except an expired binary reconstruction, which is a decoder failure and closes with `"parse error"`; nothing is replayed from a partial packet. With a polling body cap configured, the body is bounded *while it is received*: an announced `Content-Length` above the cap is refused before a byte of body arrives and a chunked body is cancelled mid-transfer (`SocketSessionDelegateProxy` is now a `URLSessionDataDelegate`); without a cap the transport keeps the previous completion-handler request form unchanged. An invalid limit is rejected before connecting. See `SocketBufferLimitsTest`, `SocketPollingBodyLimitTest` and section 9.2 of the parity review.
- New `.retries(Int)` option / `SocketManager.retries` (default `0`, disabled), JS-aligned with the `retries` option in `socket.io-client/lib/socket.ts`. With it set, every event emit goes through an ordered retry queue: only the head packet is in flight, each attempt waits `ackTimeout` (or the per-emit `timeout(after:)`) for the ack and is resent on failure until `retries` is exhausted (`retries + 1` sends total), then the ack callback fires with `SocketAckError.timeout`. The queue survives a disconnect, does not drain while disconnected, and drains on the next CONNECT before the `connect` event fires, so an emit made inside a connect handler is never sent twice. Each attempt carries a fresh ack id. The legacy `emitWithAck(...).timingOut(after:)` chain and the async `timeout(after:).emit` overload do not participate in retries.
- New `.ackTimeout(Double)` option / `SocketManager.ackTimeout` (seconds, default `nil`) plus new `SocketIOClient.emit(_:_:ack:)` / `emit(_:with:ack:)` overloads with err-first callbacks, JS-aligned with `_registerAckCallback` in `socket.io-client/lib/socket.ts`. When the default is set, the emit behaves exactly like `timeout(after: ackTimeout).emit(...)`: the callback fires with `SocketAckError.timeout` when the timer fires (and the packet is dropped from the send buffer) and with `SocketAckError.disconnected` on disconnect unless the packet is still buffered. When unset, the callback is a plain ack registered with no timer — it fires as `ack(nil, data)` on the server ack and is never called with an error, not on disconnect either.
- New `.connectTimeout(Double)` / `SocketManager.connectTimeout` (default 20 s, `.infinity` disables), JS-aligned with `Manager.open()` in `socket.io-client/lib/manager.ts`. If the engine.io handshake has not completed in time, every socket gets `.connectError` with `"timeout"`, the engine is closed, and the reconnect loop starts if enabled.
- New `SocketClientEvent.connectError` (fires as `"connect_error"`), JS-aligned with `connect_error` in `socket.io-client/lib/socket.ts`. It replaces `.error` for connection/join failures: a server CONNECT_ERROR refusal, a v2.x server detected on a `.three` manager, an engine/transport error while the socket is not connected (an error under an established connection keeps firing `.error`), and the connection timeout. Payload-serialization and v2-auth-bypass reports keep firing `.error` — those are client-side failures, not connection refusals.
- Connection State Recovery support for `.version(.three)` managers talking to Socket.IO 4.x servers with `connectionStateRecovery` enabled. `SocketIOClient` exposes `recovered: Bool` and the `.connect` event payload carries a `"recovered": Bool` key. After an abrupt transport drop, the client can resume the prior session when the server still has recovery state available.
- New `SocketIOClient.clearRecoveryState()` method. Call it before reconnecting on an identity change to prevent resuming a prior user's session.
- New `SocketIOClientOption.autoConnect(Bool)`. When `true`, `SocketManager.init` calls `defaultSocket.connect()` and opens the engine before returning, so the default namespace socket is auto-joined. Default `false` preserves existing behavior. JS `Manager` defaults to `true`; Swift inverts to avoid silently changing legacy callers. Only the `defaultSocket` is auto-CONNECTed; non-default namespaces created via `manager.socket(forNamespace:)` still require explicit `socket.connect()`. Engine I/O begins synchronously inside `init`, matching JS.
- Reserved event names (`connect`, `connect_error`, `disconnect`, `disconnecting`) emitted by user code are now intercepted at the internal emit funnel: a `.error` client-event fires and the packet is dropped before it reaches the wire. JS-aligned with `socket.io-client/lib/socket.ts` `emit()` throw — Swift surfaces via `.error` because the emit signature cannot throw without breaking back-compat. DEBUG builds (outside XCTest) additionally trigger `assertionFailure` so misuse surfaces loudly during development. `SocketRawView.emit` is also covered.
- New `SocketIOClient.active: Bool` lifecycle property. Mirrors JS `socket.active` (`!!this.subs`): flipped `true` at the start of `connect()` and `false` only inside the user-facing `disconnect()`. Survives engine-close + reconnect cycles (`didDisconnect(reason:)` does not clear it). Distinct from `socket.status.active` which reports the current status enum's liveness.
- `SocketIOClient.addAnyListener(_:)` / `prependAnyListener(_:)` / `removeAnyListener(id:)` / `removeAllAnyListeners()` / `anyListenerCount` — multi-listener catch-all family matching JS `socket.onAny` API. Returns `UUID` handle for removal (closures lack identity in Swift). Listeners fire in registration order after the legacy single-handler `onAny(_:)`. Mutators serialize via `handleQueue.async`; dispatch iterates a snapshot so self-removal mid-dispatch is safe.
- `SocketIOClient.addAnyOutgoingListener(_:)` / `prependAnyOutgoingListener(_:)` / `removeAnyOutgoingListener(id:)` / `removeAllAnyOutgoingListeners()` / `anyOutgoingListenerCount` — outgoing-side catch-all listener family matching JS `socket.onAnyOutgoing`. Fires only on actual `engine.send` (after the connected-state guard); ack response frames bypass; disconnected emits do NOT fire (JS-aligned per `socket.io-client/lib/socket.ts` `emit()` body). Mutators serialize via `handleQueue.async`.
- `SocketIOClient.send(_:completion:)` / `send(with:completion:)` / `sendWithAck(_:)` / `sendWithAck(with:)` — JS-aligned shortcuts for `emit("message", ...)` / `emitWithAck("message", ...)`. Server-side reception via existing `socket.on("message", ...)`. The legacy `OnAckCallback.timingOut` chain on `sendWithAck` still uses the magic-string `SocketAckStatus.noAck` for timeouts and is NOT cleared on disconnect — Phase 9's `socket.timeout(after:).emit(...)` provides typed errors and disconnect-clearing.
- `SocketIOClient.volatile.emit(...)` chain. Drops packet if `engine.writable == false`; no `.error`, no outgoing-listener fire, no buffering. JS-aligned per `socket.io-client/lib/socket.ts` `emit()` body which gates `discardPacket = volatile && !transport.writable`. No volatile-with-ack overload (JS allows it but the callback orphans on drop — Swift omits the API).
- `SocketEngineSpec.writable: Bool { get }` — additive protocol requirement with fail-safe `false` default. Concrete `SocketEngine.writable` returns `true` when connected and (WebSocket-mode with active ws) OR (polling-mode with no in-flight POST).
- `SocketIOClient.setAuth(_:)` — install a callback-form auth provider invoked on `handleQueue` for every CONNECT (initial + reconnect). JS-aligned with `socket.io-client/lib/socket.ts onopen()`. Multi-callback sends multiple CONNECT packets (parity with JS).
- `SocketIOClient.setAuth(_:)` async/throws overload. On throw, fires `.error` clientEvent with the localized error description; CONNECT is not sent (fail-closed). Stale results from a generation-mismatched provider are silently dropped.
- `SocketIOClient.clearAuth()` — removes the installed provider and cancels any in-flight async resolution Task.
- v2 manager guard: installing a provider on a `.version(.two)` manager fires `.error` per CONNECT attempt with a clear bypass message; the provider is never invoked on v2 (where the underlying connect path drops payloads).
- `SocketIOClient.timeout(after:) -> SocketTimedEmitter` — per-emit ack with typed `SocketAckError.timeout` / `.disconnected` (err-first callback `(Error?, [Any]) -> Void`). JS-aligned with `socket.io-client` `socket.timeout(N).emit(...)`. Atomic one-shot fire across timer / server-ack / cancel paths.
- Async/throws overload of `SocketTimedEmitter.emit(...)` with `Task.cancel()` support — cancellation surfaces as `CancellationError` thrown from the await.
- `SocketAckManager` parallel `timedAcks` storage and 4 internal APIs (`addTimedAck` / `executeTimedAck` / `cancelTimedAck(fireWith:)` / `clearTimedAcks(reason:)`). Legacy `acks` storage and `emitWithAck.timingOut(after:)` path are untouched.
- `SocketIOClient.didDisconnect` clears `timedAcks` with `.disconnected` (matches JS `_clearAcks` for `withError` callbacks).
- Async `SocketIOClient.emitWithAck(_:_:)` / `emitWithAck(_:with:)` and `SocketTimedEmitter.emitWithAck(_:_:)`, JS-aligned with `socket.emitWithAck(ev, ...args)` and `socket.timeout(ms).emitWithAck(ev, ...args)`. The bare form is bounded by `SocketManager.ackTimeout` when one is configured (JS `flags.timeout ?? _opts.ackTimeout`); without one, a disconnect throws `SocketAckError.disconnected` rather than leaving the call pending forever, because a Swift continuation has to be resumed exactly once. Ported from `socket.ts` "should emit an event and wait for the acknowledgement" and "should not timeout when the server does acknowledge the event (promise)".
- `SocketPacket.encodedPacketString() throws` and `SocketPacketError`, plus `SocketPacket.jsonSafeEmitData(_:allowBinary:)` and `SocketPacket.iso8601String(from:)` for callers that need the JS `JSON.stringify` rules directly.
- The decoder differential (`scripts/test-parser-parity.sh`) now runs in both directions. In addition to the 5,000 seeded decode vectors, 1,000 seeded packets — text and binary, every packet type, Unicode namespaces, with and without ack ids — are encoded by this client and read back by the pinned upstream JavaScript decoder, and the result must equal the source packet. The run reports `encodeCases`/`encodeDifferences` and fails on any difference; the decode direction and its recorded malformed-input contract are unchanged.

## Breaking

- An engine handshake that never completes now fails after 20 s (`.connectError` with `"timeout"`, engine closed, reconnect loop starts if enabled) instead of waiting indefinitely; set `.connectTimeout(.infinity)` to restore the old behaviour.
- An `emit` made while the socket is not connected is now **buffered and sent on the next CONNECT** instead of being dropped with a `Tried emitting when not connected` `.error`. JS-aligned with `sendBuffer` in `socket.io-client/lib/socket.ts` (`emit()` / `emitBuffered()`). Callers that treated that `.error` as "this event is lost, handle it yourself" will no longer see it, and the event will arrive after the reconnect. Like JS, the buffer has no upper bound. Ack *responses* (`emitAck`) are unaffected and still report the error.

## Breaking (.three managers only)

- `SocketManager.connectSocket` now emits `.error` and aborts when the caller's `connectPayload` cannot be JSON-encoded. Previously the connect was sent with an empty payload, silently dropping user auth. Callers must supply a JSON-serializable dict. No change for v2 managers.

## Divergences from socket.io-client JS 4.8.x (documented)

- `_lastOffset` is capped at 256 UTF-8 bytes (D1).
- Payload JSON failure is surfaced as `.error` (D2).
- `clearRecoveryState()` is a new API (D3).
- `setAuth(_:)` async/throws overload + v2 `.error` channel + generation-token stale-result discard are Swift additions (D4).
- `SocketTimedEmitter.cancelTimedAck(_:fireWith:)` surfaces `Task.cancel()` as the user-callback's err parameter (so the one-shot guarantee lives in the `fired` flag, not in continuation racing). Pure Swift addition (D5).
- Legacy `emitWithAck(...).timingOut(after:)` is NOT cleared on disconnect — only the new `timeout(after:).emit` path is. Preserved for backwards compatibility.

# v16.1.0

- Remove support for iOS 11.
- Update to Starscream 4.0.6

# v16.0.0

- Removed Objective-C support. It's time for you to embrace Swift.
- Socket.io 3 support.

# v15.3.0

- Add `==` operators for `SocketAckStatus` and `String`

# v15.2.0

- Small fixes.

# v15.1.0

- Add ability to enable websockets SOCKS proxy.
- Fix emit completion callback not firing on websockets [#1178](https://github.com/socketio/socket.io-client-swift/issues/1178)

# v15.0.0

- Swift 5

# v14.0.0

- Minimum version of the client is now Swift 4.2.
- Add exponential backoff for reconnects, with `reconnectWaitMax` and `randomizationFactor` options [#1149](https://github.com/socketio/socket.io-client-swift/pull/1149)
- `statusChange` event's data format adds a second value, the raw value of the status. This is for use in Objective-C. [#1147](https://github.com/socketio/socket.io-client-swift/issues/1147)

# v13.4.0

- Add emits with write completion handlers. [#1096](https://github.com/socketio/socket.io-client-swift/issues/1096)
- Add ability to listen for when a websocket upgrade happens

# v13.3.1

- Fixes various bugs. [#857](https://github.com/socketio/socket.io-client-swift/issues/857), [#1078](https://github.com/socketio/socket.io-client-swift/issues/1078)

# v13.3.0

- Copy cookies from polling to WebSockets ([#1057](https://github.com/socketio/socket.io-client-swift/issues/1057), [#1058](https://github.com/socketio/socket.io-client-swift/issues/1058))

# v13.2.1

- Fix packets getting lost when WebSocket upgrade fails. [#1033](https://github.com/socketio/socket.io-client-swift/issues/1033)
- Fix bad unit tests. [#794](https://github.com/socketio/socket.io-client-swift/issues/794)

# v13.2.0

- Add ability to bypass Data inspection in emits. [#992]((https://github.com/socketio/socket.io-client-swift/issues/992))
- Allow `SocketEngine` to be subclassed

# v13.1.3

- Fix setting reconnectAttempts [#989]((https://github.com/socketio/socket.io-client-swift/issues/989))


# v13.1.2

- Fix [#950](https://github.com/socketio/socket.io-client-swift/issues/950)
- Conforming to `SocketEngineWebsocket` no longer requires conforming to `WebsocketDelegate`


# v13.1.1

- Fix [#923](https://github.com/socketio/socket.io-client-swift/issues/923)
- Fix [#894](https://github.com/socketio/socket.io-client-swift/issues/894)

# v13.1.0

- Allow setting `SocketEngineSpec.extraHeaders` after init.
- Deprecate `SocketEngineSpec.websocket` in favor of just using the `SocketEngineSpec.polling` property.
- Enable bitcode for most platforms.
- Fix [#882](https://github.com/socketio/socket.io-client-swift/issues/882). This adds a new method
`SocketManger.removeSocket(_:)` that should be called if when you no longer wish to use a socket again.
This will cause the engine to no longer keep a strong reference to the socket and no longer track it.

# v13.0.1

- Fix not setting handleQueue on `SocketManager`

# v13.0.0

Checkout out the migration guide in Usage Docs for a more detailed guide on how to migrate to this version.

What's new:
---

- Adds a new `SocketManager` class that multiplexes multiple namespaces through a single engine.
- Adds `.sentPing` and `.gotPong` client events for tracking ping/pongs.
- watchOS support.

Important API changes
---

- Many properties that were previously on `SocketIOClient` have been moved to the `SocketManager`.
- `SocketIOClientOption.nsp` has been removed. Use `SocketManager.socket(forNamespace:)` to create/get a socket attached to a specific namespace.
- Adds `.sentPing` and `.gotPong` client events for tracking ping/pongs.
- Makes the framework a single target.
- Updates Starscream to 3.0
