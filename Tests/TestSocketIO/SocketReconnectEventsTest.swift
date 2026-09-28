//
//  SocketReconnectEventsTest.swift
//  Socket.IO-Client-Swift
//
//  Round 2 of the JavaScript-parity port: the manager reconnect event stream of
//  `socket.io-client/lib/manager.ts` (`reconnect_attempt`, `reconnect_error`,
//  `reconnect_failed`, `reconnect`) and `Socket.onclose` in
//  `socket.io-client/lib/socket.ts`.
//
//  Unit tests only: `ReconnectTestEngine` decides per attempt whether the
//  handshake succeeds, so no server and no wall-clock backoff are needed
//  (`.reconnectWait(0)` makes `reconnectInterval` return 0).
//

import XCTest
@testable import SocketIO

final class SocketReconnectEventsTest: XCTestCase {
    private var manager: SocketManager!
    private var engine: ReconnectTestEngine!

    override func tearDown() {
        manager?.defaultSocket.removeAllAnyOutgoingListeners()
        manager?.defaultSocket.removeAllHandlers()
        manager?.disconnect()
        manager = nil
        engine = nil
        super.tearDown()
    }

    /// Builds a manager whose transport is the fake engine. `alwaysFail` makes
    /// every handshake fail with `failureReason`; otherwise the engine opens on
    /// every attempt unless a test arms `engine.failuresRemaining`.
    /// `.reconnectWait(0)` makes `reconnectInterval` return 0, so the loop runs
    /// at queue speed instead of wall-clock backoff.
    @discardableResult
    private func makeManager(alwaysFail: Bool = false,
                             failureReason: String = "transport close",
                             _ options: SocketIOClientOption...) -> SocketManager {
        var config: SocketIOClientConfiguration = [.log(false), .reconnects(true), .reconnectWait(0)]
        for option in options {
            config.insert(option)
        }

        manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: config)
        engine = ReconnectTestEngine(client: manager, url: manager.socketURL, options: nil)
        engine.alwaysFail = alwaysFail
        engine.failureReason = failureReason
        manager.engine = engine

        return manager
    }

    /// Connects `socket` through the fake engine and waits for the first
    /// `.connect`, so the tests below start from an established session.
    private func connect(_ socket: SocketIOClient) {
        let connected = expectation(description: "initial connect")
        connected.assertForOverFulfill = false
        let id = socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)
        socket.off(id: id)
    }

    // MARK: connection.ts — "should fire reconnect_* events on manager"

    /// Swift has no manager-level event bus, so the manager's events are
    /// emitted on every socket subscribed to it — JS `Socket.subEvents()` runs
    /// in `connect()`, so both sockets connect here. A socket that never called
    /// `connect()` (or that called `disconnect()`) hears nothing, as in JS.
    func testFiresReconnectEventsOnEverySocketOfTheManager() {
        let manager = makeManager(alwaysFail: true, .reconnectAttempts(2))
        let socket = manager.socket(forNamespace: "/")
        let other = manager.socket(forNamespace: "/asd")

        var attempts = [Int]()
        var otherAttempts = [Int]()
        socket.on(clientEvent: .reconnectAttempt) { data, _ in attempts.append(data.first as? Int ?? -1) }
        other.on(clientEvent: .reconnectAttempt) { data, _ in otherAttempts.append(data.first as? Int ?? -1) }

        let failed = expectation(description: "reconnect_failed")
        failed.assertForOverFulfill = false
        socket.on(clientEvent: .reconnectFailed) { data, _ in
            XCTAssertTrue(data.isEmpty, "JS `reconnect_failed` carries no payload")
            failed.fulfill()
        }
        let otherFailed = expectation(description: "reconnect_failed on the second namespace")
        otherFailed.assertForOverFulfill = false
        other.on(clientEvent: .reconnectFailed) { _, _ in otherFailed.fulfill() }

        socket.connect()
        other.connect()

        wait(for: [failed, otherFailed], timeout: 10)

        XCTAssertEqual(attempts, [1, 2], "JS emits reconnect_attempt with the 1-based attempt number")
        XCTAssertEqual(otherAttempts, [1, 2])
    }

    // MARK: connection.ts — "should fire reconnecting (on manager) with attempts number when reconnecting twice"

    func testFiresReconnectAttemptWithTheAttemptsNumberWhenReconnectingTwice() {
        let manager = makeManager(alwaysFail: true, .reconnectAttempts(2))
        let socket = manager.socket(forNamespace: "/")

        var reconnects = 0
        var everyAttemptMatchedItsIndex = true
        socket.on(clientEvent: .reconnectAttempt) { data, _ in
            reconnects += 1
            if data.first as? Int != reconnects { everyAttemptMatchedItsIndex = false }
        }

        let failed = expectation(description: "reconnect_failed")
        failed.assertForOverFulfill = false
        socket.on(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }

        socket.connect()

        wait(for: [failed], timeout: 10)

        XCTAssertEqual(reconnects, 2)
        XCTAssertTrue(everyAttemptMatchedItsIndex, "JS passes `backoff.attempts`, i.e. the running attempt number")
    }

    // MARK: manager.ts — `reconnect_error` in the `open(fn)` error callback

    func testEveryFailedAttemptFiresReconnectErrorWithTheReason() {
        let manager = makeManager(alwaysFail: true, failureReason: "transport error", .reconnectAttempts(2))
        let socket = manager.socket(forNamespace: "/")

        var errors = [String]()
        socket.on(clientEvent: .reconnectError) { data, _ in errors.append(data.first as? String ?? "") }

        let failed = expectation(description: "reconnect_failed")
        failed.assertForOverFulfill = false
        socket.on(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }

        socket.connect()

        wait(for: [failed], timeout: 10)

        XCTAssertEqual(errors, ["transport error", "transport error"],
                       "Each failed attempt reports its reason, like JS `reconnect_error(err)`")
    }

    // MARK: connection.ts — "should reconnect by default" / manager.ts `onreconnect`

    /// JS `onreconnect()` emits `reconnect` with `backoff.attempts`, and only on
    /// success. The socket's own `connect` follows the server's CONNECT ack.
    func testReconnectFiresOnSuccessWithTheAttemptNumberBeforeConnect() {
        let manager = makeManager()
        let socket = manager.socket(forNamespace: "/")
        connect(socket)

        var order = [String]()
        var successfulAttempt: Int?
        socket.on(clientEvent: .reconnect) { data, _ in
            successfulAttempt = data.first as? Int
            order.append("reconnect")
        }

        let reconnected = expectation(description: "connect after reconnect")
        reconnected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in
            order.append("connect")
            reconnected.fulfill()
        }

        // A transport drop with reconnection enabled: the first retry fails,
        // the second opens the transport.
        engine.failuresRemaining = 1
        manager.engineDidClose(reason: "transport close")

        wait(for: [reconnected], timeout: 10)

        XCTAssertEqual(successfulAttempt, 2, "The second attempt is the one that opened the transport")
        XCTAssertEqual(order, ["reconnect", "connect"], "JS emits `reconnect` before the namespaces re-join")
    }

    // MARK: socket.ts — `Socket.onclose`: the drop reports the real reason

    /// JS `Manager.onclose(reason)` → `Socket.onclose(reason)` emits `disconnect`
    /// with the real reason on every close, including one that is about to be
    /// retried. Before 17.0.0 this fork emitted `.reconnect(reason)` instead.
    func testTransportDropReportsTheRealReasonAsDisconnect() {
        let manager = makeManager()
        let socket = manager.socket(forNamespace: "/")
        connect(socket)

        let dropped = expectation(description: "disconnect with the drop reason")
        dropped.assertForOverFulfill = false
        var reason: String?
        socket.on(clientEvent: .disconnect) { data, _ in
            reason = data.first as? String
            dropped.fulfill()
        }

        manager.engineDidClose(reason: "ping timeout")

        wait(for: [dropped], timeout: 5)

        XCTAssertEqual(reason, "ping timeout")
        XCTAssertTrue(socket.sid?.isEmpty ?? true, "JS `Socket.onclose` does `delete this.id`")
        XCTAssertTrue(socket.active, "The socket stays subscribed, so the manager re-joins its namespace")
    }

    // MARK: manager.ts — exhaustion emits `reconnect_failed`, never a second `disconnect`

    func testExhaustedBudgetEmitsReconnectFailedWithoutASecondDisconnect() {
        let manager = makeManager(.reconnectAttempts(2))
        let socket = manager.socket(forNamespace: "/")
        connect(socket)

        var disconnectReasons = [String]()
        socket.on(clientEvent: .disconnect) { data, _ in disconnectReasons.append(data.first as? String ?? "") }

        let failed = expectation(description: "reconnect_failed")
        failed.assertForOverFulfill = false
        socket.on(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }

        engine.alwaysFail = true
        manager.engineDidClose(reason: "transport close")

        wait(for: [failed], timeout: 10)

        XCTAssertEqual(disconnectReasons, ["transport close"],
                       "Only the real drop reports `disconnect`; the Swift-only \"Reconnect Failed\" reason is gone")
        XCTAssertNotEqual(socket.status, .connecting,
                          "A socket nothing will re-join must not stay parked in .connecting")
    }

    // MARK: connection.ts — "should not try to reconnect and should form a connection when connecting to correct port with default timeout"

    func testNoReconnectEventsWhenTheFirstConnectSucceeds() {
        let manager = makeManager()
        let socket = manager.socket(forNamespace: "/")

        let unexpected = expectation(description: "no reconnect event")
        unexpected.isInverted = true
        socket.on(clientEvent: .reconnectAttempt) { _, _ in unexpected.fulfill() }
        socket.on(clientEvent: .reconnect) { _, _ in unexpected.fulfill() }
        socket.on(clientEvent: .reconnectError) { _, _ in unexpected.fulfill() }
        socket.on(clientEvent: .reconnectFailed) { _, _ in unexpected.fulfill() }

        connect(socket)

        wait(for: [unexpected], timeout: 1)
        XCTAssertEqual(socket.status, .connected)
    }

    // MARK: manager.ts `reconnect()` — the attempt runs after `backoff.duration()`

    /// JS waits for the backoff before `reconnect_attempt` and `open()`. The
    /// client used to open immediately and only space the *next* attempt, which
    /// turned a drop right after every handshake into a tight loop.
    func testReconnectAttemptWaitsForTheBackoffDelay() {
        let manager = makeManager(alwaysFail: true, .reconnectWait(1), .reconnectAttempts(1))
        let socket = manager.socket(forNamespace: "/")

        let attempted = expectation(description: "reconnect_attempt after the delay")
        attempted.assertForOverFulfill = false
        var attemptedAt: Date?
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            attemptedAt = Date()
            attempted.fulfill()
        }

        let startedAt = Date()
        socket.connect()

        wait(for: [attempted], timeout: 5)
        let delay = attemptedAt!.timeIntervalSince(startedAt)
        XCTAssertGreaterThanOrEqual(delay, 0.5, "1 s base minus the maximum 50 % jitter")
        XCTAssertLessThanOrEqual(delay, 2.5, "1 s base plus the maximum 50 % jitter, plus scheduling slack")
    }

    // MARK: manager.ts `_close()` — `skipReconnect` cancels a pending attempt

    func testManagerDisconnectCancelsAScheduledReconnectAttempt() {
        let manager = makeManager(alwaysFail: true, .reconnectWait(1))
        let socket = manager.socket(forNamespace: "/")

        let unexpected = expectation(description: "no reconnect attempt after disconnect()")
        unexpected.isInverted = true
        socket.on(clientEvent: .reconnectAttempt) { _, _ in unexpected.fulfill() }

        socket.connect()          // fails, schedules attempt 1 in ~1 s
        manager.disconnect()      // JS `_close()`: skipReconnect

        wait(for: [unexpected], timeout: 2)
        XCTAssertEqual(manager.status, .disconnected)
    }

    // MARK: connection.ts — "should stop reconnecting when force closed" (manager.ts `_destroy`)

    /// Disconnecting the last active socket closes the manager, which ends the
    /// reconnect loop. The loop used to keep running with nothing to re-join.
    func testDisconnectingTheLastActiveSocketStopsTheReconnectLoop() {
        let manager = makeManager(alwaysFail: true)
        let socket = manager.socket(forNamespace: "/")

        var attempts = 0
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            attempts += 1
            if attempts == 1 { socket.disconnect() }
        }

        socket.connect()

        let settled = expectation(description: "settled")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(attempts, 1, "Closing the last socket must stop the loop after the first attempt")
        XCTAssertEqual(manager.status, .disconnected)
        XCTAssertFalse(socket.active)
    }

    /// The counterpart: another active socket keeps the manager, and its loop, alive.
    func testDisconnectingOneSocketKeepsReconnectingForAnotherActiveOne() {
        let manager = makeManager(.reconnectAttempts(2))
        let socket = manager.socket(forNamespace: "/")
        let other = manager.socket(forNamespace: "/other")
        connect(socket)
        connect(other)

        var attempts = 0
        var otherAttempts = [Int]()
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            attempts += 1
            if attempts == 1 { socket.disconnect() }
        }
        other.on(clientEvent: .reconnectAttempt) { data, _ in otherAttempts.append(data.first as? Int ?? -1) }
        let failed = expectation(description: "reconnect_failed on the surviving socket")
        failed.assertForOverFulfill = false
        other.on(clientEvent: .reconnectFailed) { _, _ in failed.fulfill() }

        engine.alwaysFail = true
        manager.engineDidClose(reason: "transport close")

        wait(for: [failed], timeout: 10)
        XCTAssertEqual(otherAttempts, [1, 2], "The surviving socket must see the whole budget")
        XCTAssertEqual(attempts, 1)
        XCTAssertNotEqual(manager.status, .disconnected)
    }

    // MARK: connection.ts — "should attempt reconnects after a failed reconnect"

    /// The JS test re-`connect()`s from the `reconnect_failed` handler and
    /// expects a fresh budget of attempts. This pins that the exhaustion path
    /// does not undo a socket the handler just reconnected.
    func testANewCycleStartedFromTheReconnectFailedHandlerGetsAFreshBudget() {
        let manager = makeManager(alwaysFail: true, .reconnectAttempts(2))
        let socket = manager.socket(forNamespace: "/")

        var attempts = [Int]()
        socket.on(clientEvent: .reconnectAttempt) { data, _ in attempts.append(data.first as? Int ?? -1) }

        var failures = 0
        let secondFailed = expectation(description: "second reconnect_failed")
        secondFailed.assertForOverFulfill = false
        socket.on(clientEvent: .reconnectFailed) { _, _ in
            failures += 1
            if failures == 1 {
                socket.connect()
            } else if failures == 2 {
                secondFailed.fulfill()
            }
        }

        socket.connect()

        wait(for: [secondFailed], timeout: 15)

        XCTAssertEqual(attempts, [1, 2, 1, 2], "Each cycle counts its attempts from 1 again")
    }
}

/// Test-only `SocketEngineSpec` that decides per `connect()` whether the
/// handshake succeeds, and answers a CONNECT frame the way a server would.
/// Same stored-property shape as the other in-repo fakes.
private final class ReconnectTestEngine: SocketEngineSpec {
    weak var client: SocketEngineClient?
    private(set) var closed = false
    private(set) var connected = false
    var connectParams: [String: Any]? = nil
    private(set) var cookies: [HTTPCookie]? = nil
    private(set) var engineQueue = DispatchQueue.main
    var extraHeaders: [String: String]? = nil
    private(set) var fastUpgrade = false
    private(set) var forcePolling = false
    private(set) var forceWebsockets = false
    private(set) var polling = false
    private(set) var probing = false
    private(set) var sid = ""
    private(set) var socketPath = ""
    private(set) var urlPolling = URL(string: "http://localhost/")!
    private(set) var urlWebSocket = URL(string: "http://localhost/")!


    /// Fails every handshake while `true`.
    var alwaysFail = false
    /// Number of upcoming handshakes that fail before the engine opens again.
    var failuresRemaining = 0
    var failureReason = "transport close"
    private(set) var connectAttempts = 0
    private(set) var written = [String]()

    required init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.client = client
    }

    func connect() {
        connectAttempts += 1

        guard !alwaysFail, failuresRemaining == 0 else {
            if failuresRemaining > 0 { failuresRemaining -= 1 }
            client?.engineDidClose(reason: failureReason)
            return
        }

        client?.engineDidOpen(reason: "Connect")
    }

    func didError(reason: String) { }

    func disconnect(reason: String) {
        client?.engineDidClose(reason: reason)
    }

    func doFastUpgrade() { }
    func flushWaitingForPostToWebSocket() { }
    func parseEngineData(_ data: Data) { }
    func parseEngineMessage(_ message: String) { }

    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) {
        written.append(msg)
        completion?()

        // Answer a `0<nsp>,<payload>` CONNECT the way the server does, so the
        // namespace reaches `.connected` and emits `.connect`.
        guard msg.hasPrefix("0"), let comma = msg.firstIndex(of: ",") else { return }

        let nsp = String(msg[msg.index(after: msg.startIndex)..<comma])
        client?.parseEngineMessage("0\(nsp),{\"sid\":\"sid-\(connectAttempts)\"}")
    }
}

// Follow-up: drive the actual manager automatic-reconnect route, not a direct
// call to didDisconnect(). The fake controls only the network handshake.
extension SocketReconnectEventsTest {
    func testAutomaticReconnectFailsSentTimedAckBeforeReconnectAttempt() {
        let manager = makeManager()
        let socket = manager.defaultSocket
        connect(socket)
        var order: [String] = []
        socket.on(clientEvent: .disconnect) { _, _ in order.append("disconnect") }
        socket.timeout(after: 60).emit("never_ack") { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            order.append("ack")
        }
        let reconnected = expectation(description: "reconnected")
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            order.append("attempt")
        }
        socket.once(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        manager.engineDidClose(reason: "transport close")
        wait(for: [reconnected], timeout: 5)
        XCTAssertEqual(order, ["disconnect", "ack", "attempt"])
    }

    func testAutomaticReconnectFailsAckTimeoutAckAndIgnoresLateReply() {
        let manager = makeManager(.ackTimeout(60))
        let socket = manager.defaultSocket
        connect(socket)
        var calls = 0
        socket.emit("never_ack", ack: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected); calls += 1
        })
        let oldID = socket.currentAck
        let reconnected = expectation(description: "reconnected")
        socket.once(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        manager.engineDidClose(reason: "ping timeout")
        wait(for: [reconnected], timeout: 5)
        XCTAssertEqual(calls, 1)
        socket.handleAck(oldID, data: ["late"])
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testAutomaticReconnectSilentlyRemovesSentNoTimeoutCallbackAck() {
        let manager = makeManager()
        let socket = manager.defaultSocket
        connect(socket)
        var calls = 0
        socket.emit("never_ack", ack: { _, _ in calls += 1 })
        let oldID = socket.currentAck
        let reconnected = expectation(description: "reconnected")
        socket.once(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        manager.engineDidClose(reason: "transport close")
        wait(for: [reconnected], timeout: 5)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        socket.handleAck(oldID, data: [])
        XCTAssertEqual(calls, 0)
    }

    func testAutomaticReconnectKeepsAckBufferedByDisconnectListener() {
        let manager = makeManager()
        let socket = manager.defaultSocket
        connect(socket)
        var bufferedID: Int?
        var replies = 0
        socket.once(clientEvent: .disconnect) { _, _ in
            socket.timeout(after: 60).emit("buffered") { error, data in
                XCTAssertNil(error)
                XCTAssertEqual(data.first as? String, "ok")
                replies += 1
            }
            bufferedID = socket.currentAck
        }
        let reconnected = expectation(description: "reconnected")
        socket.once(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        manager.engineDidClose(reason: "transport close")
        wait(for: [reconnected], timeout: 5)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, Set([bufferedID!]))
        socket.handleAck(bufferedID!, data: ["ok"])
        XCTAssertEqual(replies, 1)
    }

    func testAutomaticReconnectRetriesHeadWithFreshAckWithoutReordering() throws {
        let manager = makeManager(.retries(1), .ackTimeout(60))
        let socket = manager.defaultSocket
        connect(socket)
        var replies: [String] = []
        socket.emit("first", ack: { error, _ in XCTAssertNil(error); replies.append("first") })
        let oldID = socket.currentAck
        socket.emit("second", ack: { error, _ in XCTAssertNil(error); replies.append("second") })
        XCTAssertEqual(socket.testRetryQueueCount, 2)
        let reconnected = expectation(description: "reconnected")
        socket.once(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        manager.engineDidClose(reason: "transport close")
        wait(for: [reconnected], timeout: 5)
        let newID = socket.currentAck
        XCTAssertNotEqual(oldID, newID)
        socket.handleAck(oldID, data: [])
        XCTAssertTrue(replies.isEmpty)
        let events = try engine.written.filter { $0.hasPrefix("2") }.map { try manager.parseString($0).event }
        XCTAssertEqual(events, ["first", "first"])
        socket.handleAck(newID, data: [])
        XCTAssertEqual(replies, ["first"])
        socket.handleAck(socket.currentAck, data: [])
        XCTAssertEqual(replies, ["first", "second"])
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    func testAutomaticReconnectExhaustsRetryBudgetWithoutStrandingNextPacket() {
        let manager = makeManager(.retries(1), .ackTimeout(60))
        let socket = manager.defaultSocket
        connect(socket)
        var failures = 0
        socket.emit("first", ack: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected); failures += 1
        })
        socket.emit("second", ack: { error, _ in XCTAssertNil(error) })
        for _ in 0..<2 {
            let reconnected = expectation(description: "reconnected")
            socket.once(clientEvent: .connect) { _, _ in reconnected.fulfill() }
            manager.engineDidClose(reason: "transport close")
            wait(for: [reconnected], timeout: 5)
        }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(socket.testRetryQueueCount, 1)
        socket.handleAck(socket.currentAck, data: [])
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }
}

extension SocketReconnectEventsTest {
    func testAutomaticReconnectFailsAsyncAckWithoutTimeout() {
        let manager = makeManager()
        let socket = manager.defaultSocket
        connect(socket)
        let failed = expectation(description: "async ack rejects on automatic transport drop")
        socket.addAnyOutgoingListener { event in
            if event.event == "pending-async" { manager.engineDidClose(reason: "transport close") }
        }
        // The socket is used again after the Task; box it so the closure can be sent.
        let boxed = SocketUncheckedSendableBox(socket)
        let task = Task {
            do {
                let _: [Any] = try await boxed.value.emitWithAck("pending-async")
                XCTFail("the server never acknowledged this event")
            } catch {
                XCTAssertEqual(error as? SocketAckError, .disconnected)
            }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
        task.cancel()
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }
}
