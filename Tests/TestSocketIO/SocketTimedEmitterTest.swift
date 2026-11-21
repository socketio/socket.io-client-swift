//
//  SocketTimedEmitterTest.swift
//  Socket.IO-Client-Swift
//
//  Phase 9: tests for the parallel timed-ack storage on SocketAckManager.
//

import XCTest
@testable import SocketIO

final class SocketTimedAckManagerTest: XCTestCase {
    var ackManager: SocketAckManager!
    var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        ackManager = SocketAckManager()
        queue = DispatchQueue(label: "test.handle")
    }

    override func tearDown() {
        ackManager = nil
        queue = nil
        super.tearDown()
    }

    func testAddTimedAckFires() {
        let exp = expectation(description: "callback")
        queue.sync {
            ackManager.addTimedAck(1, on: queue,
                                   callback: { err, data in
                                       XCTAssertNil(err)
                                       XCTAssertEqual(data.first as? String, "ok")
                                       exp.fulfill()
                                   },
                                   timeout: 60)
        }
        queue.socketAsync { self.ackManager.executeTimedAck(1, with: ["ok"]) }
        wait(for: [exp], timeout: 1)
    }

    func testTimedAckTimesOut() {
        let exp = expectation(description: "timeout")
        queue.sync {
            ackManager.addTimedAck(2, on: queue,
                                   callback: { err, _ in
                                       XCTAssertEqual(err as? SocketAckError, .timeout)
                                       exp.fulfill()
                                   },
                                   timeout: 0.1)
        }
        wait(for: [exp], timeout: 1)
    }

    func testCancelTimedAck() {
        let exp = expectation(description: "callback NOT fired")
        exp.isInverted = true
        queue.sync {
            ackManager.addTimedAck(3, on: queue,
                                   callback: { _, _ in exp.fulfill() },
                                   timeout: 0.5)
        }
        queue.socketAsync { self.ackManager.cancelTimedAck(3) }
        // 1s > 0.5s timeout, but cancel removes it before the timer fires.
        wait(for: [exp], timeout: 1)
    }

    func testCancelTimedAckWithErrorFiresCallback() {
        // Bundle 1 deviation from plan: cancelTimedAck supports an optional
        // `fireWith:` error so async cancellation can deliver CancellationError
        // through the same one-shot path that timeout/disconnect use.
        let exp = expectation(description: "callback fires with CancellationError")
        queue.sync {
            ackManager.addTimedAck(7, on: queue,
                                   callback: { err, data in
                                       XCTAssertTrue(err is CancellationError)
                                       XCTAssertTrue(data.isEmpty)
                                       exp.fulfill()
                                   },
                                   timeout: 60)
        }
        queue.socketAsync {
            self.ackManager.cancelTimedAck(7, fireWith: CancellationError())
        }
        wait(for: [exp], timeout: 1)
    }

    func testClearTimedAcksFiresAllWithReason() {
        let exp = expectation(description: "both fire .disconnected")
        exp.expectedFulfillmentCount = 2
        queue.sync {
            ackManager.addTimedAck(4, on: queue, callback: { err, _ in
                XCTAssertEqual(err as? SocketAckError, .disconnected); exp.fulfill()
            }, timeout: 60)
            ackManager.addTimedAck(5, on: queue, callback: { err, _ in
                XCTAssertEqual(err as? SocketAckError, .disconnected); exp.fulfill()
            }, timeout: 60)
        }
        queue.socketAsync { self.ackManager.clearTimedAcks(reason: .disconnected) }
        wait(for: [exp], timeout: 1)
    }

    func testOneShotGuard() {
        let exp = expectation(description: "first execute fires once")
        let firesBox = FireCounter()
        queue.sync {
            ackManager.addTimedAck(6, on: queue,
                                   callback: { _, _ in
                                       firesBox.bump()
                                       exp.fulfill()
                                   },
                                   timeout: 60)
        }
        queue.socketAsync { self.ackManager.executeTimedAck(6, with: ["a"]) }
        queue.socketAsync { self.ackManager.executeTimedAck(6, with: ["b"]) } // duplicate
        wait(for: [exp], timeout: 1)
        queue.sync { } // drain
        XCTAssertEqual(firesBox.count, 1, "duplicate must be silently dropped")
    }
}

/// Tiny counter helper kept outside the test class so the closure capture is unambiguous.
private final class FireCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

// MARK: - Task 4: end-to-end callback path tests
//
// These exercise the full SocketIOClient.timeout(after:).emit(...) callback
// surface against an unconnected manager (no network), so every fire must come
// from local timer/disconnect/cancel paths. The handleQueue MUST be a
// background queue: tests call `manager.handleQueue.sync { }` from the main
// thread to drain dispatched work, and using `.main` would self-deadlock.

final class SocketTimedEmitterCallbackTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.timed.callback.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    func testTimedEmitTimesOutWhenNoServer() {
        let exp = expectation(description: ".timeout fires")
        socket.timeout(after: 0.1).emit("ping") { err, data in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            XCTAssertTrue(data.isEmpty)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testDisconnectMidWaitFiresDisconnected() {
        let exp = expectation(description: ".disconnected fires")
        socket.timeout(after: 5).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .disconnected)
            exp.fulfill()
        }
        // Drain the emit registration so the timed ack is in storage before
        // we trigger the disconnect.
        manager.handleQueue.sync { }
        socket.didDisconnect(reason: "test")
        wait(for: [exp], timeout: 1)
    }

    func testNegativeTimeoutFiresImmediately() {
        let exp = expectation(description: ".timeout fires next tick")
        socket.timeout(after: -1).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testInfinityTimeoutDoesNotFireQuickly() {
        let exp = expectation(description: "no fire within 0.5s")
        exp.isInverted = true
        socket.timeout(after: .infinity).emit("ping") { _, _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)
    }

    func testRegistrationBeforeFunnel_DisconnectedEmitStillTimesOut() {
        // Critical JS-parity contract: even though the socket is .disconnected
        // and the emit funnel will early-return without sending a packet, the
        // ack registration runs BEFORE the funnel guard so the timer is still
        // scheduled and fires .timeout. Mirrors JS `_registerAckCallback`.
        socket.setTestStatus(.disconnected)
        let exp = expectation(description: "timeout fires even though emit early-returned")
        socket.timeout(after: 0.2).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testClearRecoveryStateFiresOutstandingTimedAcksWithDisconnected() {
        let exp = expectation(description: ".disconnected fires from clearRecoveryState")
        socket.timeout(after: 60).emit("ping") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .disconnected,
                           "clearRecoveryState must fire outstanding timed acks with .disconnected")
            exp.fulfill()
        }
        queue.sync { }  // drain emit + addTimedAck
        socket.clearRecoveryState()
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - Task 5: async overload + cancellation
//
// Exercises the `async throws -> [Any]` overloads on SocketTimedEmitter,
// including the withTaskCancellationHandler path that routes Task.cancel()
// through SocketAckManager.cancelTimedAck(_:fireWith:) so the continuation
// resumes throwing CancellationError exactly once.

final class SocketTimedEmitterAsyncTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.timed.async.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    @MainActor
    func testAsyncTimeoutThrows() async {
        do {
            _ = try await socket.timeout(after: 0.1).emit("ping")
            XCTFail("should have thrown")
        } catch let error as SocketAckError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    @MainActor
    func testAsyncCancelThrowsCancellationError() async {
        // Capture the socket locally so the spawned Task does not retain self.
        let socket = self.socket!
        let expectedID = manager.handleQueue.sync { socket.currentAck + 1 }
        let task = Task {
            do {
                _ = try await socket.timeout(after: 60).emit("ping")
                XCTFail("should have thrown")
            } catch is CancellationError {
                // Expected — cancellation handler fires the registered ack
                // with CancellationError, the user-callback adapter resumes
                // the continuation throwing it.
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
        // Let the await register the timed ack on handleQueue before cancel.
        guard await waitForTimedAckRegistration(expectedID) else {
            task.cancel()
            return
        }
        task.cancel()
        _ = await task.value
    }

    @MainActor
    func testAsyncEmitOnPreCancelledTaskThrowsCancellationError() async {
        // Regression for the pre-cancellation deadlock: when a Task is cancelled
        // before its body runs, withTaskCancellationHandler invokes `onCancel`
        // synchronously BEFORE `operation`. The dispatched cancelTimedAck then
        // no-ops (entry not yet registered) and the subsequent addTimedAck
        // would register with nothing to fire it. With `.infinity` timeout this
        // would deadlock the awaiting continuation forever.
        //
        // The Task.isCancelled short-circuit at the top of the continuation
        // closure resumes throwing CancellationError before emitTimed is even
        // called. The test here uses `.infinity` so any regression hangs the
        // test (caught by XCTest's default async timeout) rather than passing
        // by accident on a stray timer.
        let socket = self.socket!
        let task = Task { () -> Void in
            do {
                _ = try await socket.timeout(after: .infinity).emit("ping")
                XCTFail("should have thrown")
            } catch is CancellationError {
                // Expected
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
        task.cancel()  // Cancel before the body has a chance to register.
        _ = await task.value  // Must NOT deadlock.
    }

    /// Observe the actual registration on its owning queue, with a bounded wait.
    @MainActor
    private func waitForTimedAckRegistration(_ id: Int) async -> Bool {
        let socket = self.socket!
        let queue = manager.handleQueue
        let deadline = DispatchTime.now() + .seconds(5)
        while DispatchTime.now() < deadline {
            let registered: Bool = await withCheckedContinuation { continuation in
                queue.socketAsync {
                    continuation.resume(returning: socket.ackHandlers.pendingTimedAckIDs.contains(id))
                }
            }
            if registered { return true }
            await Task.yield()
        }
        XCTFail("Acknowledgement \(id) was not registered")
        return false
    }

    /// socket.io-client/test/socket.ts — "should ack with an error upon
    /// disconnection (promise)": the awaiting Task is rejected instead of being
    /// left waiting. `.infinity` means only the disconnect can resume it, so a
    /// regression hangs rather than passing on a stray timer.
    @MainActor
    func testAsyncEmitThrowsDisconnectedOnDisconnect() async {
        let socket = self.socket!
        let expectedID = manager.handleQueue.sync { socket.currentAck + 1 }
        let task = Task { () -> Error? in
            do {
                _ = try await socket.timeout(after: .infinity).emit("echo", "a")
                return nil
            } catch {
                return error
            }
        }
        // Let the await register the timed ack on handleQueue before disconnecting.
        guard await waitForTimedAckRegistration(expectedID) else {
            task.cancel()
            return
        }
        manager.handleQueue.socketAsync { socket.didDisconnect(reason: "test") }
        let error = await task.value
        XCTAssertEqual(error as? SocketAckError, .disconnected)
        manager.handleQueue.sync { XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty) }
    }

    /// socket.io-client/test/socket.ts — "should ack with an error upon
    /// disconnection (promise & timeout)": the disconnect wins over the timer.
    @MainActor
    func testAsyncEmitWithTimeoutThrowsDisconnectedOnDisconnect() async {
        let socket = self.socket!
        let expectedID = manager.handleQueue.sync { socket.currentAck + 1 }
        let task = Task { () -> Error? in
            do {
                _ = try await socket.timeout(after: 30).emit("echo", "a")
                return nil
            } catch {
                return error
            }
        }
        guard await waitForTimedAckRegistration(expectedID) else {
            task.cancel()
            return
        }
        manager.handleQueue.socketAsync { socket.didDisconnect(reason: "test") }
        let error = await task.value
        XCTAssertEqual(error as? SocketAckError, .disconnected)
    }

    // MARK: socket.ts — "should emit an event and wait for the acknowledgement"

    /// JS `const val = await socket.emitWithAck("echo", 123)`. The ack is
    /// injected here the way the server would deliver it.
    @MainActor
    func testAsyncEmitWithAckResolvesWithTheServerAck() async {
        let socket = self.socket!
        let manager = self.manager!

        let expectedID = manager.handleQueue.sync { socket.currentAck + 1 }
        let task = Task { try await socket.emitWithAck("echo", 123).first as? Int }
        // Let the await register the ack on handleQueue before answering it.
        guard await waitForTimedAckRegistration(expectedID) else {
            task.cancel()
            return
        }
        manager.handleQueue.socketAsync { socket.handleAck(expectedID, data: [123]) }

        let value = try? await task.value
        XCTAssertEqual(value, 123)
    }

    // MARK: socket.ts > timeout — "should not timeout when the server does acknowledge the event (promise)"

    @MainActor
    func testAsyncTimedEmitWithAckDoesNotTimeOutWhenTheServerAcks() async {
        let socket = self.socket!
        let manager = self.manager!

        let expectedID = manager.handleQueue.sync { socket.currentAck + 1 }
        let task = Task { try await socket.timeout(after: 5).emitWithAck("echo", 42).first as? Int }
        guard await waitForTimedAckRegistration(expectedID) else {
            task.cancel()
            return
        }
        manager.handleQueue.socketAsync { socket.handleAck(expectedID, data: [42]) }

        do {
            let value = try await task.value
            XCTAssertEqual(value, 42)
        } catch {
            XCTFail("should not have thrown: \(error)")
        }
    }

    /// The mirror image, JS "should timeout when the server does not
    /// acknowledge the event (promise)", through the JS-named entry point.
    @MainActor
    func testAsyncTimedEmitWithAckTimesOutWhenNoAckArrives() async {
        do {
            _ = try await socket.timeout(after: 0.1).emitWithAck("unknown")
            XCTFail("should have thrown")
        } catch let error as SocketAckError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    @MainActor
    func testAsyncCancelClearsTimedAck() async {
        let socket = self.socket!
        let task = Task { _ = try? await socket.timeout(after: 60).emit("ping") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value
        // Drain handleQueue so the cancelTimedAck(fireWith:) dispatched from
        // the cancellation handler completes and the entry is removed.
        manager.handleQueue.sync { }

        // Public-observable check: a follow-up timed emit must complete its
        // own lifecycle cleanly. If the prior cancel left the entry in
        // storage, the ack-id allocator would still advance, but the leaked
        // timer would later fire against a stale callback. Easiest robust
        // observation is that a fresh 0.1s timeout fires exactly once with
        // .timeout — proving (a) the manager isn't wedged and (b) we can
        // continue issuing emits after cancel.
        let exp = expectation(description: "follow-up emit times out cleanly")
        socket.timeout(after: 0.1).emit("ping") { err, data in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            XCTAssertTrue(data.isEmpty)
            exp.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [exp], timeout: 1)
        XCTAssertEqual(result, .completed)
    }
}

// MARK: - Task 6: race / atomicity stress + storage isolation
//
// `testTimerAckRaceFiresOnce` is a 200-iteration stress that pits a ~1ms timer
// against an off-queue handleAck injection on the same id. Entry removal on
// handleQueue must drop the loser so the user callback fires exactly once.
//
// `testLegacyEmitWithAckTimingOutNotClearedOnDisconnect` regression-pins the
// documented divergence: legacy emitWithAck.timingOut(after:) does NOT have a
// withError callback, and Phase 9 deliberately did not retro-fit the legacy
// path. clearTimedAcks(reason: .disconnected) only drains the new timed-ack
// storage, so the legacy ack stays orphaned on disconnect — fires == 0.
//
// Each race waits for every injected operation, including the losing path,
// to finish on handleQueue before inspecting its counter. A sleep, or a queue
// drain before an asyncAfter block has enqueued its work, cannot guarantee
// completion and lets a delayed contender outlive the test's fixtures.

final class SocketTimedEmitterRaceTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.timed.race.handleQueue")
        let url = URL(string: "http://localhost/")!
        manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        manager = nil
        queue = nil
        super.tearDown()
    }

    func testTimerAckRaceFiresOnce() {
        // Capture the fixtures, not self: delayed work must never read fields
        // that tearDown() can clear, even if an expectation times out.
        let manager = self.manager!, socket = self.socket!
        // Tight race: ~1ms timer vs ~1ms async handleAck injection from a
        // background queue. Entry removal must arbitrate so the user callback
        // runs exactly once across all iterations.
        let iterations = 200
        for _ in 0..<iterations {
            let counter = FireCounter()
            let exp = expectation(description: "single fire")
            exp.assertForOverFulfill = true
            let ackProcessed = expectation(description: "racing server ack processed")
            socket.timeout(after: 0.001).emit("ping") { _, _ in
                counter.bump()
                exp.fulfill()
            }
            // Capture the allocated ack id by reading currentAck on
            // handleQueue AFTER the emit's async registration runs. This
            // serialization is what makes the next handleAck call target the
            // right id rather than racing the allocator.
            let ackId = manager.handleQueue.sync { socket.currentAck }
            // Race: server-ack arrives at ~the same time as the timer.
            DispatchQueue.global().socketAsyncAfter(deadline: .now() + 0.001) {
                manager.handleQueue.socketAsync {
                    socket.handleAck(ackId, data: ["x"])
                    ackProcessed.fulfill()
                }
            }
            // The winning callback alone does not mean the losing ack ran.
            wait(for: [exp, ackProcessed], timeout: 1)
            manager.handleQueue.sync {
                XCTAssertEqual(counter.count, 1, "must fire exactly once")
                XCTAssertFalse(socket.ackHandlers.pendingTimedAckIDs.contains(ackId))
            }
        }
    }

    func testCancelTimerRaceFiresOnce() {
        let manager = self.manager!, socket = self.socket!
        // Spec lines 801-802: cancel-vs-timer atomic stress. The timer fires at
        // ~1ms; cancelTimedAck(fireWith:) is dispatched at the same deadline
        // from a background queue. Entry removal must arbitrate so the user
        // callback runs exactly once across all iterations.
        for _ in 0..<200 {
            let counter = FireCounter()
            let exp = expectation(description: "single fire (cancel vs timer)")
            exp.assertForOverFulfill = true
            let cancelProcessed = expectation(description: "racing cancellation processed")
            let id: Int = manager.handleQueue.sync { socket.allocateAckId() }
            manager.handleQueue.sync {
                socket.ackHandlers.addTimedAck(id, on: manager.handleQueue,
                                               callback: { _, _ in
                                                   counter.bump()
                                                   exp.fulfill()
                                               },
                                               timeout: 0.001)
            }
            DispatchQueue.global().socketAsyncAfter(deadline: .now() + 0.001) {
                manager.handleQueue.socketAsync {
                    socket.ackHandlers.cancelTimedAck(id, fireWith: SocketAckError.disconnected)
                    cancelProcessed.fulfill()
                }
            }
            wait(for: [exp, cancelProcessed], timeout: 1)
            manager.handleQueue.sync {
                XCTAssertEqual(counter.count, 1, "cancel-vs-timer must fire exactly once")
                XCTAssertFalse(socket.ackHandlers.pendingTimedAckIDs.contains(id))
            }
        }
    }

    func testCancelAckRaceFiresOnce() {
        let manager = self.manager!, socket = self.socket!
        // Spec lines 801-802: cancel-vs-server-ack atomic stress. A cancel
        // (fireWith: .disconnected) and a server ack injection both target the
        // same id at ~1ms. Entry removal must drop the loser so the user
        // callback runs exactly once.
        for _ in 0..<200 {
            let counter = FireCounter()
            let exp = expectation(description: "single fire (cancel vs server-ack)")
            exp.assertForOverFulfill = true
            let contendersProcessed = expectation(description: "both racing operations processed")
            contendersProcessed.expectedFulfillmentCount = 2
            let id: Int = manager.handleQueue.sync { socket.allocateAckId() }
            manager.handleQueue.sync {
                socket.ackHandlers.addTimedAck(id, on: manager.handleQueue,
                                               callback: { _, _ in
                                                   counter.bump()
                                                   exp.fulfill()
                                               },
                                               timeout: 60)
            }
            DispatchQueue.global().socketAsyncAfter(deadline: .now() + 0.001) {
                manager.handleQueue.socketAsync {
                    socket.ackHandlers.cancelTimedAck(id, fireWith: SocketAckError.disconnected)
                    contendersProcessed.fulfill()
                }
            }
            DispatchQueue.global().socketAsyncAfter(deadline: .now() + 0.001) {
                manager.handleQueue.socketAsync {
                    socket.handleAck(id, data: ["x"])
                    contendersProcessed.fulfill()
                }
            }
            wait(for: [exp, contendersProcessed], timeout: 1)
            manager.handleQueue.sync {
                XCTAssertEqual(counter.count, 1, "cancel-vs-ack must fire exactly once")
                XCTAssertFalse(socket.ackHandlers.pendingTimedAckIDs.contains(id))
            }
        }
    }

    func testLegacyEmitWithAckTimingOutNotClearedOnDisconnect() {
        // JS-divergence regression-pin: the legacy path uses SocketAckManager's
        // `acks` (untyped AckCallback, no fireWith error). didDisconnect only
        // calls clearTimedAcks(reason: .disconnected) on the new timed-ack storage, so a
        // legacy emitWithAck.timingOut callback is orphaned across a disconnect
        // until its own timer fires (at which point it would fire .noAck, not
        // .disconnected). For this test we use a 5s timer and only wait 0.2s,
        // so the assertion is purely "no fire happened during the disconnect".
        let counter = FireCounter()
        socket.emitWithAck("ping").timingOut(after: 5) { _ in counter.bump() }
        manager.handleQueue.sync { }
        socket.didDisconnect(reason: "test")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(counter.count, 0,
                       "legacy emitWithAck.timingOut path is NOT cleared on disconnect (Swift backcompat divergence)")
    }
}


final class SocketValueSnapshotTest: XCTestCase {
    func testMutableFoundationContainersAreDetachedFromAsyncAckResults() throws {
        let array = NSMutableArray(array: ["before"])
        let bytes = NSMutableData(data: Data([4, 0, 255]))
        let dictionary = NSMutableDictionary(dictionary: ["nested": array, "binary": bytes])
        let snapshot = try SocketValueSnapshot(dictionary)
        array[0] = "after"
        bytes.setData(Data([99]))
        dictionary["added"] = true
        let value = try XCTUnwrap(snapshot.value as? [String: Any])
        XCTAssertEqual(value["nested"] as? [String], ["before"])
        XCTAssertEqual(value["binary"] as? Data, Data([4, 0, 255]))
        XCTAssertNil(value["added"])
    }

    func testUnsupportedObjectsCannotCrossTheAsyncAckBoundary() {
        XCTAssertThrowsError(try SocketValueSnapshot(NSObject()))
    }

    func testWireScalarAndEmptyContainerTypesRoundTrip() throws {
        XCTAssertEqual(try SocketValueSnapshot(true).value as? Bool, true)
        XCTAssertEqual(try SocketValueSnapshot(42).value as? Int, 42)
        XCTAssertTrue(try SocketValueSnapshot(NSNull()).value is NSNull)
        XCTAssertEqual(try SocketValueSnapshot([String]()).value as? [String], [])
        XCTAssertNotNil(try SocketValueSnapshot([String: Any]()).value as? [String: Any])
    }
}


final class SocketMainActorAsyncAPITest: XCTestCase {
    @MainActor
    func testMainActorCanAwaitTimedAndDefaultAcknowledgements() async {
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                    config: [.log(false), .ackTimeout(0.01)])
        let socket = manager.defaultSocket
        socket.setTestStatus(.connected)
        do {
            _ = try await socket.timeout(after: 0.01).emitWithAck("timeout")
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? SocketAckError, .timeout)
        }
        do {
            _ = try await socket.emitWithAck("timeout")
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? SocketAckError, .timeout)
        }
    }
}
