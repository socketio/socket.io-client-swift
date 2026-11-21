//
//  SocketClearAcksOnCloseTest.swift
//  Socket.IO-Client-Swift
//
//  Round 3 of the JavaScript-parity port: `Socket.onclose` calls `_clearAcks()`
//  on EVERY close in `socket.io-client/lib/socket.ts`, including a close that
//  the manager will retry. Swift used to clear acknowledgements only on the
//  terminal `didDisconnect`, so an ack registered by a session the transport
//  swallowed could survive a reconnect.
//
//  These are unit tests: `ClearAcksTestEngine` answers CONNECT and ACK frames
//  itself and can drop the transport on demand, so the whole
//  drop → reconnect → re-join → re-drain path runs at queue speed with no
//  server and no wall-clock backoff (`.reconnectWait(0)`).
//

import XCTest
@testable import SocketIO

final class SocketClearAcksOnCloseTest: XCTestCase {
    private var manager: SocketManager!
    private var engine: ClearAcksTestEngine!
    private var socket: SocketIOClient!

    override func tearDown() {
        manager?.disconnect()
        socket = nil
        engine = nil
        manager = nil
        super.tearDown()
    }

    /// Builds a manager on the fake engine and connects its default socket, so
    /// every test starts from an established session.
    @discardableResult
    private func makeConnectedSocket(_ options: SocketIOClientOption...) -> SocketIOClient {
        var config: SocketIOClientConfiguration = [.log(false), .reconnects(true), .reconnectWait(0)]
        for option in options {
            config.insert(option)
        }

        manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: config)
        engine = ClearAcksTestEngine(client: manager, url: manager.socketURL, options: nil)
        manager.engine = engine
        socket = manager.defaultSocket

        let connected = expectation(description: "initial connect")
        connected.assertForOverFulfill = false
        let id = socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)
        socket.off(id: id)

        return socket
    }

    /// Kills the transport the way an unexpected drop does and waits for the
    /// namespace to be re-joined, i.e. for one full JS
    /// `onclose` → `reconnect` → `onconnect` cycle.
    private func dropTransportAndWaitForReconnect(reason: String = "transport close") {
        let reconnected = expectation(description: "namespace re-joined")
        reconnected.assertForOverFulfill = false
        let id = socket.on(clientEvent: .connect) { _, _ in reconnected.fulfill() }
        engine.dropTransport(reason: reason)
        wait(for: [reconnected], timeout: 5)
        socket.off(id: id)
    }

    /// Kills the transport without waiting for the namespace to come back.
    /// The `.disconnect` event is JS `Socket.onclose`, which is where
    /// `_clearAcks()` runs.
    private func dropTransport(reason: String = "transport close") {
        let dropped = expectation(description: "disconnect reported")
        dropped.assertForOverFulfill = false
        let id = socket.on(clientEvent: .disconnect) { _, _ in dropped.fulfill() }
        engine.dropTransport(reason: reason)
        wait(for: [dropped], timeout: 5)
        socket.off(id: id)
    }

    /// Runs a barrier through the manager's queue so the deferred `_clearAcks`
    /// dispatch has completed before the assertions read the registry.
    private func drain() {
        let done = expectation(description: "handle queue barrier")
        manager.handleQueue.async { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    // MARK: socket.ts — "should ack with an error upon disconnection (callback & timeout)"

    /// The JS test disconnects manually; this runs the same assertions on a
    /// transport drop that reconnects, which is the path `_clearAcks()` covers
    /// and Swift used to skip. JS also asserts the registry is empty afterwards
    /// (`Object.keys(socket.acks).length === 0`).
    func testTimedAckFailsOnATransportDropThatReconnects() {
        makeConnectedSocket()

        let failed = expectation(description: "ack settles with the disconnect error")
        socket.timeout(after: 10).emit("echo", "a", ack: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            failed.fulfill()
        })
        drain()
        XCTAssertEqual(engine.sentEvents, ["echo"])

        dropTransportAndWaitForReconnect()
        wait(for: [failed], timeout: 5)
        drain()

        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty,
                      "JS `_clearAcks` leaves no registration behind")
        XCTAssertEqual(socket.status, .connected)
    }

    // MARK: socket.ts — "should ack with an error upon disconnection (callback & ackTimeout)"

    func testAckTimeoutCallbackFailsOnATransportDropThatReconnects() {
        makeConnectedSocket(.ackTimeout(10))

        let failed = expectation(description: "err-first ack settles with the disconnect error")
        socket.emit("echo", with: ["a"], ack: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            failed.fulfill()
        })
        drain()

        dropTransportAndWaitForReconnect()
        wait(for: [failed], timeout: 5)
        drain()

        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    // MARK: socket.ts — handlers without `withError` are dropped silently

    /// JS `_clearAcks`: *"handlers that do not accept an error as first argument
    /// are ignored here"* — the registration is deleted, the callback is not
    /// invoked. Without a configured `ackTimeout` the Swift err-first callback
    /// is registered exactly that way (`notifyOnDisconnect: false`).
    func testPlainAckIsRemovedSilentlyOnATransportDropThatReconnects() {
        makeConnectedSocket()

        var calls = [Error?]()
        socket.emit("echo", with: ["a"], ack: { error, _ in calls.append(error) })
        drain()
        XCTAssertFalse(socket.ackHandlers.pendingTimedAckIDs.isEmpty)

        dropTransportAndWaitForReconnect()
        drain()

        XCTAssertTrue(calls.isEmpty, "a plain callback is never called with an error, JS `withError` gating")
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty,
                      "it is still removed from the registry, so a later id collision cannot fire it")
    }

    // MARK: socket.ts — "should not discard an unsent ack (callback)" + "throttled timer"

    /// JS `_clearAcks` skips an ack whose packet is still in `sendBuffer`: the
    /// packet has not reached the server, so the ack is still owed once
    /// `emitBuffered()` sends it. The throttled-timer scenario is what puts a
    /// packet in the buffer while the socket still believes it is connected —
    /// JS sets `_pingTimeoutTime` into the past, here `hasPingExpired`.
    func testUnsentAckSurvivesATransportDropAndIsAcknowledgedAfterReconnect() throws {
        makeConnectedSocket()

        engine.hasPingExpired = true
        let acked = expectation(description: "buffered emit is acknowledged after the reconnect")
        socket.timeout(after: 30).emit("echo", "123", ack: { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? String, "123")
            acked.fulfill()
        })
        drain()
        XCTAssertEqual(engine.sentEvents, [], "the packet is buffered, not sent")
        let bufferedAckID = socket.ackHandlers.pendingTimedAckIDs.first

        engine.hasPingExpired = false
        dropTransportAndWaitForReconnect(reason: "ping timeout")
        drain()

        XCTAssertEqual(engine.sentEvents, ["echo"], "the buffered packet goes out on the next CONNECT")
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, Set([try XCTUnwrap(bufferedAckID)]),
                       "JS `_clearAcks` keeps an ack whose packet is still buffered")

        // The server can now answer it, which is the whole point of keeping it.
        engine.acknowledge(id: try XCTUnwrap(manager.parseString(engine.sent[0]).id), with: "[\"123\"]")
        wait(for: [acked], timeout: 5)
        drain()

        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    // MARK: retry.ts — the retried head after a drop

    /// JS `_clearAcks` retires the *attempt* acknowledgement that `_drainQueue`
    /// registered. The appended `_addToQueue` callback then sees an error with
    /// `tryCount <= retries`, so the entry keeps its place in `_queue` and
    /// `onconnect`'s `_drainQueue(true)` re-sends it under a fresh id.
    func testRetryHeadStaysQueuedAndIsResentWithAFreshIdAfterADrop() throws {
        makeConnectedSocket(.retries(3), .ackTimeout(30))

        var settled = [Error?]()
        socket.emit("echo", with: ["a"], ack: { error, _ in settled.append(error) })
        drain()
        XCTAssertEqual(engine.sentEvents, ["echo"])
        let firstAckID = try XCTUnwrap(manager.parseString(engine.sent[0]).id)

        dropTransportAndWaitForReconnect()
        drain()

        XCTAssertEqual(socket.testRetryQueueCount, 1, "the head keeps its place in the queue")
        XCTAssertTrue(settled.isEmpty, "the user acknowledgement is not settled while retries remain")
        XCTAssertEqual(engine.sentEvents, ["echo", "echo"], "the head is re-sent on the new session")

        let secondAckID = try XCTUnwrap(manager.parseString(engine.sent[1]).id)
        XCTAssertNotEqual(firstAckID, secondAckID, "each attempt owns a fresh acknowledgement id")

        // The server answers the second attempt: the user callback fires once,
        // with the payload, and the queue empties.
        engine.acknowledge(id: secondAckID, with: "[\"a\"]")
        drain()
        XCTAssertEqual(settled.count, 1)
        XCTAssertNil(settled.first ?? nil)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    /// The other half of the JS rule: once `packet.tryCount > this._opts.retries`
    /// the disconnect error discards the entry and settles the user
    /// acknowledgement, exactly like a timeout would.
    func testRetryHeadWhoseBudgetIsSpentIsDiscardedByTheDrop() {
        makeConnectedSocket(.retries(1), .ackTimeout(30))

        let discarded = expectation(description: "user ack settles after the budget is spent")
        socket.emit("echo", with: ["a"], ack: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            discarded.fulfill()
        })
        drain()

        // Try 1 is dropped: 1 > 1 is false, so the entry survives.
        dropTransportAndWaitForReconnect()
        drain()
        XCTAssertEqual(socket.testRetryQueueCount, 1)

        // Try 2 is dropped: 2 > 1, so the entry is discarded with the error.
        dropTransportAndWaitForReconnect()
        wait(for: [discarded], timeout: 5)
        drain()

        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertEqual(engine.sentEvents, ["echo", "echo"], "a discarded entry is not sent a third time")
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    // MARK: connection-state-recovery — the close must not touch recovery state

    /// JS `onclose` clears acknowledgements but leaves `_pid`/`_lastOffset`
    /// alone; that is what lets the next CONNECT ask the server to resume the
    /// session. Only `clearRecoveryState()` drops them.
    func testClearingAcksOnADropLeavesRecoveryStateIntact() {
        makeConnectedSocket()
        socket._pid = "pid-1"
        socket._lastOffset = "offset-1"

        socket.timeout(after: 10).emit("echo", "a", ack: { _, _ in })
        drain()
        dropTransport()
        drain()

        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        XCTAssertEqual(socket._pid, "pid-1")
        XCTAssertEqual(socket._lastOffset, "offset-1")
    }

    // MARK: socket.ts — "should ack with an error upon disconnection (promise)"

    /// The promise form of the same scenario, again on a drop that reconnects.
    /// JS rejects the `emitWithAck` promise from `_clearAcks`; a Swift
    /// continuation has to be resumed exactly once, so it throws `.disconnected`.
    ///
    /// Everything here awaits `fulfillment(of:)`: a synchronous `wait(for:)`
    /// inside a main-actor job cannot drain the main queue the manager runs on.
    @MainActor
    func testAsyncEmitWithAckThrowsDisconnectedOnATransportDropThatReconnects() async {
        let initial = expectation(description: "initial connect")
        let registered = expectation(description: "emit reached the fake transport")
        let rejoined = expectation(description: "namespace re-joined")
        let thrown = expectation(description: "await throws the disconnect error")
        manager = SocketManager(socketURL: URL(string: "http://localhost/")!,
            config: [.log(false), .reconnects(true), .reconnectWait(0), .ackTimeout(10)])
        engine = ClearAcksTestEngine(client: manager, url: manager.socketURL, options: nil)
        manager.engine = engine
        socket = manager.defaultSocket
        socket.once(clientEvent: .connect) { _, _ in initial.fulfill() }
        engine.onEventWrite = { registered.fulfill() }
        socket.connect()
        await fulfillment(of: [initial], timeout: 5)

        let boxed = SocketUncheckedSendableBox(socket!)
        let task = Task {
            do {
                _ = try await boxed.value.emitWithAck("echo", "a")
                XCTFail("the acknowledgement must not resolve")
            } catch {
                XCTAssertEqual(error as? SocketAckError, .disconnected)
            }
            thrown.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [registered], timeout: 5)
        socket.once(clientEvent: .connect) { _, _ in rejoined.fulfill() }
        engine.dropTransport(reason: "transport close")
        await fulfillment(of: [thrown, rejoined], timeout: 5)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        XCTAssertEqual(socket.status, .connected)
        _ = await task.value
    }

}

/// Fake transport for the tests above: it opens on demand, answers the
/// namespace CONNECT the way a server does, records the event frames it is
/// given and can inject an ACK or kill the session.
private final class ClearAcksTestEngine: SocketEngineSpec {
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

    /// Drives the JS "throttled timer" scenario: an emit made while this is
    /// `true` is buffered instead of written.
    var hasPingExpired = false

    var onEventWrite: (() -> Void)?
    private var sessions = 0
    /// Every non-CONNECT frame handed to the transport.
    private(set) var sent = [String]()

    required init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.client = client
    }

    func connect() {
        sessions += 1
        connected = true
        client?.engineDidOpen(reason: "Connect")
    }

    func didError(reason: String) { }

    func disconnect(reason: String) {
        guard connected else { return }
        connected = false
        client?.engineDidClose(reason: reason)
    }

    func doFastUpgrade() { }
    func flushWaitingForPostToWebSocket() { }
    func parseEngineData(_ data: Data) { }
    func parseEngineMessage(_ message: String) { }

    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) {
        completion?()

        guard msg.hasPrefix("0") else {
            sent.append(msg)
            onEventWrite?()
            return
        }

        // Answer the namespace CONNECT as the server does.
        let nsp: String
        if let comma = msg.firstIndex(of: ",") {
            nsp = String(msg[msg.index(after: msg.startIndex)..<comma])
        } else {
            nsp = ""
        }
        client?.parseEngineMessage("0\(nsp),{\"sid\":\"sid-\(sessions)\"}")
    }

    /// The event names of the EVENT frames written so far, in order.
    var sentEvents: [String] {
        sent.compactMap { frame in
            guard let start = frame.firstIndex(of: "["),
                  let json = try? JSONSerialization.jsonObject(with: Data(frame[start...].utf8)) as? [Any]
            else { return nil }

            return json.first as? String
        }
    }

    /// Kills the session from the far end, the way an unexpected drop does.
    func dropTransport(reason: String) {
        disconnect(reason: reason)
    }

    /// Delivers a socket.io ACK frame for `id` on the default namespace.
    func acknowledge(id: Int, with payload: String) {
        client?.parseEngineMessage("3\(id)\(payload)")
    }
}
