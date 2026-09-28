import Foundation
import XCTest
@testable import SocketIO

/// Queue/ack invariants use a synchronous fake writer, not a 10ms localhost budget.
final class SocketRetrySafetyTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var engine: MockEngine!

    private func make(_ config: SocketIOClientConfiguration = [.retries(1), .ackTimeout(1)]) {
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: config)
        socket = manager.defaultSocket
        engine = MockEngine()
        manager.engine = engine
        socket.didConnect(toNamespace: "/", payload: ["sid": "first"])
    }
    private func drain() {
        let done = expectation(description: "handle queue barrier")
        manager.handleQueue.socketAsync { done.fulfill() }
        wait(for: [done], timeout: 3)
    }
    private func ackID(_ position: Int) throws -> Int {
        try manager.parseString(engine.sentPackets[position].0).id
    }
    override func tearDown() {
        if let socket = socket { socket.clearRecoveryState() }
        socket = nil; engine = nil; manager = nil
        super.tearDown()
    }

    func testExpiredHeartbeatBuffersInsteadOfSendingOnTheStaleConnection() throws {
        make([])
        engine.hasPingExpired = true
        socket.emit("after-suspension", "data")
        XCTAssertTrue(engine.sentPackets.isEmpty)
        socket.didDisconnect(reason: "ping timeout")
        engine.hasPingExpired = false
        socket.didConnect(toNamespace: "/", payload: ["sid": "fresh"])
        XCTAssertEqual(engine.sentPackets.count, 1)
        XCTAssertEqual(try manager.parseString(engine.sentPackets[0].0).event, "after-suspension")
    }

    func testIdentityResetCannotSweepTheNewIdentityAcknowledgement() {
        make([])
        socket.ackHandlers.addTimedAck(100, on: .main, callback: { _, _ in }, timeout: .infinity)
        socket.clearRecoveryState()
        socket.ackHandlers.addTimedAck(101, on: .main, callback: { _, _ in }, timeout: .infinity)
        drain()
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [101])
    }

    func testEmitImmediatelyFollowedByDisconnectFailsTheAlreadyRegisteredAck() {
        make([.ackTimeout(10)])
        let failed = expectation(description: "same-turn emit is registered before disconnect")
        socket.emit("never_ack", ack: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            failed.fulfill()
        })
        XCTAssertEqual(engine.sentPackets.count, 1)
        socket.didDisconnect(reason: "transport close")
        wait(for: [failed], timeout: 2)
    }

    func testTimedRetryDoesNotConsumeAnUnusedAckID() throws {
        make([.retries(1)])
        socket.timeout(after: 10).emit("x", ack: { _, _ in })
        drain()
        XCTAssertEqual(try ackID(0), 0)
    }

    func testPlainRetryInheritsAckTimeoutAndCannotBlockNextPacketForever() {
        make([.retries(1), .ackTimeout(0)])
        let done = expectation(description: "next packet exhausted its budget")
        socket.emit("never-acked")
        socket.emit("next", ack: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .timeout)
            done.fulfill()
        })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(engine.sentPackets.count, 4)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    func testPlainLocalCompletionFiresOnceAcrossRetries() {
        make([.retries(2), .ackTimeout(0)])
        let completed = expectation(description: "one local completion")
        var calls = 0
        socket.emit("never-acked", completion: { calls += 1; completed.fulfill() })
        let done = expectation(description: "following packet drained")
        socket.emit("next", ack: { _, _ in done.fulfill() })
        wait(for: [completed, done], timeout: 3)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(engine.sentPackets.count, 6)
    }

    func testRetryCannotBypassReservedEventValidation() {
        make()
        var errors = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        for event in ["connect", "connect_error", "disconnect", "disconnecting", "newListener", "removeListener"] {
            socket.emit(event)
        }
        drain()
        XCTAssertEqual(errors, 6)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testReconnectRetiresOldAckAndOldDisconnectCannotCancelNewAttempt() throws {
        make()
        var replies = 0
        socket.emit("x", ack: { error, _ in XCTAssertNil(error); replies += 1 })
        drain()
        let oldID = try ackID(0)
        socket.didDisconnect(reason: "transport close")
        // Before the old asynchronous ack sweep executes, the new namespace opens.
        socket.didConnect(toNamespace: "/", payload: ["sid": "second"])
        let newID = try ackID(1)
        drain()
        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(engine.sentPackets.count, 2)
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [newID])
        socket.handleAck(oldID, data: ["stale"])
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [newID])
        XCTAssertEqual(engine.sentPackets.count, 2)
        socket.handleAck(newID, data: ["current"])
        socket.handleAck(newID, data: ["duplicate"])
        socket.handleAck(oldID, data: ["late again"])
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(engine.sentPackets.count, 2)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testConnectEventSeesAlreadyDrainedRetryHead() throws {
        make()
        socket.setTestStatus(.disconnected)
        socket.emit("buffered")
        drain()
        socket.on(clientEvent: .connect) { [self] _, _ in
            XCTAssertEqual(engine.sentPackets.count, 1)
            socket.emit("from-connect")
        }
        socket.didConnect(toNamespace: "/", payload: ["sid": "replacement"])
        drain()
        XCTAssertEqual(engine.sentPackets.count, 1)
        socket.handleAck(try ackID(0), data: [])
        drain()
        XCTAssertEqual(engine.sentPackets.count, 2)
    }

    func testIdentityResetCancelsRetryTimerAndCompletesUnsentOperation() {
        make([.retries(3), .ackTimeout(3600)])
        socket.setTestStatus(.disconnected)
        let completed = expectation(description: "unsent local operation cancelled")
        socket.emit("unsent", completion: { completed.fulfill() })
        XCTAssertEqual(socket.testRetryQueueCount, 1, "exercise cleanup, not configuration rejection")
        socket.clearRecoveryState()
        wait(for: [completed], timeout: 3)
        drain()
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    func testNoTimeoutModernAckIsRemovedSilentlyOnDisconnect() {
        make([])
        var callbacks = 0
        socket.emit("x", ack: { _, _ in callbacks += 1 })
        drain()
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs.count, 1)
        socket.didDisconnect(reason: "transport close")
        drain()
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        XCTAssertEqual(callbacks, 0)
    }

    func testRetryWithoutTimeoutSurvivesSeveralDisconnects() throws {
        make([.retries(1)])
        var callbacks = 0
        socket.emit("x", ack: { error, _ in XCTAssertNil(error); callbacks += 1 })
        drain()
        for index in 0..<3 {
            socket.didDisconnect(reason: "transport close")
            drain()
            socket.didConnect(toNamespace: "/", payload: ["sid": "s\(index)"])
        }
        XCTAssertEqual(callbacks, 0)
        socket.handleAck(try ackID(3), data: [])
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    func testSelectiveAckSweepDoesNotDeleteLaterRegistration() {
        make([])
        socket.ackHandlers.addTimedAck(10, on: .main, callback: { _, _ in }, timeout: .infinity)
        let retired = socket.ackHandlers.pendingTimedAckIDs
        socket.ackHandlers.addTimedAck(11, on: .main, callback: { _, _ in }, timeout: .infinity)
        socket.ackHandlers.clearTimedAcks(reason: .disconnected, only: retired)
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [11])
    }

    func testCancelledBeforeRegistrationCannotHangInfiniteAsyncAck() {
        make([])
        let state = SocketAsyncAckState()
        state.cancel() // Models cancellation in the check-to-enqueue race window.
        let cancelled = expectation(description: "early cancellation observed at registration")
        socket.emitTimed(event: "x", items: [], timeout: .infinity, cancellation: state) { error, _ in
            XCTAssertTrue(error is CancellationError)
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 3)
        XCTAssertNil(state.registeredID)
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testReplacingAnAckIDCannotFireItsOldTimer() {
        make([])
        var oldCalls = 0
        var newCalls = 0
        socket.ackHandlers.addTimedAck(50, on: .main, callback: { _, _ in oldCalls += 1 }, timeout: 0)
        socket.ackHandlers.addTimedAck(50, on: .main, callback: { _, _ in newCalls += 1 }, timeout: .infinity)
        drain()
        XCTAssertEqual(oldCalls, 0)
        XCTAssertEqual(newCalls, 0)
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [50])
        socket.ackHandlers.executeTimedAck(50, with: [])
        socket.ackHandlers.executeTimedAck(50, with: ["duplicate"])
        drain()
        XCTAssertEqual(oldCalls, 0)
        XCTAssertEqual(newCalls, 1)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }
}

extension SocketRetrySafetyTest {
    func testAsyncRegistrationSharesRetryQueueAndIgnoresLateAcknowledgements() throws {
        make([.retries(1), .ackTimeout(100)])
        let state = SocketAsyncAckState()
        var results: [String] = []
        socket.emit("first", ack: { error, _ in XCTAssertNil(error); results.append("first") })
        socket.emitTimed(event: "async", items: [], timeout: 100, cancellation: state) { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? String, "ok")
            results.append("async")
        }
        socket.emit("last", ack: { error, _ in XCTAssertNil(error); results.append("last") })
        XCTAssertEqual(engine.sentPackets.count, 1)
        let first = try ackID(0)
        socket.ackHandlers.cancelTimedAck(first, fireWith: SocketAckError.timeout)
        XCTAssertEqual(engine.sentPackets.count, 2)
        socket.handleAck(first, data: ["late"])
        XCTAssertTrue(results.isEmpty)
        socket.handleAck(try ackID(1), data: ["ok"])
        XCTAssertEqual(results, ["first"])
        let asyncFirst = try ackID(2)
        socket.ackHandlers.cancelTimedAck(asyncFirst, fireWith: SocketAckError.timeout)
        socket.handleAck(asyncFirst, data: ["late"])
        socket.handleAck(try ackID(3), data: ["ok"])
        socket.handleAck(try ackID(4), data: ["ok"])
        XCTAssertEqual(results, ["first", "async", "last"])
        XCTAssertEqual(try engine.sentPackets.map { try manager.parseString($0.0).event },
                       ["first", "first", "async", "async", "last"])
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testCancellationRemovesWaitingInflightAndReconnectingRetryEntries() throws {
        for phase in ["waiting", "inflight", "reconnecting"] {
            make([.retries(2), .ackTimeout(100)])
            if phase == "waiting" { socket.emit("head", ack: { _, _ in }) }
            let state = SocketAsyncAckState()
            var calls = 0
            socket.emitTimed(event: "cancel", items: [], timeout: 100, cancellation: state) { error, _ in
                XCTAssertTrue(error is CancellationError)
                calls += 1
            }
            socket.emit("next", ack: { _, _ in })
            let stale = phase == "waiting" ? nil : try ackID(0)
            if phase == "reconnecting" { socket.setReconnecting(reason: "transport close") }
            state.cancel()
            socket.cancelAsyncEmit(state)
            socket.cancelAsyncEmit(state)
            if let stale { socket.handleAck(stale, data: ["late"]) }
            XCTAssertEqual(calls, 1, phase)
            if phase == "waiting" { socket.handleAck(try ackID(0), data: []) }
            if phase == "reconnecting" {
                socket.didConnect(toNamespace: "/", payload: ["sid": "replacement"])
            }
            let last = try ackID(engine.sentPackets.count - 1)
            XCTAssertEqual(try manager.parseString(engine.sentPackets.last!.0).event, "next", phase)
            socket.handleAck(last, data: [])
            XCTAssertEqual(socket.testRetryQueueCount, 0, phase)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty, phase)
            socket.clearRecoveryState()
        }
    }

    func testNamespaceDeliveryOverridesDoNotChangeSiblingOrManager() {
        make([.retries(2), .ackTimeout(10)])
        let sibling = manager.socket(forNamespace: "/sibling")
        socket.retries = 0
        socket.ackTimeout = 3
        XCTAssertEqual(sibling.retries, 2)
        XCTAssertEqual(sibling.ackTimeout, 10)
        XCTAssertEqual(manager.retries, 2)
        XCTAssertEqual(manager.ackTimeout, 10)
        XCTAssertEqual(socket.retries, 0)
        XCTAssertEqual(socket.ackTimeout, 3)
        socket.resetDeliveryOptions()
        XCTAssertEqual(socket.retries, 2)
        XCTAssertEqual(socket.ackTimeout, 10)
    }

    @MainActor
    func testAwaitEmitWithAckRetriesBeforeTheFollowingCallbackEmit() async throws {
        make([.retries(1), .ackTimeout(100)])
        let socket = self.socket!
        let manager = self.manager!
        let engine = self.engine!
        let boxed = SocketUncheckedSendableBox(socket)
        let firstWrite = expectation(description: "async first attempt registered")
        engine.onWrite = { _, _ in firstWrite.fulfill() }
        let task = Task {
            let data = try await boxed.value.emitWithAck("async")
            return data.first as? String
        }
        defer { task.cancel() }
        await fulfillment(of: [firstWrite], timeout: 3)
        engine.onWrite = nil
        socket.emit("following", ack: { error, _ in XCTAssertNil(error) })
        XCTAssertEqual(engine.sentPackets.count, 1)
        let first = try manager.parseString(engine.sentPackets[0].0).id
        socket.ackHandlers.cancelTimedAck(first, fireWith: SocketAckError.timeout)
        let second = try manager.parseString(engine.sentPackets[1].0).id
        socket.handleAck(second, data: ["success"])
        let result = try await task.value
        XCTAssertEqual(result, "success")
        XCTAssertEqual(try engine.sentPackets.map { try manager.parseString($0.0).event },
                       ["async", "async", "following"])
        socket.handleAck(try manager.parseString(engine.sentPackets[2].0).id, data: [])
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }
}

extension SocketRetrySafetyTest {
    func testCancellationWinsWhenAnAckOrQueueDrainRunsBeforeTheCancellationHop() throws {
        for waiting in [false, true] {
            make([.retries(1), .ackTimeout(100)])
            if waiting { socket.emit("head", ack: { _, _ in }) }
            let token = SocketAsyncAckState()
            var cancellations = 0
            var successes = 0
            socket.emitTimed(event: "cancel", items: [], timeout: 100, cancellation: token) { error, _ in
                XCTAssertTrue(error is CancellationError)
                cancellations += 1
            }
            socket.emit("next", ack: { error, _ in
                XCTAssertNil(error)
                successes += 1
            })
            let oldID = try ackID(0)
            // Task cancellation sets the lock-protected token before its owner-
            // queue cleanup hop. An already queued ack must not turn it into success.
            token.cancel()
            socket.handleAck(oldID, data: ["too late"])
            XCTAssertEqual(cancellations, 1)
            XCTAssertEqual(engine.sentPackets.count, 2)
            XCTAssertEqual(try manager.parseString(engine.sentPackets[1].0).event, "next")
            socket.cancelAsyncEmit(token)
            socket.handleAck(oldID, data: ["duplicate"])
            XCTAssertEqual(cancellations, 1)
            socket.handleAck(try ackID(1), data: [])
            XCTAssertEqual(successes, 1)
            XCTAssertEqual(socket.testRetryQueueCount, 0)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        }
    }
}
