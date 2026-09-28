import XCTest
@testable import SocketIO

/// Scenarios ported one-to-one from the JavaScript client's own test suite
/// (`socket.io/packages/socket.io-client/test`, v4.8.3), run against the same
/// kind of server it is tested against.
///
/// The point is not to add more Swift tests but to let the reference client's
/// expectations decide what "parity" means, instead of our reading of the
/// source. Each test names the JS file and title it comes from; the fixture
/// namespaces (`/no`, `/with-data`, `/foo`, `/asd`) and the `echo` handler
/// mirror `test/support/server.ts`.
///
/// See `PARITY.md` for the full matrix, including the scenarios that are not
/// portable and why.
final class JSParityE2ETest: XCTestCase {
    var server: TestServerProcess!
    var manager: SocketManager!
    var serverURL: URL { URL(string: "http://127.0.0.1:\(server.port)")! }

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        manager?.disconnect()
        manager = nil
        server.stop()
        super.tearDown()
    }

    private func makeManager(_ extra: SocketIOClientOption...) -> SocketManager {
        var config: SocketIOClientConfiguration = [.log(false)]
        for option in extra { config.insert(option) }

        manager = SocketManager(socketURL: serverURL, config: config)

        return manager
    }

    /// Connects and waits for it. The handler stays registered, so reconnects
    /// later in a test do not trip the over-fulfil check.
    @discardableResult
    private func connect(_ socket: SocketIOClient) -> SocketIOClient {
        let connected = expectation(description: "connect \(socket.nsp)")
        connected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        return socket
    }

    /// Waits a fixed interval, for assertions that nothing *further* happens.
    private func settle(_ seconds: TimeInterval) {
        let done = expectation(description: "settled")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    /// Raw socket.io CONNECT frames the server has seen, counted at the
    /// engine.io layer so duplicates cannot be deduplicated away.
    private func connectFrameCount() throws -> Int {
        let (status, body) = try server.admin("/admin/connect-frame-count", method: "GET")
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        return json?["count"] as? Int ?? -1
    }

    /// Reads the receiving namespace's own server-side ID, not an echoed client ID.
    private func serverSocketId(for socket: SocketIOClient) throws -> String {
        let replied = expectation(description: "server ID for \(socket.nsp)")
        var serverID: String?
        socket.emitWithAck("server-socket-id").timingOut(after: 5) { data in
            serverID = data.first as? String
            XCTAssertNotEqual(serverID, SocketAckStatus.noAck.rawValue)
            replied.fulfill()
        }
        wait(for: [replied], timeout: 6)
        return try XCTUnwrap(serverID)
    }

    /// Drops the engine from the server side, the way `StateRecoveryE2ETest`
    /// does. The JS tests call `socket.io.engine.close()`, but a client-initiated
    /// close is a *clean* shutdown here and does not reliably trigger a
    /// reconnect — killing the transport server-side reproduces the unexpected
    /// drop those tests mean to simulate.
    private func killTransport(ofSocketWithId sid: String) throws {
        let (status, _) = try server.admin("/admin/kill-transport?sid=\(sid)")
        XCTAssertEqual(status, 200)
    }

    /// CONNECT_ERROR arrives as the `connect_error` client event, JS-aligned.
    /// What has to match is that the server's message reaches the application
    /// at all.
    private func errorMessage(from data: [Any]) -> String? {
        if let payload = data.first as? [String: Any] {
            return payload["message"] as? String
        }

        return data.first as? String
    }

    // MARK: socket.ts — "should fire an error event on middleware failure from custom namespace"

    func testMiddlewareFailureOnCustomNamespaceIsReported() {
        let socket = makeManager().socket(forNamespace: "/no")

        let failed = expectation(description: "connect error")
        // A refused namespace may be retried; only the first report is under test.
        failed.assertForOverFulfill = false
        var message: String?
        socket.on(clientEvent: .connectError) { data, _ in
            message = self.errorMessage(from: data)
            failed.fulfill()
        }
        socket.connect()

        wait(for: [failed], timeout: 5)
        XCTAssertEqual(message, "Auth failed (custom namespace)")
    }

    // MARK: socket.ts — "should fire a connect_error event with error data on middleware failure"

    func testMiddlewareFailureCarriesItsErrorData() {
        let socket = makeManager().socket(forNamespace: "/with-data")

        let failed = expectation(description: "connect error")
        failed.assertForOverFulfill = false
        var payload: [String: Any]?
        socket.on(clientEvent: .connectError) { data, _ in
            payload = data.first as? [String: Any]
            failed.fulfill()
        }
        socket.connect()

        wait(for: [failed], timeout: 5)

        XCTAssertEqual(payload?["message"] as? String, "Auth failed (with data)")

        let errorData = payload?["data"] as? [String: Any]
        XCTAssertEqual(Set(errorData?.keys.map { $0 } ?? []), Set(["code", "details"]))
        XCTAssertEqual(errorData?["code"] as? Int, 401,
                       "JS exposes err.data; without it the app cannot tell 401 from any other refusal")
        XCTAssertEqual(errorData?["details"] as? String, "Invalid token")
    }

    // MARK: socket.ts — "should not try to reconnect after a middleware failure"

    /// The server refused this namespace. Rejoining it on the next engine open
    /// would hammer a server that already said no, so JS does not: it destroys
    /// the socket's subscriptions on CONNECT_ERROR and waits for an explicit
    /// `connect()`.
    func testNoRejoinAfterAMiddlewareFailure() throws {
        let manager = makeManager(.reconnectWait(1))

        // A socket on a namespace the server accepts, so the engine has a
        // transport to kill and something to prove it came back.
        let root = manager.socket(forNamespace: "/")
        let rootConnected = expectation(description: "root connected")
        let rootReconnected = expectation(description: "root reconnected")
        var rootConnects = 0
        root.on(clientEvent: .connect) { _, _ in
            rootConnects += 1
            if rootConnects == 1 { rootConnected.fulfill() }
            if rootConnects == 2 { rootReconnected.fulfill() }
        }
        root.connect()
        wait(for: [rootConnected], timeout: 5)

        let refused = manager.socket(forNamespace: "/no")
        var errorCount = 0
        let firstError = expectation(description: "first connect error")
        firstError.assertForOverFulfill = false
        refused.on(clientEvent: .connectError) { _, _ in
            errorCount += 1
            firstError.fulfill()
        }
        refused.connect()
        wait(for: [firstError], timeout: 5)

        let sid = try XCTUnwrap(root.sid)
        try killTransport(ofSocketWithId: sid)

        wait(for: [rootReconnected], timeout: 10)
        // A server round trip after reconnect is a processing barrier, not a
        // guessed sleep: a mistakenly re-sent /no CONNECT precedes this event.
        XCTAssertEqual(try serverSocketId(for: root), root.sid)
        XCTAssertEqual(rootConnects, 2, "The engine has to actually reconnect, or this proves nothing")
        XCTAssertEqual(errorCount, 1, "The namespace must not be rejoined after the server refused it")
        XCTAssertEqual(try connectFrameCount(), 3, "Only initial root, refused namespace and reconnected root CONNECTs are allowed")
    }

    // MARK: socket.ts — "should not discard an unsent ack (callback)"

    /// Disconnect, emit, reconnect: the packet is buffered and its ack is still
    /// owed. This is the JS scenario that the send buffer exists for.
    func testAnUnsentAckIsNotDiscarded() {
        let socket = makeManager().socket(forNamespace: "/")

        let connected = expectation(description: "connect")
        // The handler stays registered across the reconnect below.
        connected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        socket.disconnect()

        let acked = expectation(description: "the buffered emit is acked after reconnecting")
        socket.emitWithAck("echo", "a").timingOut(after: 10) { data in
            XCTAssertEqual(data.first as? String, "a")
            acked.fulfill()
        }

        socket.connect()
        wait(for: [acked], timeout: 10)
    }

    // MARK: socket.ts — "should not ack upon disconnection (callback)"

    /// The mirror image of the test above: an ack registered with no timeout on
    /// a socket that is then disconnected is dropped silently. It must never
    /// fire — not with data, not with an error — and it must not stay in the
    /// registry (JS `_clearAcks` empties `socket.acks`).
    func testANoTimeoutAckIsNotCalledAfterDisconnecting() {
        let socket = makeManager().socket(forNamespace: "/")
        connect(socket)

        let neverAcked = expectation(description: "the ack must not fire after disconnecting")
        neverAcked.isInverted = true
        socket.emit("echo", "a", ack: { _, _ in neverAcked.fulfill() })
        // JS registers the ack synchronously inside `emit()` and disconnects on
        // the very next line. Here registration is dispatched to the manager's
        // handleQueue, so the disconnect goes through that same serial queue: it
        // lands after the registration and before any ack the server sends back,
        // which a wall-clock wait could not guarantee. (`handleQueue.sync` is not
        // an option — this manager's handleQueue is the queue we are on.)
        manager.handleQueue.socketAsync { socket.disconnect() }
        settle(0.2)
        // Read on handleQueue: it is the main queue, which is this thread.
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)

        // The server may well answer the echo; none of it may reach the callback.
        settle(1)
        wait(for: [neverAcked], timeout: 0.1)
    }

    // MARK: socket.ts — "clears socket.id upon disconnection"

    /// Root IDs match the server's ID and are cleared by explicit disconnection.
    func testSocketIdIsClearedOnDisconnect() throws {
        let socket = makeManager().socket(forNamespace: "/")

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)
        XCTAssertEqual(try serverSocketId(for: socket), try XCTUnwrap(socket.sid))
        XCTAssertFalse(socket.sid?.isEmpty ?? true)
        XCTAssertNotEqual(socket.sid, manager.engine?.sid)

        let disconnected = expectation(description: "disconnect")
        disconnected.assertForOverFulfill = false
        socket.on(clientEvent: .disconnect) { _, _ in
            XCTAssertTrue(socket.sid?.isEmpty ?? true)
            disconnected.fulfill()
        }
        socket.disconnect()
        wait(for: [disconnected], timeout: 5)

        XCTAssertTrue(socket.sid?.isEmpty ?? true, "A cleared id is what tells the app the session is gone")
    }

    // MARK: socket.ts — "should change socket.id upon reconnection"

    func testSocketIdChangesOnReconnection() throws {
        let manager = makeManager(.reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")

        let connected = expectation(description: "connect")
        // The handler stays registered and fires again on the reconnect below.
        connected.assertForOverFulfill = false
        var connects = 0
        socket.on(clientEvent: .connect) { _, _ in
            connects += 1
            connected.fulfill()
        }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let firstId = try XCTUnwrap(socket.sid)
        var attempts = 0
        var reconnects = 0
        socket.on(clientEvent: .reconnect) { _, _ in
            reconnects += 1
            XCTAssertNotEqual(socket.sid, firstId)
        }
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            attempts += 1
            XCTAssertTrue(socket.sid?.isEmpty ?? true)
        }

        try killTransport(ofSocketWithId: firstId)

        let reconnected = expectation(description: "reconnect")
        reconnected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        wait(for: [reconnected], timeout: 15)

        XCTAssertGreaterThan(attempts, 0)
        XCTAssertEqual(reconnects, 1)
        XCTAssertGreaterThan(connects, 1)
        XCTAssertNotEqual(socket.sid, firstId, "A new session must not reuse the old id")
    }

    // MARK: connection.ts — "should not close the connection when disconnecting a single socket"

    /// Two namespaces share one engine. Leaving one must not take the other
    /// down with it.
    func testDisconnectingOneNamespaceKeepsTheOtherConnected() {
        let manager = ParityCloseObservingManager(socketURL: serverURL, config: [.log(false)])
        self.manager = manager
        let foo = manager.socket(forNamespace: "/foo")
        let asd = manager.socket(forNamespace: "/asd")

        let bothConnected = expectation(description: "both namespaces connected")
        bothConnected.expectedFulfillmentCount = 2
        bothConnected.assertForOverFulfill = false
        foo.on(clientEvent: .connect) { _, _ in bothConnected.fulfill() }
        asd.on(clientEvent: .connect) { _, _ in bothConnected.fulfill() }
        foo.connect()
        asd.connect()
        wait(for: [bothConnected], timeout: 5)

        var asdDisconnected = false
        asd.on(clientEvent: .disconnect) { _, _ in asdDisconnected = true }

        foo.disconnect()

        let settled = expectation(description: "give the disconnect time to propagate")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertFalse(asdDisconnected, "Leaving one namespace must not close the shared engine")
        XCTAssertEqual(asd.status, .connected)
        let closed = expectation(description: "last namespace closes the engine")
        manager.onEngineClose = { reason in
            XCTAssertEqual(reason, "io client disconnect")
            closed.fulfill()
        }
        asd.disconnect()
        XCTAssertTrue(asdDisconnected)
        XCTAssertEqual(manager.status, .disconnected)
        wait(for: [closed], timeout: 5)
        manager.engine?.engineQueue.sync { XCTAssertTrue(manager.engine?.closed == true) }
    }

    // MARK: connection.ts — "should work with acks"

    func testEmitWithAckRoundTrip() {
        let socket = makeManager().socket(forNamespace: "/")

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let acked = expectation(description: "ack")
        socket.emitWithAck("echo", "hello").timingOut(after: 5) { data in
            XCTAssertEqual(data.first as? String, "hello")
            acked.fulfill()
        }
        wait(for: [acked], timeout: 5)
    }

    // MARK: connection.ts — "should receive utf8 multibyte characters"

    func testUtf8MultibyteCharactersSurviveTheRoundTrip() {
        let socket = makeManager().socket(forNamespace: "/")

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        // All five strings from the pinned JS test, including its duplicate.
        let strings = [
            "てすと",
            "Я Б Г Д Ж Й",
            "Ä ä Ü ü ß",
            "utf8 — string",
            "utf8 — string"
        ]

        for string in strings {
            let acked = expectation(description: "ack for \(string)")
            socket.emitWithAck("echo", string).timingOut(after: 5) { data in
                XCTAssertEqual(data.first as? String, string)
                acked.fulfill()
            }
            wait(for: [acked], timeout: 5)
        }
    }

    // MARK: connection.ts — "should work with false"

    func testFalseSurvivesTheRoundTrip() {
        let socket = makeManager().socket(forNamespace: "/")

        let received = expectation(description: "false comes back")
        socket.on("false") { data, _ in
            XCTAssertEqual(data.first as? Bool, false, "A falsy value must not be lost or turned into nil")
            received.fulfill()
        }
        socket.emit("false")
        socket.connect()

        wait(for: [received], timeout: 5)
    }

    // MARK: connection.ts — "should connect to a namespace after connection established"

    func testJoinANamespaceAfterTheConnectionIsEstablished() {
        let manager = makeManager()
        connect(manager.socket(forNamespace: "/"))

        let foo = connect(manager.socket(forNamespace: "/foo"))

        XCTAssertEqual(foo.status, .connected)
    }

    // MARK: connection.ts — "should open a new namespace after connection gets closed"

    func testJoinANewNamespaceAfterTheConnectionWasClosed() {
        let manager = makeManager()
        let root = connect(manager.socket(forNamespace: "/"))

        let disconnected = expectation(description: "disconnect")
        disconnected.assertForOverFulfill = false
        root.on(clientEvent: .disconnect) { _, _ in disconnected.fulfill() }
        root.disconnect()
        wait(for: [disconnected], timeout: 5)

        let foo = connect(manager.socket(forNamespace: "/foo"))

        XCTAssertEqual(foo.status, .connected)
    }

    // MARK: connection.ts — "should not reopen a cached but active socket"

    /// Looking up a connected, active socket must not send another CONNECT.
    /// A post-lookup server round trip precedes the raw-frame count assertion.
    func testFetchingTheSameNamespaceTwiceSendsOneConnectFrame() {
        let recorded = ParityPacketRecordingManager(socketURL: serverURL, config: [.autoConnect(true)])
        manager = recorded
        let socket = recorded.defaultSocket
        let again = recorded.socket(forNamespace: "/")
        XCTAssertTrue(socket === again)
        let disconnected = expectation(description: "cached socket closes once")
        socket.once(clientEvent: .connect) { _, _ in
            socket.disconnect()
            disconnected.fulfill()
        }
        wait(for: [disconnected], timeout: 5)
        XCTAssertEqual(recorded.createdPackets, ["0", "1"])
    }

    // MARK: connection.ts — "should not reopen an already active socket"

    func testTwoNamespacesSendOneConnectFrameEach() {
        let recorded = ParityPacketRecordingManager(socketURL: serverURL, config: [.autoConnect(true)])
        manager = recorded
        let root = recorded.defaultSocket
        let foo = recorded.socket(forNamespace: "/foo")
        let disconnected = expectation(description: "both namespaces leave")
        root.once(clientEvent: .connect) { _, _ in
            root.disconnect()
            foo.disconnect()
            disconnected.fulfill()
        }
        wait(for: [disconnected], timeout: 5)
        XCTAssertEqual(recorded.createdPackets, ["0", "0/foo,", "1", "1/foo,"])
    }

    // MARK: socket.ts — "should have an accessible socket id equal to the server-side socket id (custom namespace)"

    /// Both namespace IDs must equal IDs independently supplied by their servers.
    func testSocketIdOnACustomNamespace() throws {
        let manager = makeManager()
        let root = connect(manager.socket(forNamespace: "/"))
        let foo = connect(manager.socket(forNamespace: "/foo"))

        XCTAssertEqual(try serverSocketId(for: root), try XCTUnwrap(root.sid))
        XCTAssertEqual(try serverSocketId(for: foo), try XCTUnwrap(foo.sid))
        XCTAssertFalse(foo.sid?.isEmpty ?? true)
        XCTAssertNotEqual(foo.sid, root.sid, "Each namespace gets its own server-side id")
        XCTAssertNotEqual(foo.sid, manager.engine?.sid)
    }

    // MARK: socket.ts — "doesn't fire an error event if we force disconnect in opening state"

    func testNoErrorWhenDisconnectingWhileStillOpening() {
        let manager = makeManager(.connectTimeout(0.1))
        let socket = manager.socket(forNamespace: "/")

        var errors = [[Any]]()
        socket.on(clientEvent: .error) { data, _ in errors.append(data) }
        socket.on(clientEvent: .connectError) { data, _ in errors.append(data) }

        socket.connect()
        socket.disconnect()

        settle(1.5)

        XCTAssertTrue(errors.isEmpty, "Tearing down an in-flight connect is not an error: \(errors)")
    }

    // MARK: socket.ts — "doesn't fire a connect_error event when the connection is already established"

    /// The JS assertion concerns connect_error, not Swift's runtime .error
    /// diagnostic. URLSession may report a native receive failure when the
    /// server drops the transport; that detail must not be suppressed just to
    /// satisfy this test. The drop must still disconnect and reconnect once.
    func testNoErrorEventWhenAnEstablishedConnectionDrops() throws {
        let manager = makeManager(.reconnectWait(1))
        let socket = connect(manager.socket(forNamespace: "/"))
        defer { socket.removeAllHandlers() }

        var connectErrors = [[Any]]()
        var lifecycle = [String]()
        var disconnectCount = 0
        var connectCount = 0
        let disconnected = expectation(description: "transport disconnected")
        let reconnected = expectation(description: "namespace reconnected")
        socket.on(clientEvent: .connectError) { data, _ in connectErrors.append(data) }
        socket.on(clientEvent: .disconnect) { data, _ in
            lifecycle.append("disconnect")
            disconnectCount += 1
            XCTAssertTrue(["transport close", "transport error"].contains(data.first as? String ?? ""))
            if disconnectCount == 1 { disconnected.fulfill() }
        }
        socket.on(clientEvent: .reconnect) { _, _ in lifecycle.append("reconnect") }
        socket.on(clientEvent: .connect) { _, _ in
            lifecycle.append("connect")
            connectCount += 1
            if connectCount == 1 { reconnected.fulfill() }
        }

        try killTransport(ofSocketWithId: XCTUnwrap(socket.sid))
        wait(for: [disconnected, reconnected], timeout: 15, enforceOrder: true)
        // A real round trip proves that the replacement connection is usable
        // and provides a processing barrier instead of the old fixed sleep.
        XCTAssertEqual(try serverSocketId(for: socket), socket.sid)

        XCTAssertTrue(connectErrors.isEmpty, "An established transport drop is not a connect_error: \(connectErrors)")
        XCTAssertEqual(lifecycle, ["disconnect", "reconnect", "connect"])
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(socket.status, .connected)
        XCTAssertTrue(socket.active)
    }

    // MARK: connection.ts — "should reconnect manually"

    func testReconnectManually() {
        let manager = makeManager()
        let socket = manager.socket(forNamespace: "/")
        connect(socket)

        let disconnected = expectation(description: "manual disconnect")
        disconnected.assertForOverFulfill = false
        socket.on(clientEvent: .disconnect) { _, _ in disconnected.fulfill() }
        socket.disconnect()
        wait(for: [disconnected], timeout: 5)

        connect(socket)

        XCTAssertEqual(socket.status, .connected)
    }

    // MARK: connection.ts — "should reconnect automatically after reconnecting manually"

    func testReconnectAutomaticallyAfterReconnectingManually() throws {
        let manager = makeManager(.reconnectWait(1))
        let socket = manager.defaultSocket
        let manuallyReconnected = expectation(description: "manual reconnect from disconnect callback")
        var connects = 0
        socket.on(clientEvent: .connect) { _, _ in
            connects += 1
            if connects == 1 { socket.disconnect() }
            if connects == 2 { manuallyReconnected.fulfill() }
        }
        socket.once(clientEvent: .disconnect) { _, _ in socket.connect() }
        socket.connect()
        wait(for: [manuallyReconnected], timeout: 10)

        let reconnect = expectation(description: "automatic reconnect event")
        socket.once(clientEvent: .reconnect) { data, _ in
            XCTAssertEqual(data.first as? Int, 1)
            reconnect.fulfill()
        }
        let joined = expectation(description: "namespace rejoins after automatic reconnect")
        socket.once(clientEvent: .connect) { _, _ in joined.fulfill() }
        try killTransport(ofSocketWithId: XCTUnwrap(socket.sid))
        wait(for: [reconnect, joined], timeout: 15, enforceOrder: true)
        XCTAssertEqual(connects, 3)
        XCTAssertEqual(socket.status, .connected)
    }

    // MARK: socket.ts — "should properly disconnect then reconnect"

    func testDisconnectThenReconnect() {
        let manager = makeManager(.forceWebsockets(true))
        let socket = manager.socket(forNamespace: "/")

        var connects = 0
        var disconnects = 0
        var bounced = false
        let reconnected = expectation(description: "connected again after bounce")
        reconnected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in
            connects += 1
            if !bounced {
                bounced = true
                socket.disconnect()
                socket.connect()
            } else {
                reconnected.fulfill()
            }
        }
        socket.on(clientEvent: .disconnect) { _, _ in disconnects += 1 }
        socket.connect()
        wait(for: [reconnected], timeout: 10)

        settle(1)

        XCTAssertEqual(connects, 2, "The bounce must be followed by exactly one reconnect")
        XCTAssertEqual(disconnects, 1, "The bounce must surface exactly one disconnect")
        XCTAssertEqual(socket.status, .connected)
    }

    // MARK: connection.ts — "should connect while disconnecting another socket"

    func testConnectWhileDisconnectingAnotherSocket() {
        let manager = makeManager()
        let foo = manager.socket(forNamespace: "/foo")
        let asd = manager.socket(forNamespace: "/asd")
        let joined = expectation(description: "second namespace joins")
        asd.once(clientEvent: .connect) { _, _ in joined.fulfill() }
        foo.once(clientEvent: .connect) { _, _ in
            asd.connect()
            foo.disconnect()
        }
        foo.connect()
        wait(for: [joined], timeout: 5)
        XCTAssertEqual(asd.status, .connected)
        XCTAssertEqual(foo.status, .disconnected)
    }

    // MARK: connection.ts — "should stop reconnecting on a socket and keep to reconnect on another"

    func testStopReconnectingOnOneSocketButNotTheOther() throws {
        let manager = makeManager(.reconnectWait(1))
        let socket1 = manager.socket(forNamespace: "/")
        let socket2 = manager.socket(forNamespace: "/asd")

        var connects1 = 0
        var connects2 = 0
        let bothConnected = expectation(description: "both namespaces connected")
        bothConnected.expectedFulfillmentCount = 2
        bothConnected.assertForOverFulfill = false
        socket1.on(clientEvent: .connect) { _, _ in
            connects1 += 1
            bothConnected.fulfill()
        }
        socket2.on(clientEvent: .connect) { _, _ in
            connects2 += 1
            bothConnected.fulfill()
        }
        socket1.connect()
        socket2.connect()
        wait(for: [bothConnected], timeout: 5)

        // Registered after the initial connects, so this only fires on the
        // reconnect. The `connects2` count below proves the engine came back.
        let socket2Back = expectation(description: "second socket reconnected")
        socket2Back.assertForOverFulfill = false
        socket2.on(clientEvent: .connect) { _, _ in socket2Back.fulfill() }

        var stoppedFirst = false
        socket1.on(clientEvent: .reconnectAttempt) { _, _ in
            if !stoppedFirst {
                stoppedFirst = true
                socket1.disconnect()
            }
        }

        try killTransport(ofSocketWithId: XCTUnwrap(socket1.sid))
        wait(for: [socket2Back], timeout: 15)

        settle(2)

        XCTAssertGreaterThan(connects2, 1, "The engine has to actually reconnect, or this proves nothing")
        XCTAssertEqual(connects1, 1, "The stopped socket must not connect again")
    }

    // MARK: connection.ts — "should not try to reconnect and should form a connection when connecting to correct port with default timeout"

    func testNoReconnectAttemptWhenConnectingToCorrectPort() {
        let manager = makeManager(.reconnects(true), .reconnectWait(1))
        let socket = manager.socket(forNamespace: "/valid")

        var attempts = 0
        socket.on(clientEvent: .reconnectAttempt) { _, _ in attempts += 1 }

        connect(socket)
        settle(2)

        XCTAssertEqual(attempts, 0, "A healthy connection must not attempt to reconnect")
        XCTAssertEqual(socket.status, .connected)
    }

    // MARK: socket.ts — "should properly encode the parameters"

    func testQueryParametersAreProperlyEncoded() {
        let manager = makeManager(.connectParams(["&a": "&=?a"]))
        let socket = manager.socket(forNamespace: "/abc")

        let gotHandshake = expectation(description: "handshake")
        var queryValue: String?
        socket.on("handshake") { data, _ in
            let handshake = data.first as? [String: Any]
            let query = handshake?["query"] as? [String: Any]
            queryValue = query?["&a"] as? String
            gotHandshake.fulfill()
        }
        socket.connect()
        wait(for: [gotHandshake], timeout: 5)

        XCTAssertEqual(queryValue, "&=?a")
    }

    func testAutoConnectAlsoJoinsNewlyCreatedNamespaces() {
        let manager = makeManager(.autoConnect(true))
        let foo = manager.socket(forNamespace: "/foo")
        XCTAssertTrue(foo.active)
        let joined = expectation(description: "new namespace auto-connects")
        foo.once(clientEvent: .connect) { _, _ in joined.fulfill() }
        wait(for: [joined], timeout: 5)
        XCTAssertEqual(foo.status, .connected)
    }

    func testNamespaceConnectPacketsFollowSubscriptionRatherThanCreationOrder() {
        let recorded = ParityPacketRecordingManager(socketURL: serverURL)
        manager = recorded
        let foo = recorded.socket(forNamespace: "/foo")
        let asd = recorded.socket(forNamespace: "/asd")
        let joined = expectation(description: "both subscribed namespaces join")
        joined.expectedFulfillmentCount = 2
        foo.once(clientEvent: .connect) { _, _ in joined.fulfill() }
        asd.once(clientEvent: .connect) { _, _ in joined.fulfill() }
        asd.connect()
        foo.connect()
        wait(for: [joined], timeout: 5)
        XCTAssertEqual(recorded.createdPackets, ["0/asd,", "0/foo,"])
    }

    func testOriginalBase64FallbackDeliversTheSameBinaryData() throws {
        let socket = makeManager(.forcePolling(true), .forceBase64(true)).defaultSocket
        let received = expectation(description: "base64 binary delivered")
        socket.on("takebin") { data, _ in
            let binary = data.first as? Data
            XCTAssertNotNil(binary)
            XCTAssertEqual(binary?.base64EncodedString(), "YXNkZmFzZGY=")
            received.fulfill()
        }
        socket.connect()
        socket.emit("getbin")
        wait(for: [received], timeout: 5)
        let engine = try XCTUnwrap(manager.engine as? SocketEngine)
        let query = URLComponents(url: engine.urlPolling, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "b64", value: "1")) == true)
    }

    func testOriginalBinaryReceptionUsesDataOnBothTransports() {
        for transport: SocketIOClientOption in [.forcePolling(true), .forceWebsockets(true)] {
            let socket = makeManager(transport).defaultSocket
            let received = expectation(description: "doge binary received")
            socket.on("doge") { data, _ in
                XCTAssertEqual(data.first as? Data, Data("asdfasdf".utf8))
                received.fulfill()
            }
            socket.connect()
            socket.emit("doge")
            wait(for: [received], timeout: 5)
            socket.disconnect()
        }
    }

    func testOriginalBinarySendIsDecodedAsBinaryByTheServer() {
        for transport: SocketIOClientOption in [.forcePolling(true), .forceWebsockets(true)] {
            let socket = makeManager(transport).defaultSocket
            let received = expectation(description: "server recognizes binary")
            socket.on("buffack") { _, _ in received.fulfill() }
            socket.connect()
            socket.emit("buffa", Data([106, 199, 95, 106, 199, 95]))
            wait(for: [received], timeout: 5)
            socket.disconnect()
        }
    }

    func testOriginalMixedJSONAndBinarySendPreservesEveryField() {
        for transport: SocketIOClientOption in [.forcePolling(true), .forceWebsockets(true)] {
            let socket = makeManager(transport).defaultSocket
            let received = expectation(description: "server validates mixed payload")
            socket.on("jsonbuff-ack") { _, _ in received.fulfill() }
            socket.connect()
            socket.emit("jsonbuff", ["hello": "lol", "message": Data([134, 140, 29]), "goodbye": "gotcha"] as [String: Any])
            wait(for: [received], timeout: 5)
            socket.disconnect()
        }
    }

    func testOpeningFailureEmitsConnectError() {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:9823")!,
                                config: [.connectTimeout(0.1)])
        let socket = manager.defaultSocket
        let failed = expectation(description: "connect_error on refused endpoint")
        socket.once(clientEvent: .connectError) { _, _ in
            socket.disconnect()
            failed.fulfill()
        }
        socket.connect()
        wait(for: [failed], timeout: 5)
    }

    // MARK: connection.ts — "should send events with ArrayBuffers in the correct order"

    func testBinaryEventsArriveInOrder() {
        let socket = makeManager().defaultSocket
        socket.connect()

        let acked = expectation(description: "abuff2-ack")
        socket.on("abuff2-ack") { _, _ in acked.fulfill() }
        socket.emit("abuff1", Data([105, 187, 159, 127]))
        socket.emit("abuff2", "please arrive second")
        wait(for: [acked], timeout: 5)
    }

    // MARK: connection.ts — "should stop trying to reconnect"

    func testStopTryingToReconnect() {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:9823")!,
                                config: [.log(false), .reconnectWait(1)])
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        var stopped = false
        socket.on(clientEvent: .reconnectAttempt) { _, _ in attempts += 1 }
        socket.on(clientEvent: .reconnectError) { _, _ in
            if !stopped {
                stopped = true
                self.manager.reconnects = false
            }
        }
        socket.connect()

        settle(4)

        XCTAssertTrue(stopped, "The reconnect attempt must actually fail before disabling retries")
        XCTAssertEqual(attempts, 1, "Disabling reconnection must stop the loop after the first attempt")
        XCTAssertNotEqual(socket.status, .connected)
    }

    // MARK: connection.ts — "should not try to reconnect with incorrect port when reconnection disabled"

    func testNoReconnectWhenDisabledWithIncorrectPort() {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:9823")!,
                                config: [.log(false), .reconnects(false), .reconnectWait(1)])
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        socket.on(clientEvent: .reconnectAttempt) { _, _ in attempts += 1 }

        let terminal = expectation(description: "terminal error or disconnect")
        terminal.assertForOverFulfill = false
        var terminalReason: String?
        var connectErrors = 0
        socket.on(clientEvent: .error) { data, _ in
            terminalReason = self.errorMessage(from: data)
            terminal.fulfill()
        }
        socket.on(clientEvent: .connectError) { data, _ in
            connectErrors += 1
            terminalReason = self.errorMessage(from: data)
            terminal.fulfill()
        }
        socket.on(clientEvent: .disconnect) { data, _ in
            terminalReason = self.errorMessage(from: data)
            terminal.fulfill()
        }
        socket.connect()
        wait(for: [terminal], timeout: 5)

        settle(3)

        XCTAssertEqual(attempts, 0, "Reconnect attempts must not fire when reconnection is disabled")
        XCTAssertGreaterThan(connectErrors, 0, "Opening failure must emit connect_error, not only disconnect")
        XCTAssertNotNil(terminalReason, "A terminal event must have arrived, or this proves nothing")
    }

    // MARK: connection.ts — "should try to reconnect twice and fail when requested two attempts with incorrect address and reconnect enabled"

    func testReconnectTwiceThenFailWithIncorrectAddress() {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:9823")!,
                                config: [.log(false), .reconnects(true), .reconnectAttempts(2), .reconnectWait(1)])
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        socket.on(clientEvent: .reconnectAttempt) { _, _ in attempts += 1 }

        let failed = expectation(description: "reconnect failed")
        failed.assertForOverFulfill = false
        // JS `reconnect_failed`; the Swift-only `.disconnect("Reconnect Failed")`
        // was removed in 17.0.0.
        socket.on(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }
        socket.connect()
        wait(for: [failed], timeout: 15)

        XCTAssertEqual(attempts, 2)
    }

    // MARK: connection.ts — "should close the engine upon decoding exception"

    /// Proves the engine is closed and re-opened on a decoding exception: after
    /// injecting bad data the socket reports `.disconnect("parse error")` — the
    /// reason JS emits on this path — and connects again with a different sid.
    func testParseErrorClosesEngineAndReconnectsWithFreshSession() {
        makeManager(.reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")
        connect(socket)
        let oldEngine = manager.engine
        let oldSid = socket.sid
        XCTAssertNotNil(oldSid)

        var sawReconnectSignal = false
        let signal = expectation(description: "reconnect signal")
        signal.assertForOverFulfill = false
        socket.on(clientEvent: .reconnect) { _, _ in
            sawReconnectSignal = true
            signal.fulfill()
        }
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            sawReconnectSignal = true
            signal.fulfill()
        }

        // JS `Manager.ondata` → `onclose("parse error")` → `Socket.onclose`.
        let parseErrorReported = expectation(description: "disconnect with parse error")
        parseErrorReported.assertForOverFulfill = false
        socket.on(clientEvent: .disconnect) { data, _ in
            if data.first as? String == "parse error" { parseErrorReported.fulfill() }
        }

        let reconnected = expectation(description: "reconnect")
        reconnected.assertForOverFulfill = false
        var newSid: String?
        var sawSignalBeforeReconnect = false
        socket.on(clientEvent: .connect) { _, _ in
            sawSignalBeforeReconnect = sawReconnectSignal
            newSid = socket.sid
            reconnected.fulfill()
        }

        // The entry point the engine calls with incoming data, i.e. the same
        // injection point as the JS test's `engine.emit("data", "bad")`.
        manager.parseEngineMessage("bad")

        wait(for: [parseErrorReported, signal, reconnected], timeout: 15)
        XCTAssertTrue(sawSignalBeforeReconnect, "A .reconnect or .reconnectAttempt must be observed before the second .connect")
        XCTAssertNotNil(newSid)
        XCTAssertFalse(manager.engine === oldEngine, "A parser failure retires the entire engine")
        oldEngine?.engineQueue.sync { XCTAssertTrue(oldEngine?.closed == true) }
        XCTAssertNotEqual(newSid, oldSid)
    }

    // MARK: socket.ts — "fire a connect_error event on open timeout (polling)"

    /// `.connectTimeout(0)` fails the attempt before the handshake can
    /// complete — the JS `timeout: 0` trick — so the namespace never matters.
    func testConnectErrorOnOpenTimeoutPolling() {
        let socket = makeManager(.connectTimeout(0), .forcePolling(true), .reconnects(false))
            .socket(forNamespace: "/")

        let failed = expectation(description: "connect error")
        failed.assertForOverFulfill = false
        var message: String?
        socket.on(clientEvent: .connectError) { data, _ in
            message = data.first as? String
            failed.fulfill()
        }
        socket.connect()
        wait(for: [failed], timeout: 5)

        XCTAssertEqual(message, "timeout")
    }

    // MARK: socket.ts — "fire a connect_error event on open timeout (websocket)"

    func testConnectErrorOnOpenTimeoutWebsocket() {
        let socket = makeManager(.connectTimeout(0), .forceWebsockets(true), .reconnects(false))
            .socket(forNamespace: "/")

        let failed = expectation(description: "connect error")
        failed.assertForOverFulfill = false
        var message: String?
        socket.on(clientEvent: .connectError) { data, _ in
            message = data.first as? String
            failed.fulfill()
        }
        socket.connect()
        wait(for: [failed], timeout: 5)

        XCTAssertEqual(message, "timeout")
    }

    // MARK: connection.ts — "should try to reconnect twice and fail when requested two attempts with immediate timeout and reconnect enabled"

    func testReconnectTwiceThenFailWithImmediateTimeout() {
        let manager = makeManager(.connectTimeout(0), .reconnectAttempts(2), .reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")

        var attempts = [Int]()
        socket.on(clientEvent: .reconnectAttempt) { data, _ in attempts.append(data.first as? Int ?? -1) }

        let failed = expectation(description: "reconnect failed")
        failed.assertForOverFulfill = false
        // JS `reconnect_failed`; the Swift-only `.disconnect("Reconnect Failed")`
        // was removed in 17.0.0.
        socket.on(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }
        socket.connect()
        wait(for: [failed], timeout: 15)

        XCTAssertEqual(attempts, [1, 2])
    }

    // MARK: connection.ts — "should attempt reconnects after a failed reconnect"

    /// Written exactly to the JS contract: after the first `reconnect_failed`
    /// a new `connect()` must get another full budget of 2 attempts. JS resets
    /// its attempt counter on `reconnect_failed`; if this client does not,
    /// this test fails — that is a FINDING, do not weaken the test.
    func testAttemptReconnectsAfterAFailedReconnect() {
        let manager = makeManager(.connectTimeout(0), .reconnectAttempts(2), .reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        socket.on(clientEvent: .reconnectAttempt) { _, _ in attempts += 1 }

        var failures = 0
        let secondFailed = expectation(description: "second reconnect failed")
        secondFailed.assertForOverFulfill = false
        socket.on(clientEvent: .reconnectFailed) { _, _ in
            failures += 1
            if failures == 1 {
                XCTAssertEqual(attempts, 2)
                socket.connect()
            } else if failures == 2 {
                secondFailed.fulfill()
            }
        }
        socket.connect()
        wait(for: [secondFailed], timeout: 15)
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(attempts, 4, "The second round must get a fresh budget of 2 attempts")
    }

    // MARK: connection.ts — "reconnect delay should increase every time"

    func testReconnectDelayIncreasesAcrossThreeRealTimeouts() {
        // The native option uses whole seconds. Keep the original 0.2 jitter
        // and three exponentially increasing intervals, scaled from 100 ms.
        let manager = makeManager(.connectTimeout(0), .reconnectAttempts(3),
                                  .reconnectWait(1), .randomizationFactor(0.2))
        let socket = manager.defaultSocket
        var started: UInt64?
        var delays = [Double]()
        var attemptNumbers = [Int]()
        socket.on(clientEvent: .connectError) { data, _ in
            XCTAssertEqual(data.first as? String, "timeout")
            started = DispatchTime.now().uptimeNanoseconds
        }
        socket.on(clientEvent: .reconnectAttempt) { data, _ in
            attemptNumbers.append(data.first as? Int ?? -1)
            guard let started else { return XCTFail("Retry must follow an opening timeout") }
            delays.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000)
        }
        let failed = expectation(description: "three attempts exhaust the reconnect budget")
        socket.once(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }
        socket.connect()
        wait(for: [failed], timeout: 15)
        XCTAssertEqual(attemptNumbers, [1, 2, 3])
        XCTAssertEqual(delays.count, 3)
        guard delays.count == 3 else { return }
        XCTAssertGreaterThan(delays[0], 0)
        XCTAssertGreaterThan(delays[1], delays[0])
        XCTAssertGreaterThan(delays[2], delays[1])
    }

    // MARK: connection.ts — "should not reconnect when force closed"

    func testNoReconnectWhenForceClosedDuringTimeout() {
        let manager = makeManager(.connectTimeout(0), .reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")

        var errors = 0
        var attempts = 0
        var closed = false
        socket.on(clientEvent: .connectError) { _, _ in
            errors += 1
            if !closed {
                closed = true
                socket.disconnect()
            }
        }
        socket.on(clientEvent: .reconnectAttempt) { _, _ in attempts += 1 }
        socket.connect()

        settle(2)

        XCTAssertGreaterThanOrEqual(errors, 1, "The timeout error must have fired, or this proves nothing")
        XCTAssertEqual(attempts, 0, "No reconnect attempt may fire after the socket was closed")
    }

    // MARK: connection.ts — "should stop reconnecting when force closed"

    func testStopReconnectingWhenForceClosed() {
        let manager = makeManager(.connectTimeout(0), .reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        var stopped = false
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            attempts += 1
            if !stopped {
                stopped = true
                socket.disconnect()
            }
        }
        socket.connect()

        settle(2.5)

        XCTAssertEqual(attempts, 1, "Closing the socket must stop the loop after the first attempt")
    }

    // MARK: connection.ts — "should reconnect after stopping reconnection"

    func testReconnectAfterStoppingReconnection() {
        let manager = makeManager(.connectTimeout(0), .reconnectAttempts(3), .reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        let attemptedAgain = expectation(description: "further reconnect attempt")
        attemptedAgain.assertForOverFulfill = false
        var restarted = false
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            attempts += 1
            if !restarted {
                restarted = true
                socket.disconnect()
                socket.connect()
            } else {
                attemptedAgain.fulfill()
            }
        }
        socket.connect()
        wait(for: [attemptedAgain], timeout: 10)

        XCTAssertGreaterThanOrEqual(attempts, 2, "Reconnecting after the stop must schedule further attempts")
    }

    // MARK: connection.ts — "should still try to reconnect twice after opening another socket asynchronously"

    func testReconnectTwiceAfterOpeningAnotherSocketAsynchronously() {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:9823")!,
                                config: [.log(false), .reconnects(true), .reconnectAttempts(2), .reconnectWait(1)])
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        var openedSecond = false
        socket.on(clientEvent: .reconnectAttempt) { _, _ in attempts += 1 }
        // Open the other namespace during the initial backoff, as in the
        // original test, rather than after the first retry has already begun.
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.1) {
            openedSecond = true
            self.manager.socket(forNamespace: "/asd").connect()
        }

        let failed = expectation(description: "reconnect failed")
        failed.assertForOverFulfill = false
        // JS `reconnect_failed`; the Swift-only `.disconnect("Reconnect Failed")`
        // was removed in 17.0.0.
        socket.on(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }
        socket.connect()
        wait(for: [failed], timeout: 15)

        XCTAssertTrue(openedSecond)
        XCTAssertEqual(attempts, 2, "Opening a second socket must not change the first socket's attempt budget")
    }

    // MARK: connection.ts — "should reopen a cached socket"

    /// With `autoConnect` on, asking for a namespace whose cached socket was
    /// disconnected re-connects it and hands back the same instance.
    func testReopenACachedSocket() {
        let manager = makeManager(.autoConnect(true))
        let socket = manager.defaultSocket
        let reconnected = expectation(description: "cached namespace reconnected")
        var connects = 0
        socket.on(clientEvent: .connect) { _, _ in
            connects += 1
            if connects == 1 { socket.disconnect() }
            if connects == 2 { reconnected.fulfill() }
        }
        socket.once(clientEvent: .disconnect) { _, _ in
            let again = manager.socket(forNamespace: "/")
            XCTAssertTrue(again === socket)
            XCTAssertTrue(again.active)
        }
        wait(for: [reconnected], timeout: 10)
        XCTAssertEqual(connects, 2)
    }

    // MARK: engine.io-client — Polling.uri() cache buster

    /// Every polling request has to carry a unique `t=` parameter so that
    /// intermediaries never serve a cached long-poll response, JS-aligned
    /// with `Polling.uri()` in engine.io-client. The fixture taps the HTTP
    /// layer because poll URLs never reach the packet layer.
    func testPollingRequestsCarryCacheBustingTimestamp() throws {
        connect(makeManager(.forcePolling(true)).socket(forNamespace: "/"))
        settle(0.5)

        let (status, body) = try server.admin("/admin/last-polling-query", method: "GET")
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let query = json?["query"] as? String
        XCTAssertNotNil(query, "The server must have seen at least one polling request")

        let items = URLComponents(string: "http://localhost/?\(query ?? "")")?.queryItems ?? []
        let t = items.first(where: { $0.name == "t" })?.value
        XCTAssertNotNil(t, "Polling requests must carry the t= cache buster (saw query: \(query ?? "nil"))")
        XCTAssertFalse(t?.isEmpty ?? true)
    }

    // MARK: original timeout scenarios (socket.ts)

    func testZeroTimeoutEchoCallsBackExactlyOnce() throws {
        let socket = makeManager().defaultSocket
        socket.connect()
        var callbacks = 0
        let timedOut = expectation(description: "zero timeout")
        socket.timeout(after: 0).emit("echo", 42) { error, _ in
            callbacks += 1
            XCTAssertEqual(error as? SocketAckError, .timeout)
            if callbacks == 1 { timedOut.fulfill() }
        }
        wait(for: [timedOut], timeout: 5)
        settle(0.2)
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)

        // Also test the stronger case with an established connection. A second
        // server ACK forms a wire-order barrier behind the expired echo ACK.
        if socket.status != .connected { connect(socket) }
        var connectedCallbacks = 0
        let expired = expectation(description: "connected zero timeout")
        socket.timeout(after: 0).emit("echo", 42) { error, _ in
            connectedCallbacks += 1
            XCTAssertEqual(error as? SocketAckError, .timeout)
            if connectedCallbacks == 1 { expired.fulfill() }
        }
        wait(for: [expired], timeout: 5)
        XCTAssertEqual(try serverSocketId(for: socket), socket.sid)
        XCTAssertEqual(connectedCallbacks, 1)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testCallbackEchoAcknowledgesTheOriginalIntegerBeforeTimeout() {
        let socket = makeManager().defaultSocket
        socket.connect()
        let acked = expectation(description: "original echo acknowledged")
        socket.timeout(after: 5).emit("echo", 42) { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? Int, 42)
            acked.fulfill()
        }
        wait(for: [acked], timeout: 6)
    }

    func testCallbackUnknownEventTimesOutAgainstTheRealServer() {
        let socket = makeManager().defaultSocket
        socket.connect()
        let timedOut = expectation(description: "unknown event times out")
        socket.timeout(after: 0.05).emit("unknown") { error, _ in
            XCTAssertEqual(error as? SocketAckError, .timeout)
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 5)
    }

    func testAsyncUnknownEventTimesOutAgainstTheRealServer() async {
        let socket = makeManager().defaultSocket
        socket.connect()
        do {
            _ = try await socket.timeout(after: 0.05).emitWithAck("unknown")
            XCTFail("An unacknowledged event must reject")
        } catch {
            XCTAssertEqual(error as? SocketAckError, .timeout)
        }
    }

    @MainActor
    func testAsyncTimedEchoRejectsWhenDisconnectedImmediatelyAfterSending() {
        let socket = connect(makeManager().defaultSocket)
        let rejected = expectation(description: "async ACK rejects on disconnect")
        var sent = false
        socket.addAnyOutgoingListener { event in
            guard event.event == "echo" else { return }
            sent = true
            // Registration has completed before outgoing listeners run. Queue
            // close directly behind the send, before a network ACK can return.
            self.manager.handleQueue.socketAsync { socket.disconnect() }
        }
        let task = Task { @MainActor in
            do {
                _ = try await socket.timeout(after: 10).emitWithAck("echo", "a")
                XCTFail("Disconnect must reject the pending async ACK")
            } catch {
                XCTAssertEqual(error as? SocketAckError, .disconnected)
            }
            rejected.fulfill()
        }
        defer { task.cancel() }
        wait(for: [rejected], timeout: 5)
        XCTAssertTrue(sent)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    // MARK: socket.ts — "should use the default timeout value"

    func testDefaultAckTimeoutApplies() {
        let socket = makeManager(.ackTimeout(0.05)).defaultSocket
        socket.connect()

        let timedOut = expectation(description: "default timeout fires")
        socket.emit("unknown", ack: { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            timedOut.fulfill()
        })
        wait(for: [timedOut], timeout: 5)
    }

    // MARK: socket.ts — "should ack with an error upon disconnection (callback & ackTimeout)"

    func testAckTimeoutFailsWithErrorOnDisconnect() {
        let socket = connect(makeManager(.ackTimeout(10)).socket(forNamespace: "/"))

        let disconnected = expectation(description: "ack fails on disconnect")
        socket.emit("never_ack", ack: { err, _ in
            XCTAssertEqual(err as? SocketAckError, .disconnected)
            disconnected.fulfill()
        })
        socket.disconnect()
        wait(for: [disconnected], timeout: 5)
    }

    // MARK: socket.ts — "should use the default timeout value" (positive round trip)

    /// The default must not break the happy path: a server ack still arrives
    /// as `(nil, data)`.
    func testEmitWithDefaultAckTimeoutRoundTrip() {
        let socket = connect(makeManager(.ackTimeout(5)).socket(forNamespace: "/"))

        let acked = expectation(description: "server ack")
        socket.emit("echo", "a", ack: { err, data in
            XCTAssertNil(err)
            XCTAssertEqual(data.first as? String, "a")
            acked.fulfill()
        })
        wait(for: [acked], timeout: 5)
    }

    // MARK: socket.ts > query option — "should accept an object (default namespace)"

    func testQueryOptionAcceptsAnObjectOnTheDefaultNamespace() throws {
        let socket = makeManager(.connectParams(["e": "f"])).socket(forNamespace: "/")
        socket.connect()

        XCTAssertEqual(try handshakeQuery(for: socket)["e"] as? String, "f")
    }

    // MARK: socket.ts > query option — "should accept a query string (default namespace)"

    /// JS reads the parameters out of the server URL
    /// (`opts.query = parsed.queryKey` in `lib/index.ts`).
    func testQueryOptionAcceptsAQueryStringOnTheDefaultNamespace() throws {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:\(server.port)/?c=d")!,
                                config: [.log(false)])
        let socket = manager.socket(forNamespace: "/")
        socket.connect()

        XCTAssertEqual(try handshakeQuery(for: socket)["c"] as? String, "d")
    }

    // MARK: socket.ts > query option — "should accept an object"

    /// The JS test puts the namespace in the URL (`io(BASE_URL + "/abc")`);
    /// here the namespace comes from `socket(forNamespace:)`, which is the only
    /// way this client selects one.
    func testQueryOptionAcceptsAnObjectOnACustomNamespace() {
        let socket = makeManager(.connectParams(["a": "b"])).socket(forNamespace: "/abc")

        XCTAssertEqual(handshakeEventQuery(for: socket)["a"] as? String, "b")
    }

    // MARK: socket.ts > query option — "should accept a query string"

    func testQueryOptionAcceptsAQueryStringOnACustomNamespace() {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:\(server.port)/?b=c&d=e")!,
                                config: [.log(false)])
        let socket = manager.socket(forNamespace: "/abc")

        let query = handshakeEventQuery(for: socket)
        XCTAssertEqual(query["b"] as? String, "c")
        XCTAssertEqual(query["d"] as? String, "e")
    }

    /// The default namespace answers `getHandshake` with its own handshake.
    private func handshakeQuery(for socket: SocketIOClient) throws -> [String: Any] {
        let replied = expectation(description: "handshake for \(socket.nsp)")
        var handshake: [String: Any]?
        socket.emitWithAck("getHandshake").timingOut(after: 5) { data in
            handshake = data.first as? [String: Any]
            replied.fulfill()
        }
        wait(for: [replied], timeout: 5)

        return try XCTUnwrap(handshake?["query"] as? [String: Any])
    }

    /// `/abc` pushes its handshake on connect, like `server.of("/abc")` in the
    /// JS support server.
    private func handshakeEventQuery(for socket: SocketIOClient) -> [String: Any] {
        let got = expectation(description: "handshake event for \(socket.nsp)")
        got.assertForOverFulfill = false
        var handshake: [String: Any]?
        socket.on("handshake") { data, _ in
            handshake = data.first as? [String: Any]
            got.fulfill()
        }
        socket.connect()
        wait(for: [got], timeout: 5)

        return (handshake?["query"] as? [String: Any]) ?? [:]
    }

    // MARK: connection.ts — "should emit date as string"

    func testEmitDateAsString() {
        let socket = makeManager().socket(forNamespace: "/")

        let took = expectation(description: "takeDate")
        took.assertForOverFulfill = false
        var received: Any?
        socket.on("takeDate") { data, _ in
            received = data.first
            took.fulfill()
        }
        socket.emit("getDate")
        socket.connect()
        wait(for: [took], timeout: 5)

        XCTAssertTrue(received is String, "A Date crosses the wire as a string, got \(String(describing: received))")
    }

    // MARK: connection.ts — "should emit date in object"

    func testEmitDateInObject() {
        let socket = makeManager().socket(forNamespace: "/")

        let took = expectation(description: "takeDateObj")
        took.assertForOverFulfill = false
        var received: [String: Any]?
        socket.on("takeDateObj") { data, _ in
            received = data.first as? [String: Any]
            took.fulfill()
        }
        socket.emit("getDateObj")
        socket.connect()
        wait(for: [took], timeout: 5)

        XCTAssertNotNil(received)
        XCTAssertTrue(received?["date"] is String)
    }

    // MARK: connection.ts — "should receive date with ack"

    func testReceiveDateWithAck() {
        let socket = makeManager().socket(forNamespace: "/")

        let acked = expectation(description: "getAckDate")
        var received: Any?
        socket.emitWithAck("getAckDate", ["test": true]).timingOut(after: 5) { data in
            XCTAssertNotEqual(data.first as? String, SocketAckStatus.noAck.rawValue)
            received = data.first
            acked.fulfill()
        }
        socket.connect()
        wait(for: [acked], timeout: 5)

        XCTAssertTrue(received is String)
    }

    /// The outgoing direction of the same rule: a `Date` this client emits
    /// arrives as the ISO-8601 string `JSON.stringify` produces.
    func testEmittedDateArrivesAsAnISO8601String() {
        let socket = makeManager().socket(forNamespace: "/")
        connect(socket)

        let date = Date(timeIntervalSince1970: 1_704_164_645.678)
        let acked = expectation(description: "echo")
        var received: Any?
        socket.emitWithAck("echo", date).timingOut(after: 5) { data in
            received = data.first
            acked.fulfill()
        }
        wait(for: [acked], timeout: 5)

        XCTAssertEqual(received as? String, "2024-01-02T03:04:05.678Z")
    }

    // MARK: socket.ts — "should emit an event and wait for the acknowledgement"

    func testEmitWithAckAwaitsTheAcknowledgement() async throws {
        let socket = makeManager().socket(forNamespace: "/")
        socket.connect()

        let value = try await socket.emitWithAck("echo", 123)

        XCTAssertEqual(value.first as? Int, 123)
    }

    // MARK: socket.ts > timeout — "should not timeout when the server does acknowledge the event (promise)"

    func testTimedEmitWithAckDoesNotTimeOutWhenTheServerAcknowledges() async throws {
        let socket = makeManager().socket(forNamespace: "/")
        socket.connect()

        let value = try await socket.timeout(after: 5).emitWithAck("echo", 42)

        XCTAssertEqual(value.first as? Int, 42)
    }

    // MARK: socket.ts > acknowledgement upon disconnection — on a retried drop

    /// The JS scenarios "should ack with an error upon disconnection
    /// (callback & timeout / ackTimeout)" disconnect manually, but JS
    /// `Socket.onclose` runs `_clearAcks()` on *every* close, so a transport
    /// drop that the manager retries settles the pending acknowledgement the
    /// same way. `never_ack` guarantees the server never answers, so the only
    /// thing that can settle it is the close. The timeout is far longer than
    /// the test budget, so a `.timeout` here would be a different bug.
    func testPendingAckFailsWhenTheTransportIsKilledAndTheSocketReconnects() throws {
        let socket = connect(makeManager(.ackTimeout(60), .reconnectWait(1)).socket(forNamespace: "/"))
        let sid = try XCTUnwrap(socket.sid)

        let settled = expectation(description: "pending ack settles on the retried drop")
        socket.emit("never_ack", ack: { err, _ in
            XCTAssertEqual(err as? SocketAckError, .disconnected)
            settled.fulfill()
        })
        // A round trip on the same session proves the emit reached the server
        // before the transport is killed.
        XCTAssertEqual(try serverSocketId(for: socket), sid)

        let reconnected = expectation(description: "namespace re-joined")
        reconnected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in reconnected.fulfill() }

        try killTransport(ofSocketWithId: sid)
        wait(for: [settled, reconnected], timeout: 20)

        XCTAssertEqual(socket.status, .connected)
        XCTAssertTrue(socket.active)
    }
}

extension JSParityE2ETest {
    func testOriginalServerRequestedAcknowledgementReceivesBothArguments() {
        let socket = makeManager().defaultSocket
        let done = expectation(description: "server validates both ack arguments")
        socket.on("parity-server-ack") { _, ack in ack.with(5, ["test": true]) }
        socket.on("parity-ack-result") { data, _ in
            XCTAssertEqual(data.first as? Bool, true)
            done.fulfill()
        }
        socket.emit("parity-request-ack")
        socket.connect()
        wait(for: [done], timeout: 5)
    }

    func testOriginalUTF8ServerEventsPreserveAllFiveValuesAndOrder() {
        let socket = makeManager().defaultSocket
        let expected = ["てすと", "Я Б Г Д Ж Й", "Ä ä Ü ü ß", "utf8 — string", "utf8 — string"]
        var values: [String] = []
        let received = expectation(description: "all original UTF8 events")
        received.expectedFulfillmentCount = expected.count
        socket.on("parity-utf8") { data, _ in
            values.append(data.first as? String ?? "missing")
            received.fulfill()
        }
        socket.emit("parity-get-utf8")
        socket.connect()
        wait(for: [received], timeout: 5)
        XCTAssertEqual(values, expected)
    }

    func testBinaryAndNestedBinarySurviveTheActualSocketIOConnection() {
        let socket = connect(makeManager().defaultSocket)
        let bytes = Data([0, 1, 2, 3, 255])
        let direct = expectation(description: "binary bytes")
        socket.emit("parity-binary", bytes, ack: { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? Data, bytes)
            direct.fulfill()
        })
        let nested = expectation(description: "binary in object")
        socket.emit("parity-binary", ["hello": "lol", "message": bytes, "goodbye": "gotcha"] as [String: Any], ack: { error, data in
            XCTAssertNil(error)
            let object = data.first as? [String: Any]
            XCTAssertEqual(object?["message"] as? Data, bytes)
            XCTAssertEqual(object?["hello"] as? String, "lol")
            XCTAssertEqual(object?["goodbye"] as? String, "gotcha")
            nested.fulfill()
        })
        wait(for: [direct, nested], timeout: 5)
    }

    func testAuthObjectAndCallbackReachAuthWithoutLeakingIntoQuery() {
        for callback in [false, true] {
            let socket = makeManager().socket(forNamespace: "/abc")
            let received = expectation(description: "auth stays out of query")
            let auth = callback ? ["e": "f"] : ["a": "b", "c": "d"]
            socket.on("handshake") { data, _ in
                let handshake = data.first as? [String: Any]
                XCTAssertEqual(handshake?["auth"] as? [String: String], auth)
                let query = handshake?["query"] as? [String: Any]
                for key in auth.keys { XCTAssertNil(query?[key]) }
                received.fulfill()
            }
            if callback {
                socket.setAuth { complete in complete(auth) }
                socket.connect()
            } else {
                socket.connect(withPayload: auth)
            }
            wait(for: [received], timeout: 5)
            socket.disconnect()
        }
    }
}

extension JSParityE2ETest {
    func testOriginalLocalhostConnectionDeliversAPreconnectEmit() {
        let socket = makeManager().defaultSocket
        let received = expectation(description: "original hi event returned")
        socket.on("hi") { _, _ in received.fulfill() }
        socket.emit("hi")
        socket.connect()
        wait(for: [received], timeout: 5)
        socket.disconnect()
    }

    func testExplicitAutoConnectFalseDoesNotCreateAnEngine() {
        let manager = makeManager(.autoConnect(false))
        XCTAssertNil(manager.engine)
        XCTAssertFalse(manager.defaultSocket.active)
        manager.defaultSocket.disconnect()
    }

    func testDifferentNamespacesShareTheExplicitManager() {
        let manager = makeManager()
        let foo = manager.socket(forNamespace: "/foo")
        let bar = manager.socket(forNamespace: "/bar")
        XCTAssertTrue(foo.manager === bar.manager)
        XCTAssertTrue(foo.manager === manager)
        foo.disconnect()
        bar.disconnect()
    }

    func testNamespaceCanJoinFromAnotherNamespacesConnectCallback() {
        let manager = makeManager()
        let root = manager.defaultSocket
        let done = expectation(description: "namespace joins reentrantly")
        root.once(clientEvent: .connect) { _, _ in
            let foo = manager.socket(forNamespace: "/foo")
            foo.once(clientEvent: .connect) { _, _ in
                XCTAssertEqual(root.status, .connected)
                foo.disconnect()
                root.disconnect()
                done.fulfill()
            }
            foo.connect()
        }
        root.connect()
        wait(for: [done], timeout: 5)
    }

    func testNamespaceCanJoinFromAnotherNamespacesDisconnectCallback() {
        let manager = makeManager()
        let root = manager.defaultSocket
        let done = expectation(description: "new namespace joins from disconnect")
        root.once(clientEvent: .connect) { _, _ in root.disconnect() }
        root.once(clientEvent: .disconnect) { _, _ in
            let foo = manager.socket(forNamespace: "/foo")
            foo.once(clientEvent: .connect) { _, _ in
                foo.disconnect()
                done.fulfill()
            }
            foo.connect()
        }
        root.connect()
        wait(for: [done], timeout: 5)
    }

    func testManualReconnectInsideTheDisconnectCallback() {
        let socket = makeManager().defaultSocket
        let done = expectation(description: "manual reconnect from callback")
        var connects = 0
        socket.on(clientEvent: .connect) { _, _ in
            connects += 1
            socket.disconnect()
            if connects == 2 { done.fulfill() }
        }
        socket.once(clientEvent: .disconnect) { _, _ in socket.connect() }
        socket.connect()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(connects, 2)
    }
}

extension JSParityE2ETest {
    func testPreconnectVolatileAckIsDroppedButReliableAckCompletes() {
        let socket = makeManager(.autoConnect(false)).defaultSocket
        let received = expectation(description: "reliable server ID")
        var volatileReplies = 0
        socket.volatile.emit("server-socket-id", ack: { _, _ in volatileReplies += 1 })
        socket.emit("server-socket-id", ack: { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? String, socket.sid)
            received.fulfill()
        })
        socket.connect()
        wait(for: [received], timeout: 5)
        XCTAssertEqual(volatileReplies, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testVolatileAckEventuallySucceedsOnTheRealWritableTransport() {
        let socket = makeManager().defaultSocket
        let received = expectation(description: "volatile server ID")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var settled = false
        let tick = SocketUncheckedSendableBox({
            guard !settled else { return }
            socket.volatile.emit("server-socket-id", ack: { error, data in
                XCTAssertNil(error)
                XCTAssertEqual(data.first as? String, socket.sid)
                if !settled {
                    settled = true
                    timer.cancel()
                    received.fulfill()
                }
            })
        })
        timer.setEventHandler { tick.value() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.resume()
        defer { timer.cancel() }
        socket.connect()
        wait(for: [received], timeout: 5)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }
}

extension JSParityE2ETest {
    func testOriginalIncomingCatchAllPayloadPrependOrderAndRemoval() {
        let socket = makeManager().socket(forNamespace: "/abc")
        let removed = socket.addAnyListener { _ in XCTFail("Removed listener fired") }
        socket.removeAnyListener(id: removed)
        XCTAssertEqual(socket.anyListenerCount, 0)
        let received = expectation(description: "handshake through catch-all")
        var order: [Int] = []
        socket.addAnyListener { event in
            order.append(2)
            XCTAssertEqual(event.event, "handshake")
            XCTAssertNotNil(event.items?.first as? [String: Any])
            XCTAssertEqual(order, [0, 1, 2])
            received.fulfill()
        }
        socket.prependAnyListener { _ in order.append(1) }
        socket.prependAnyListener { _ in order.append(0) }
        socket.connect()
        wait(for: [received], timeout: 5)
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testOriginalOutgoingCatchAllPayloadAndPrependOrder() {
        for emitBeforeConnect in [false, true] {
            let socket = makeManager().socket(forNamespace: "/abc")
            let sent = expectation(description: "outgoing catch-all")
            var order: [Int] = []
            socket.addAnyOutgoingListener { event in
                order.append(2)
                XCTAssertEqual(event.event, "my-event")
                XCTAssertEqual(event.items?.first as? String, "123")
                XCTAssertEqual(order, [0, 1, 2])
                sent.fulfill()
            }
            socket.prependAnyOutgoingListener { _ in order.append(1) }
            socket.prependAnyOutgoingListener { _ in order.append(0) }
            if emitBeforeConnect {
                socket.emit("my-event", "123")
                XCTAssertTrue(order.isEmpty)
            } else {
                socket.once(clientEvent: .connect) { _, _ in socket.emit("my-event", "123") }
            }
            socket.connect()
            wait(for: [sent], timeout: 5)
            socket.disconnect()
        }
    }
}

private final class ParityCloseObservingManager: SocketManager {
    var onEngineClose: ((String) -> Void)?
    override func engineDidClose(reason: String) {
        super.engineDidClose(reason: reason)
        onEngineClose?(reason)
    }
}


extension JSParityE2ETest {
    func testManagerURLPathConnectsToNamespaceAndRetainsQuery() {
        manager = SocketManager(socketURL: URL(string: serverURL.absoluteString + "/abc?token=from-url")!,
                                config: [.autoConnect(false), .reconnects(false)])
        let socket = manager.defaultSocket
        let query = handshakeEventQuery(for: socket)
        XCTAssertEqual(socket.nsp, "/abc")
        XCTAssertEqual(socket.status, .connected)
        XCTAssertTrue(socket === manager.socket(forNamespace: "/abc"))
        XCTAssertEqual(query["token"] as? String, "from-url")
    }
}
