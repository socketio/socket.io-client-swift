import XCTest
@testable import SocketIO

/// Unit tests for the Phase 8 `setAuth` / `clearAuth` / `resolveConnectPayload`
/// surface on `SocketIOClient`.
///
/// All tests use a dedicated background `handleQueue` because
/// `manager.handleQueue.sync { }` from the main thread would deadlock if the
/// queue were `.main`. The internal `resolveConnectPayload` requires the caller
/// to be on `handleQueue`, so tests dispatch onto it explicitly.
final class SocketAuthProviderTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.auth.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    /// Drain pending work on the handle queue so that async-dispatched mutations
    /// (e.g. `setAuth`'s install hop, `clearAuth`'s tear-down hop) are visible
    /// before the test asserts.
    private func drain() {
        queue.sync { }
    }

    // MARK: U-A1 — provider stored at install but NOT invoked until resolution

    func testProviderStoredButNotInvokedUntilConnect() {
        var invoked = 0
        socket.setAuth { cb in
            invoked += 1
            cb(["token": "abc"])
        }
        drain()

        XCTAssertEqual(invoked, 0,
                       "setAuth must only store the provider; resolution happens on CONNECT")

        // Now drive a single resolution: provider must run exactly once.
        let resolved = expectation(description: "resolution completed")
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { _ in
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(invoked, 1, "exactly one resolution should invoke the provider once")
    }

    // MARK: U-A2 — no provider → completion gets explicit verbatim

    func testResolveConnectPayloadWithoutProviderReturnsExplicit() {
        let resolved = expectation(description: "explicit returned verbatim")
        var captured: [String: Any]?
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: ["x": 1]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(captured?["x"] as? Int, 1)
    }

    // MARK: U-A3 — provider's resolved dict overrides explicit

    func testResolveConnectPayloadWithProviderOverridesExplicit() {
        socket.setAuth { cb in cb(["a": 1]) }
        drain()

        let resolved = expectation(description: "provider value wins")
        var captured: [String: Any]?
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: ["b": 2]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(captured?["a"] as? Int, 1, "provider value must win")
        XCTAssertNil(captured?["b"], "explicit must be discarded when provider returns non-nil")
    }

    // MARK: U-A4 — provider returning nil falls back to explicit (`resolved ?? explicit`)

    func testResolveConnectPayloadWithProviderReturningNilFallsBackToExplicit() {
        socket.setAuth { cb in cb(nil) }
        drain()

        let resolved = expectation(description: "fallback to explicit")
        var captured: [String: Any]?
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: ["x": 1]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(captured?["x"] as? Int, 1,
                       "provider returning nil should fall through to explicit per `resolved ?? explicit`")
    }

    // MARK: U-A5 — clearAuth removes installed provider

    func testClearAuthRemovesProvider() {
        var invoked = 0
        socket.setAuth { cb in
            invoked += 1
            cb(["token": "abc"])
        }
        drain()
        socket.clearAuth()
        drain()

        let resolved = expectation(description: "explicit returned after clearAuth")
        var captured: [String: Any]?
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: ["x": 1]) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)

        XCTAssertEqual(invoked, 0, "cleared provider must never be invoked")
        XCTAssertEqual(captured?["x"] as? Int, 1, "after clearAuth, explicit is returned verbatim")
    }

    // MARK: U-A6 — multi-callback provider invokes completion twice (JS parity)

    func testMultiCallbackProviderInvokesCompletionTwice() {
        // Provider that calls cb twice mirrors socket.io-client/lib/socket.ts
        // multi-callback semantics: each cb invocation produces a CONNECT.
        socket.setAuth { cb in
            cb(["a": 1])
            cb(["b": 2])
        }
        drain()

        let twice = expectation(description: "completion fires twice")
        twice.expectedFulfillmentCount = 2
        var captures = [[String: Any]]()
        let lock = NSLock()
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                lock.lock()
                if let p = payload { captures.append(p) }
                lock.unlock()
                twice.fulfill()
            }
        }
        wait(for: [twice], timeout: 2)

        XCTAssertEqual(captures.count, 2, "completion must be invoked once per provider callback")
        let firstA = captures.first?["a"] as? Int
        let secondB = captures.last?["b"] as? Int
        XCTAssertEqual(firstA, 1)
        XCTAssertEqual(secondB, 2)
    }


    // MARK: U-A8 — async provider stale result discarded after clearAuth + new provider install

    func testAsyncProviderStaleResultDiscardedAfterClearAuth() {
        // Provider 1 sleeps 200ms then returns ["old": true]. We immediately
        // clearAuth + install a fresh sync provider returning ["new": true].
        // The contract: the late ["old": true] result must NEVER reach completion
        // because clearAuth bumps `authGeneration`, and the async overload
        // discards any result whose captured generation no longer matches.
        socket.setAuth {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return ["old": true]
        }
        drain()

        // Trigger first resolution while status is .connecting (the async
        // overload also requires status == .connecting on the result hop).
        socket.setTestStatus(.connecting)

        let firstScheduled = expectation(description: "first resolution scheduled")
        let lock = NSLock()
        var observed = [[String: Any]?]()

        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                lock.lock()
                observed.append(payload)
                lock.unlock()
            }
            firstScheduled.fulfill()
        }
        wait(for: [firstScheduled], timeout: 1)

        // Immediately swap identity. clearAuth bumps the generation token; the
        // in-flight async Task's result hop will then be dropped.
        socket.clearAuth()
        socket.setAuth { cb in cb(["new": true]) }
        drain()

        // Trigger a second resolution that should run the new sync provider
        // and complete immediately.
        let secondCompleted = expectation(description: "fresh provider produced new value")
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                lock.lock()
                observed.append(payload)
                lock.unlock()
                if (payload?["new"] as? Bool) == true {
                    secondCompleted.fulfill()
                }
            }
        }
        wait(for: [secondCompleted], timeout: 1)

        // Give the stale Task ample time (>>200ms sleep + hop) to attempt
        // its forbidden completion.
        Thread.sleep(forTimeInterval: 0.6)

        lock.lock()
        let snapshot = observed
        lock.unlock()

        for entry in snapshot {
            if let dict = entry, dict["old"] as? Bool == true {
                XCTFail("stale async result leaked through completion: \(dict)")
            }
        }
        let sawNew = snapshot.contains { ($0?["new"] as? Bool) == true }
        XCTAssertTrue(sawNew, "fresh provider must produce ['new': true] in observed results")
    }

    func testAsyncProviderSuccessWritesResolvedConnectPayload() {
        let engine = MockEngine()
        manager.engine = engine
        let written = expectation(description: "async auth writes CONNECT")
        engine.onWrite = { message, attachments in
            XCTAssertEqual(message, "0/,{\"token\":\"async-token\"}")
            XCTAssertTrue(attachments.isEmpty)
            written.fulfill()
        }
        socket.setAuth { () async throws -> [String: Any]? in ["token": "async-token"] }
        drain()
        queue.sync {
            manager.setTestStatus(.connected)
            socket.connect()
        }
        wait(for: [written], timeout: 2)
        queue.sync { XCTAssertEqual(engine.sentPackets.count, 1) }
    }

    // MARK: U-A9 — async provider throw fires .error and does NOT call completion

    func testAsyncProviderThrowFiresErrorClientEvent() {
        struct ProviderError: LocalizedError {
            let errorDescription: String? = "fetch failed"
        }
        socket.setAuth { () async throws -> [String: Any]? in
            throw ProviderError()
        }
        drain()

        socket.setTestStatus(.connecting)

        let errorFired = expectation(description: ".error fired with provider failure message")
        let noCompletion = expectation(description: "completion must NOT fire on throw")
        noCompletion.isInverted = true
        var errorMessage: String?
        socket.on(clientEvent: .error) { data, _ in
            errorMessage = data.first as? String
            errorFired.fulfill()
        }

        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { _ in
                noCompletion.fulfill()
            }
        }

        wait(for: [errorFired], timeout: 2)
        // Brief inverted wait — give the wrong path a chance to fire.
        wait(for: [noCompletion], timeout: 0.4)
        // `.error` fulfills before abortPendingConnect() in the same hop;
        // drain so the status assertion cannot race that remaining work.
        drain()

        XCTAssertNotNil(errorMessage)
        XCTAssertTrue(errorMessage?.contains("auth provider failed") ?? false,
                      "expected localized failure message; got: \(errorMessage ?? "<nil>")")
        XCTAssertTrue(errorMessage?.contains("fetch failed") ?? false,
                      "expected error.localizedDescription to be included")
        XCTAssertEqual(socket.status, .notConnected,
                       "async auth throw must abort the pending connect instead of leaving .connecting")
    }

    // MARK: U-A10 — provider returning nil produces a CONNECT byte-identical
    //               to a static `connect(withPayload: nil)` (wire-shape parity)
    //
    // Spec §Phase 8: "Capture the CONNECT packet on the wire and assert it is
    // byte-identical to the CONNECT packet produced by static
    // `connect(withPayload: nil)`. Both must omit the `data` field."

    func testProviderReturningNilProducesIdenticalWireAsStaticNil() {
        // ----- Path A: provider that yields nil -----
        let url = URL(string: "http://localhost/")!
        let q1 = DispatchQueue(label: "test.parity.q1")
        let m1 = SocketManager(socketURL: url,
                               config: [.log(false), .handleQueue(q1)])
        let s1 = m1.defaultSocket
        let e1 = CaptureEngine()
        m1.engine = e1
        e1.client = m1
        s1.setAuth { cb in cb(nil) }
        q1.sync { }
        s1.connect()
        q1.sync { }
        m1.engineDidOpen(reason: "test")
        // Drain twice: `_engineDidOpen` invokes `resolveConnectPayload`, which
        // always async-hops back to `handleQueue` before calling completion (and
        // hence `writeConnectPacket`). The first drain finishes `_engineDidOpen`;
        // the second runs the queued completion that writes the CONNECT packet.
        q1.sync { }
        q1.sync { }
        let providerWire = e1.lastSent

        // ----- Path B: no provider, no payload -----
        let q2 = DispatchQueue(label: "test.parity.q2")
        let m2 = SocketManager(socketURL: url,
                               config: [.log(false), .handleQueue(q2)])
        let s2 = m2.defaultSocket
        let e2 = CaptureEngine()
        m2.engine = e2
        e2.client = m2
        s2.connect()
        q2.sync { }
        m2.engineDidOpen(reason: "test")
        q2.sync { }
        let staticWire = e2.lastSent

        XCTAssertNotNil(providerWire)
        XCTAssertNotNil(staticWire)
        XCTAssertEqual(providerWire, staticWire,
                       "provider returning nil must produce byte-identical CONNECT to static nil — got \(providerWire ?? "nil") vs \(staticWire ?? "nil")")
    }

    // MARK: U-A11 — provider payload merges with recovery pid + offset
    //
    // Spec §Phase 8: "The provider does NOT bypass recovery merge."

    func testProviderPayloadMergedWithRecoveryPidAndOffset() {
        let url = URL(string: "http://localhost/")!
        let mergeQueue = DispatchQueue(label: "test.recovery.merge")
        let mgr = SocketManager(socketURL: url,
                                config: [.log(false), .handleQueue(mergeQueue)])
        let sock = mgr.defaultSocket
        let engine = CaptureEngine()
        mgr.engine = engine
        engine.client = mgr

        sock.setAuth { cb in cb(["token": "abc"]) }
        mergeQueue.sync { }

        // Simulate a recovery-eligible socket: install pid + lastOffset before connect.
        sock._pid = "p-recovery-1"
        sock._lastOffset = "off-42"

        sock.connect()
        mergeQueue.sync { }
        mgr.engineDidOpen(reason: "test")
        // See `testProviderReturningNilProducesIdenticalWireAsStaticNil` — the
        // provider's resolution always async-hops back to `handleQueue`, so we
        // need a second drain to land the actual CONNECT packet on the engine.
        mergeQueue.sync { }
        mergeQueue.sync { }

        let wire = engine.lastSent ?? ""
        XCTAssertTrue(wire.contains("\"pid\":\"p-recovery-1\""),
                      "wire must include pid for recovery: \(wire)")
        XCTAssertTrue(wire.contains("\"offset\":\"off-42\""),
                      "wire must include offset for recovery: \(wire)")
        XCTAssertTrue(wire.contains("\"token\":\"abc\""),
                      "wire must include provider-supplied token: \(wire)")
    }


    // MARK: U-A13 — setAuth and clearAuth bump the generation token

    func testSetAuthBumpsGenerationAndClearAuthAlsoBumps() {
        // We can't read `authGeneration` directly (private), but we can observe
        // its effect on the async path's stale-result discard. This test just
        // verifies the generation-mutating methods are no-throw and queue-safe.
        socket.setAuth { cb in cb(nil) }
        socket.setAuth { cb in cb(["a": 1]) }
        socket.clearAuth()
        socket.setAuth { cb in cb(["b": 2]) }
        drain()

        let resolved = expectation(description: "final provider wins")
        var captured: [String: Any]?
        queue.socketAsync { [socket] in
            socket!.resolveConnectPayload(explicit: nil) { payload in
                captured = payload
                resolved.fulfill()
            }
        }
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(captured?["b"] as? Int, 2,
                       "the most recently installed provider must be the one invoked")
    }
}

extension SocketAuthProviderTest {
    func testUnserializableConnectPayloadAbortsJoinAndDiscardsPreconnectEvents() throws {
        let engine = MockEngine()
        manager.engine = engine
        try queue.sync {
            manager.setTestStatus(.connected)
            socket.setTestStatus(.connecting)
            var deliveries = 0
            var errors: [String] = []
            socket.on("early") { _, _ in deliveries += 1 }
            socket.on(clientEvent: .error) { data, _ in errors.append(data.first as? String ?? "") }
            socket.handlePacket(try manager.parseString("2[\"early\",42]"))
            manager.connectSocket(socket, withPayload: ["token": Double.nan])
            XCTAssertEqual(errors, ["connect payload serialization failed: invalid JSON object"])
            XCTAssertEqual(socket.status, .notConnected)
            XCTAssertTrue(engine.sentPackets.isEmpty)
            XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 0)
            // A corrected explicit join can recover; old incoming data must not leak.
            manager.connectSocket(socket, withPayload: ["token": "corrected"])
            XCTAssertEqual(engine.sentPackets.map { $0.0 }, ["0/,{\"token\":\"corrected\"}"])
            socket.didConnect(toNamespace: "/", payload: ["sid": "new"])
            XCTAssertEqual(deliveries, 0)
        }
    }

    func testInvalidParserConfigurationNeverStartsTheAttachedEngine() {
        let invalid = SocketManager(socketURL: URL(string: "http://localhost")!,
                                    config: [.parserOptions(SocketParserOptions(maximumAttachments: 0)), .log(false)])
        let engine = TestEngine(client: invalid, url: invalid.socketURL, options: nil)
        invalid.engine = engine
        var opens = 0
        var errors: [String] = []
        engine.onConnect = { opens += 1 }
        invalid.defaultSocket.on(clientEvent: .connectError) { data, _ in errors.append(data.first as? String ?? "") }
        invalid.connect()
        XCTAssertEqual(errors, ["Invalid parser limits"])
        XCTAssertEqual(invalid.status, .disconnected)
        XCTAssertEqual(opens, 0)
    }
}
