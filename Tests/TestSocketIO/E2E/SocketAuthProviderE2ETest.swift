import XCTest
@testable import SocketIO

/// End-to-end tests for the Phase 8 `setAuth` provider surface. These tests
/// stand up the Node Socket.IO 4.x test server and exercise the full
/// CONNECT path (engine open → namespace CONNECT) against a real server.
final class SocketAuthProviderE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var managers = [SocketManager]()

    override func tearDown() {
        server?.stop()
        server = nil
        managers.removeAll()
        super.tearDown()
    }

    // MARK: Helpers

    private func startServer(serverScript: String = "server.js") throws {
        server = try TestServerProcess.start(serverScript: serverScript)
    }

    private func makeClient(

        forceNew: Bool = true,
        reconnects: Bool = true
    ) -> (SocketManager, SocketIOClient) {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        let config: SocketIOClientConfiguration = [
            .log(false),

            .reconnects(reconnects),
            .reconnectWait(1),
            .forceNew(forceNew)
        ]
        let manager = SocketManager(socketURL: url, config: config)
        managers.append(manager)
        return (manager, manager.defaultSocket)
    }

    private func adminKillTransport(sid: String) throws {
        let (status, _) = try server.admin("/admin/kill-transport?sid=\(sid)")
        XCTAssertEqual(status, 200)
    }

    private func adminLastAuth(sid: String) throws -> [String: Any]? {
        let (status, body) = try server.admin("/admin/last-auth?sid=\(sid)", method: "GET")
        XCTAssertEqual(status, 200)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return obj?["auth"] as? [String: Any]
    }

    private func adminConnectCount() throws -> Int {
        let (status, body) = try server.admin("/admin/connect-count", method: "GET")
        XCTAssertEqual(status, 200)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return obj?["count"] as? Int ?? -1
    }

    private func adminConnectFrameCount() throws -> Int {
        let (status, body) = try server.admin("/admin/connect-frame-count", method: "GET")
        XCTAssertEqual(status, 200)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return obj?["count"] as? Int ?? -1
    }

    private func waitForConnect(_ socket: SocketIOClient, timeout: TimeInterval = 10) {
        let expect = expectation(description: "connected")
        socket.once(clientEvent: .connect) { _, _ in expect.fulfill() }
        if socket.status != .connecting && socket.status != .connected {
            socket.connect()
        }
        wait(for: [expect], timeout: timeout)
    }

    // MARK: E1 — provider sends auth on every CONNECT (initial)

    func testProviderSendsAuthOnConnect() throws {
        try startServer()
        let (_, socket) = makeClient()

        socket.setAuth { cb in cb(["token": "abc"]) }
        waitForConnect(socket)

        let sid = try XCTUnwrap(socket.sid, "socket.sid must be set after .connect")
        let auth = try adminLastAuth(sid: sid)
        XCTAssertEqual(auth?["token"] as? String, "abc",
                       "server handshake.auth must reflect the provider's resolved payload")
    }

    // MARK: E2 — provider re-invoked on reconnect (forced transport kill)

    func testProviderReinvokedOnReconnect() throws {
        try startServer()
        let (_, socket) = makeClient()

        let lock = NSLock()
        var invocations = 0
        socket.setAuth { cb in
            lock.lock()
            invocations += 1
            lock.unlock()
            cb(["token": "abc"])
        }
        waitForConnect(socket)

        let firstSid = try XCTUnwrap(socket.sid)

        // Wait for at least the first invocation to have settled.
        lock.lock()
        let firstCount = invocations
        lock.unlock()
        XCTAssertGreaterThanOrEqual(firstCount, 1, "provider must have run at least once for the first CONNECT")

        // Force a reconnect by killing the underlying transport.
        let reconnected = expectation(description: "reconnect observed")
        socket.on(clientEvent: .connect) { _, _ in
            // Accept any subsequent .connect after the kill as reconnect proof.
            reconnected.fulfill()
        }
        try adminKillTransport(sid: firstSid)
        wait(for: [reconnected], timeout: 15)

        // Give the post-reconnect provider invocation a moment to settle.
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock()
        let total = invocations
        lock.unlock()
        XCTAssertGreaterThanOrEqual(total, 2,
                                    "provider must be re-invoked on reconnect; saw \(total) total invocations")

        // And the most recent handshake must still carry the provider's auth.
        let latestSid = try XCTUnwrap(socket.sid)
        let auth = try adminLastAuth(sid: latestSid)
        XCTAssertEqual(auth?["token"] as? String, "abc")
    }

    // MARK: E3 — multi-callback provider sends two CONNECT frames (JS parity)
    //
    // The previous incarnation of this test asserted only `delta >= 1` against
    // `io.on("connection")` (which the socket.io@4 server dedupes per-namespace
    // on a shared engine). That assertion was tautological. Now we tap raw
    // engine.io packets at the server and count `0<nsp>` frames directly,
    // bypassing the per-namespace dedup entirely. The JS reference client
    // writes two CONNECT frames; we assert exactly two reach the wire.
    //
    // The unit test `testMultiCallbackProviderInvokesCompletionTwice` is the
    // authoritative client-side check (completion fires twice → two writes).
    // This E2E confirms both writes actually leave the client and reach the
    // server's engine.io layer.

    func testProviderMultiCallbackSendsTwoConnects() throws {
        try startServer()
        let (_, socket) = makeClient(reconnects: false)

        let baselineFrames = try adminConnectFrameCount()

        socket.setAuth { cb in
            cb(["a": 1])
            cb(["b": 2])
        }
        waitForConnect(socket)

        // Allow the second CONNECT frame to settle on the wire.
        Thread.sleep(forTimeInterval: 0.4)

        let finalFrames = try adminConnectFrameCount()
        let delta = finalFrames - baselineFrames
        XCTAssertEqual(delta, 2,
                       "multi-callback must produce 2 raw CONNECT frames on the wire; got \(delta)")
    }


    // MARK: E5 — identity-swap stale-auth race

    func testIdentitySwapStaleAuthRace() throws {
        try startServer()
        let (_, socket) = makeClient(reconnects: false)

        // Async provider returns ["token":"old"] after 500ms. We immediately
        // disconnect, clearAuth, install a fresh sync provider returning
        // ["token":"new"], and reconnect. The new connect must carry "new",
        // never "old", proving the generation token kills the stale result.
        socket.setAuth { () async throws -> [String: Any]? in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ["token": "old"]
        }
        socket.connect()

        // Yield briefly so the first connect attempt actually issues to the
        // engine and the async Task is scheduled.
        Thread.sleep(forTimeInterval: 0.05)

        // Race: tear down before the 500ms async resolves.
        socket.disconnect()
        socket.clearAuth()
        socket.setAuth { cb in cb(["token": "new"]) }

        // Wait for the disconnect to fully settle on the manager queue.
        let disconnected = expectation(description: "disconnected")
        socket.once(clientEvent: .disconnect) { _, _ in disconnected.fulfill() }
        // It may have already fired; use a brief inverted-style wait fallback.
        let result = XCTWaiter().wait(for: [disconnected], timeout: 1.5)
        if result == .timedOut {
            // Already disconnected; carry on.
        }

        // Reconnect with the fresh sync provider installed.
        let reconnected = expectation(description: "reconnect observed")
        socket.once(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        socket.connect()
        wait(for: [reconnected], timeout: 10)

        // Sleep beyond the stale provider's 500ms sleep so any forbidden
        // late-write would have happened.
        Thread.sleep(forTimeInterval: 0.6)

        let newSid = try XCTUnwrap(socket.sid)
        let auth = try adminLastAuth(sid: newSid)
        XCTAssertEqual(auth?["token"] as? String, "new",
                       "the late stale provider must NOT contaminate the second handshake")
    }
}
