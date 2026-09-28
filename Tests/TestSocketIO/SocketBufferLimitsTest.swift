//
//  SocketBufferLimitsTest.swift
//  Socket.IO-Client-Swift
//
//  Round 3 of the JavaScript-parity port: review gate R1, "bound the entire
//  pipeline, not only individual native packets"
//  (`Documentation/ProtocolParityReview.md` section 5).
//
//  The acceptance list from that gate, one test each: blocked consumer,
//  never-connected socket, never-acked retry head, replay flood, unfinished
//  binary packet, oversized and chunked HTTP body, plus proof that the retained
//  counts and bytes return to zero after a reset or a disconnect.
//
//  The defaults are unlimited, which is what keeps this client JavaScript-equal;
//  `testDefaultsAreUnlimitedLikeJavaScript` pins that.
//

import Foundation
import XCTest
@testable import SocketIO

final class SocketBufferLimitsTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var engine: MockEngine!

    private func make(_ limits: SocketBufferLimits, _ options: SocketIOClientOption...) {
        var config: SocketIOClientConfiguration = [.log(false), .bufferLimits(limits)]
        for option in options {
            config.insert(option)
        }

        manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: config)
        socket = manager.defaultSocket
        engine = MockEngine()
        manager.engine = engine
    }

    private func connect() {
        socket.didConnect(toNamespace: "/", payload: ["sid": "first"])
    }

    private func drain() {
        let done = expectation(description: "handle queue barrier")
        manager.handleQueue.async { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    override func tearDown() {
        socket = nil
        engine = nil
        manager = nil
        super.tearDown()
    }

    // MARK: The default is the JavaScript behaviour

    func testDefaultsAreUnlimitedLikeJavaScript() {
        let defaults = SocketBufferLimits()

        XCTAssertEqual(defaults, SocketBufferLimits.unlimited)
        XCTAssertEqual(defaults.maximumSendBufferPackets, .max)
        XCTAssertEqual(defaults.maximumSendBufferBytes, .max)
        XCTAssertEqual(defaults.maximumRetryQueuePackets, .max)
        XCTAssertEqual(defaults.maximumRecoveryReplayPackets, .max)
        XCTAssertEqual(defaults.maximumUnparsedPackets, .max)
        XCTAssertEqual(defaults.maximumPollingResponseBytes, .max)
        XCTAssertTrue(defaults.binaryReconstructionTimeout.isInfinite)
        XCTAssertTrue(defaults.isUnlimited)
        XCTAssertTrue(defaults.isValid)
        XCTAssertEqual(SocketManager(socketURL: URL(string: "http://localhost/")!, config: []).bufferLimits,
                       .unlimited)
    }

    func testAnInvalidLimitIsRejectedBeforeConnecting() {
        make(SocketBufferLimits(maximumSendBufferPackets: 0))

        var errors = [String]()
        socket.on(clientEvent: .connectError) { data, _ in errors.append(data.first as? String ?? "") }
        manager.connect()

        XCTAssertEqual(errors, ["Invalid buffer limits"])
        XCTAssertEqual(manager.status, .disconnected)
    }

    func testDictionaryConfigurationReportsAWrongBufferLimitsValue() {
        let config: [String: Any] = ["bufferLimits": 12]
        let converted = config.toSocketConfiguration()

        XCTAssertTrue(converted.contains(where: {
            if case let .invalidConfiguration(reason) = $0 {
                return reason == "invalid value for bufferLimits; expected SocketBufferLimits"
            }
            return false
        }))
    }

    // MARK: Acceptance — never-connected socket

    /// A socket that never connects buffers every emit. Once the bound is
    /// reached the *new* emit fails; nothing already buffered is evicted, so no
    /// reliable emit is lost silently.
    func testNeverConnectedSocketStopsBufferingAtTheLimit() {
        make(SocketBufferLimits(maximumSendBufferPackets: 2))

        var errors = [SocketBufferLimitError]()
        socket.on(clientEvent: .error) { data, _ in
            if let error = data.first as? SocketBufferLimitError { errors.append(error) }
        }

        socket.emit("one", "a")
        socket.emit("two", "b")
        XCTAssertTrue(errors.isEmpty)

        var completed = 0
        socket.emit("three", "c", completion: { completed += 1 })
        drain()

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.buffer, .sendBuffer)
        XCTAssertEqual(errors.first?.limit, 2)
        XCTAssertEqual(errors.first?.attempted, 3)
        XCTAssertFalse(errors.first?.measuringBytes ?? true)
        XCTAssertEqual(completed, 1, "the rejected emit's local completion runs exactly once")
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 2, "nothing already buffered is evicted")

        // The two accepted emits still go out, in order, on the next CONNECT.
        connect()
        XCTAssertEqual(engine.sentPackets.count, 2)
        XCTAssertEqual(try? manager.parseString(engine.sentPackets[0].0).event, "one")
        XCTAssertEqual(try? manager.parseString(engine.sentPackets[1].0).event, "two")
    }

    /// The byte bound is enforced the same way, and the error says so.
    func testSendBufferByteLimitFailsTheOverflowingEmitAndItsAcknowledgement() {
        make(SocketBufferLimits(maximumSendBufferBytes: 16), .ackTimeout(30))

        socket.emit("x", String(repeating: "a", count: 10))
        drain()
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 1)

        var ackError: Error?
        let settled = expectation(description: "the rejected emit settles its acknowledgement")
        socket.emit("y", with: [String(repeating: "b", count: 10)], ack: { error, _ in
            ackError = error
            settled.fulfill()
        })
        wait(for: [settled], timeout: 3)
        drain()

        XCTAssertEqual((ackError as? SocketBufferLimitError)?.buffer, .sendBuffer)
        XCTAssertTrue((ackError as? SocketBufferLimitError)?.measuringBytes ?? false)
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 1, "the rejected emit was not buffered")
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty,
                      "its acknowledgement is settled once and removed")
    }

    // MARK: Acceptance — never-acked retry head

    /// Only the head of the retry queue is in flight, so a head the server
    /// never acknowledges makes everything behind it accumulate. The bound
    /// fails the new emit and leaves the head its retry budget.
    func testNeverAckedRetryHeadStopsTheQueueAtTheLimit() {
        make(SocketBufferLimits(maximumRetryQueuePackets: 2), .retries(3), .ackTimeout(3600))
        connect()

        var errors = [SocketBufferLimitError]()
        socket.on(clientEvent: .error) { data, _ in
            if let error = data.first as? SocketBufferLimitError { errors.append(error) }
        }

        socket.emit("head", with: ["a"], ack: { _, _ in })
        socket.emit("second", with: ["b"], ack: { _, _ in })
        drain()
        XCTAssertEqual(socket.testRetryQueueCount, 2)
        XCTAssertEqual(engine.sentPackets.count, 1, "only the head is in flight")

        var rejected: Error?
        let settled = expectation(description: "the rejected retry emit settles")
        socket.emit("third", with: ["c"], ack: { error, _ in
            rejected = error
            settled.fulfill()
        })
        wait(for: [settled], timeout: 3)
        drain()

        XCTAssertEqual((rejected as? SocketBufferLimitError)?.buffer, .retryQueue)
        XCTAssertEqual(errors.first?.buffer, .retryQueue)
        XCTAssertEqual(socket.testRetryQueueCount, 2, "the head keeps its place and its budget")
        XCTAssertEqual(engine.sentPackets.count, 1)
    }

    // MARK: Acceptance — blocked consumer

    /// The permit is taken when the engine dispatches a packet and released
    /// only when parsing has finished, so a `handleQueue` that cannot keep up
    /// stops the transport instead of letting the backlog grow. Releasing after
    /// the *dispatch* would not bound anything.
    func testBlockedConsumerStopsTheTransportInsteadOfGrowingTheBacklog() {
        let blocked = DispatchQueue(label: "blocked.consumer")
        make(SocketBufferLimits(maximumUnparsedPackets: 3), .handleQueue(blocked))

        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        blocked.async {
            entered.signal()
            release.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)

        for index in 0..<3 {
            manager.parseEngineMessage("2[\"ev\",\(index)]")
        }
        XCTAssertEqual(manager.testReceiveBacklog.packets, 3)
        XCTAssertTrue(engine.disconnectReasons.isEmpty)

        // The fourth packet has nowhere to go: it is refused and the transport
        // is closed rather than dispatched onto a queue that is not draining.
        manager.parseEngineMessage("2[\"ev\",3]")
        XCTAssertEqual(manager.testReceiveBacklog.packets, 3, "the refused packet took no permit")
        XCTAssertEqual(engine.disconnectReasons, ["transport error"])

        // Further packets are refused too, without re-closing.
        manager.parseEngineMessage("2[\"ev\",4]")
        XCTAssertEqual(engine.disconnectReasons, ["transport error"])

        release.signal()
        let drained = expectation(description: "consumer resumed")
        blocked.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(manager.testReceiveBacklog.packets, 0, "permits are released after parsing")
        XCTAssertEqual(manager.testReceiveBacklog.bytes, 0)
    }

    func testReceiveBacklogByteLimitAlsoClosesTheTransport() {
        let blocked = DispatchQueue(label: "blocked.consumer.bytes")
        make(SocketBufferLimits(maximumUnparsedBytes: 20), .handleQueue(blocked))

        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        blocked.async {
            entered.signal()
            release.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)

        manager.parseEngineMessage("2[\"ev\",\"\(String(repeating: "a", count: 10))\"]")
        XCTAssertTrue(engine.disconnectReasons.isEmpty)
        manager.parseEngineMessage("2[\"ev\",\"\(String(repeating: "b", count: 10))\"]")
        XCTAssertEqual(engine.disconnectReasons, ["transport error"])

        release.signal()
        let drained = expectation(description: "consumer resumed")
        blocked.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(manager.testReceiveBacklog.bytes, 0)
    }

    /// Without a configured bound the handoff behaves exactly as before: every
    /// packet is dispatched and nothing is counted.
    func testUnlimitedReceiveKeepsDispatchingEverything() {
        make(.unlimited)

        for index in 0..<50 {
            manager.parseEngineMessage("2[\"ev\",\(index)]")
        }
        drain()

        XCTAssertTrue(engine.disconnectReasons.isEmpty)
        XCTAssertEqual(manager.testReceiveBacklog.packets, 0)
    }

    // MARK: Acceptance — replay flood

    /// Connection-state-recovery packets arrive while the socket is still
    /// `.connecting`, so they are buffered rather than delivered. A peer that
    /// floods that window has no caller to report to: the connection closes,
    /// the way engine.io-client's `_onError` → `_onClose` does.
    func testRecoveryReplayFloodClosesTheConnection() throws {
        make(SocketBufferLimits(maximumRecoveryReplayPackets: 2))
        socket.setTestStatus(.connecting)
        socket._pid = "pid-1"

        var errors = [SocketBufferLimitError]()
        socket.on(clientEvent: .error) { data, _ in
            if let error = data.first as? SocketBufferLimitError { errors.append(error) }
        }

        for index in 0..<2 {
            socket.handlePacket(try manager.parseString("2[\"replayed\",\(index)]"))
        }
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 2)
        XCTAssertTrue(engine.disconnectReasons.isEmpty)

        socket.handlePacket(try manager.parseString("2[\"replayed\",2]"))

        XCTAssertEqual(errors.first?.buffer, .recoveryReplay)
        XCTAssertEqual(engine.disconnectReasons, ["transport error"])
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 0,
                       "a refused replay buffer is dropped, never partially delivered")
    }

    // MARK: Acceptance — unfinished binary packet

    /// JS waits forever for the attachments a binary header announced. With a
    /// deadline configured, a packet that never completes closes the session
    /// with `parse error` — the reason `Manager.ondata` reports when the
    /// decoder fails — and nothing is delivered from the partial packet.
    func testUnfinishedBinaryPacketIsClosedAfterItsDeadline() {
        make(SocketBufferLimits(binaryReconstructionTimeout: 0.2))
        connect()

        var received = [String]()
        socket.on("binary") { data, _ in received.append("\(data)") }

        manager.parseEngineMessage("51-[\"binary\",{\"_placeholder\":true,\"num\":0}]")
        drain()
        XCTAssertEqual(manager.waitingPackets.count, 1)
        XCTAssertTrue(manager.testHasBinaryReconstructionTimer)

        let expired = expectation(description: "reconstruction deadline")
        manager.handleQueue.asyncAfter(deadline: .now() + 0.5) { expired.fulfill() }
        wait(for: [expired], timeout: 3)

        XCTAssertEqual(engine.disconnectReasons, ["parse error"])
        XCTAssertTrue(manager.waitingPackets.isEmpty)
        XCTAssertTrue(received.isEmpty, "a partial packet is never replayed")
    }

    /// The deadline is armed per packet and disarmed by the attachment that
    /// completes it, so an ordinary binary event is unaffected.
    func testCompletedBinaryPacketDisarmsTheDeadline() {
        make(SocketBufferLimits(binaryReconstructionTimeout: 5))
        connect()

        let received = expectation(description: "binary event delivered")
        socket.on("binary") { data, _ in
            XCTAssertEqual(data.first as? Data, Data([1, 2, 3]))
            received.fulfill()
        }

        manager.parseEngineMessage("51-[\"binary\",{\"_placeholder\":true,\"num\":0}]")
        manager.parseEngineBinaryData(Data([1, 2, 3]))
        wait(for: [received], timeout: 3)
        drain()

        XCTAssertFalse(manager.testHasBinaryReconstructionTimer)
        XCTAssertTrue(engine.disconnectReasons.isEmpty)
    }

    // MARK: Acceptance — retained memory is released

    /// Gate R1 asks for proof that the bounded buffers release what they hold,
    /// not only that they stop growing.
    func testSendBufferAndReplayBufferAreReleasedOnReset() throws {
        make(SocketBufferLimits(maximumSendBufferPackets: 10, maximumRecoveryReplayPackets: 10))

        // Send buffer: filled while disconnected.
        socket.emit("buffered", String(repeating: "a", count: 32))
        drain()
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 1)
        XCTAssertGreaterThan(socket.testRetainedBuffers.sendBytes, 0)

        // Replay buffer: filled while the resumed session is still connecting.
        socket.setTestStatus(.connecting)
        socket._pid = "pid-1"
        socket.handlePacket(try manager.parseString("2[\"replayed\",\"\(String(repeating: "r", count: 32))\"]"))
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 1)
        XCTAssertGreaterThan(socket.testRetainedBuffers.replayBytes, 0)

        socket.clearRecoveryState()
        drain()

        let retained = socket.testRetainedBuffers
        XCTAssertEqual(retained.sendPackets, 0)
        XCTAssertEqual(retained.sendBytes, 0)
        XCTAssertEqual(retained.replayPackets, 0)
        XCTAssertEqual(retained.replayBytes, 0)
    }

    func testRetryQueueIsReleasedOnReset() {
        make(SocketBufferLimits(maximumRetryQueuePackets: 10), .retries(3), .ackTimeout(3600))
        connect()

        // Only the head is in flight; the second entry waits behind it.
        socket.emit("head", with: [String(repeating: "b", count: 32)], ack: { _, _ in })
        socket.emit("second", with: [String(repeating: "c", count: 32)], ack: { _, _ in })
        drain()
        XCTAssertEqual(socket.testRetainedBuffers.retryPackets, 2)
        XCTAssertGreaterThan(socket.testRetainedBuffers.retryBytes, 0)

        socket.clearRecoveryState()
        drain()

        XCTAssertEqual(socket.testRetainedBuffers.retryPackets, 0)
        XCTAssertEqual(socket.testRetainedBuffers.retryBytes, 0)
    }

    /// The accounting has to follow an ordinary drain too, not only a reset:
    /// an acknowledged head must give its bytes back or the queue would slowly
    /// refuse emits it is no longer holding.
    func testRetryQueueBytesAreReleasedWhenTheHeadIsAcknowledged() throws {
        make(SocketBufferLimits(maximumRetryQueuePackets: 10), .retries(3), .ackTimeout(3600))
        connect()

        socket.emit("head", with: [String(repeating: "b", count: 32)], ack: { _, _ in })
        drain()
        XCTAssertGreaterThan(socket.testRetainedBuffers.retryBytes, 0)

        socket.handleAck(try XCTUnwrap(manager.parseString(engine.sentPackets[0].0).id), data: [])
        drain()

        XCTAssertEqual(socket.testRetainedBuffers.retryPackets, 0)
        XCTAssertEqual(socket.testRetainedBuffers.retryBytes, 0)
    }

    /// Byte accounting must survive the partial removals too, or the buffer
    /// would slowly refuse emits it is no longer holding.
    func testByteAccountingFollowsPartialRemovals() {
        make(SocketBufferLimits(maximumSendBufferBytes: 4096), .ackTimeout(3600))

        var ids = [Int]()
        for index in 0..<3 {
            socket.timeout(after: 3600).emit("e\(index)", String(repeating: "x", count: 100), ack: { _, _ in })
            drain()
            ids.append(socket.currentAck)
        }
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 3)
        let filled = socket.testRetainedBuffers.sendBytes
        XCTAssertGreaterThan(filled, 300)

        socket.dropBufferedEmit(ack: ids[1])
        let afterDrop = socket.testRetainedBuffers
        XCTAssertEqual(afterDrop.sendPackets, 2)
        XCTAssertLessThan(afterDrop.sendBytes, filled)

        connect()
        drain()
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 0)
        XCTAssertEqual(socket.testRetainedBuffers.sendBytes, 0)
    }

    // MARK: Byte estimation

    func testRetainedBytesCountsStringsDataAndNesting() {
        XCTAssertEqual(SocketBufferLimits.retainedBytes(of: ["abc"]), 3)
        XCTAssertEqual(SocketBufferLimits.retainedBytes(of: [NSNull()]), 4)
        XCTAssertEqual(SocketBufferLimits.retainedBytes(of: [Data(count: 64)]), 64)
        XCTAssertEqual(SocketBufferLimits.retainedBytes(of: ["ev", ["k": "vv"]]), 2 + 8 + 1 + 2)
        XCTAssertGreaterThan(SocketBufferLimits.retainedBytes(of: [["a", "b"]]), 2)
    }
}

extension SocketBufferLimitsTest {
    func testCancellingAnInflightRetryReleasesItsByteBudgetForTheNextEmit() throws {
        make(SocketBufferLimits(maximumRetryQueueBytes: 9), .retries(1), .ackTimeout(100))
        connect()
        let state = SocketAsyncAckState()
        var cancelled = 0
        socket.emitTimed(event: "x", items: ["12345678"], timeout: 100, cancellation: state) { error, _ in
            XCTAssertTrue(error is CancellationError)
            cancelled += 1
        }
        XCTAssertEqual(socket.testRetainedBuffers.retryBytes, 9)
        var rejected = 0
        socket.emit("x", "12345678", ack: { error, _ in
            let limit = error as? SocketBufferLimitError
            XCTAssertEqual(limit?.buffer, .retryQueue)
            XCTAssertEqual(limit?.measuringBytes, true)
            XCTAssertEqual(limit?.attempted, 18)
            rejected += 1
        })
        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(engine.sentPackets.count, 1)
        let staleID = try manager.parseString(engine.sentPackets[0].0).id
        state.cancel()
        socket.cancelAsyncEmit(state)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(socket.testRetainedBuffers.retryBytes, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        var completed = 0
        socket.emit("x", "12345678", ack: { error, _ in
            XCTAssertNil(error)
            completed += 1
        })
        XCTAssertEqual(engine.sentPackets.count, 2)
        socket.handleAck(staleID, data: [])
        XCTAssertEqual(completed, 0)
        socket.handleAck(try manager.parseString(engine.sentPackets[1].0).id, data: [])
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(socket.testRetainedBuffers.retryBytes, 0)
        XCTAssertEqual(socket.testRetainedBuffers.retryPackets, 0)
    }

    func testPreconnectReceiveByteOverflowClearsBufferedEventsWithoutDeliveringThem() throws {
        make(SocketBufferLimits(maximumRecoveryReplayBytes: 8))
        socket.setTestStatus(.connecting)
        var deliveries = 0
        var errors: [SocketBufferLimitError] = []
        socket.on("x") { _, _ in deliveries += 1 }
        socket.on(clientEvent: .error) { data, _ in
            if let error = data.first as? SocketBufferLimitError { errors.append(error) }
        }
        socket.handlePacket(try manager.parseString("2[\"x\",\"1234567\"]"))
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 1)
        socket.handlePacket(try manager.parseString("2[\"x\",\"1234567\"]"))
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.buffer, .recoveryReplay)
        XCTAssertEqual(errors.first?.measuringBytes, true)
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 0)
        XCTAssertEqual(socket.testRetainedBuffers.replayBytes, 0)
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(engine.disconnectReasons.count, 1)
    }
}
