import Foundation
import XCTest
@testable import SocketIO

/// Invalid implicit acknowledgements must never take ownership of the retry head.
final class SocketRetryTimeoutValidationTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var engine: MockEngine!

    private func make(timeout: Double? = nil, retries: Int = 1) {
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.retries(retries)])
        manager.ackTimeout = timeout
        socket = manager.defaultSocket
        engine = MockEngine()
        manager.engine = engine
        socket.didConnect(toNamespace: "/", payload: ["sid": "first"])
    }

    private func drain() {
        let barrier = expectation(description: "handle queue barrier")
        manager.handleQueue.socketAsync { barrier.fulfill() }
        wait(for: [barrier], timeout: 3)
    }

    private func packet(_ position: Int) throws -> SocketPacket {
        guard engine.sentPackets.indices.contains(position) else {
            XCTFail("Expected an outgoing packet at index \(position)")
            throw NSError(domain: "SocketRetryTimeoutValidationTest", code: 1)
        }
        return try manager.parseString(engine.sentPackets[position].0)
    }

    override func tearDown() {
        if socket != nil {
            socket.clearRecoveryState()
            drain()
        }
        socket = nil
        engine = nil
        manager = nil
        super.tearDown()
    }

    func testMissingTimeoutRejectsPlainEmitBeforeQueueing() throws {
        make()
        var errors = [[Any]]()
        var completions = 0
        socket.on(clientEvent: .error) { data, _ in errors.append(data) }

        socket.emit("unacknowledged", 42, completion: { completions += 1 })

        XCTAssertEqual(errors.count, 1, "missing finite timeout must emit a configuration error")
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertEqual(socket.currentAck, -1)
        XCTAssertEqual(completions, 0, "local completion remains asynchronous")
        drain()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        let errorData = try XCTUnwrap(errors.first)
        XCTAssertEqual(errorData.first as? String, "unacknowledged")
        XCTAssertEqual(errorData.count, 3)
        let error = try XCTUnwrap(errorData.last as? NSError)
        XCTAssertEqual(error.domain, "SocketIO.Emit")
        XCTAssertEqual(error.code, 2)
        XCTAssertTrue(error.localizedDescription.contains("ackTimeout"))
    }

    func testNonFiniteOrNegativeTimeoutsAlsoRejectPlainEmits() {
        make()
        var errors = 0
        var completions = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        for timeout in [Double.infinity, -Double.infinity, Double.nan, -1] {
            manager.ackTimeout = timeout
            socket.emit("invalid-timeout", completion: { completions += 1 })
            XCTAssertEqual(socket.testRetryQueueCount, 0)
        }
        drain()
        XCTAssertEqual(errors, 4)
        XCTAssertEqual(completions, 4)
        XCTAssertEqual(socket.currentAck, -1)
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testDisconnectedRejectionIsNotBufferedForTheNextConnection() {
        make()
        socket.setTestStatus(.disconnected)
        var errors = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        socket.emit("must-not-be-buffered")
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        drain()
        socket.didConnect(toNamespace: "/", payload: ["sid": "replacement"])
        drain()
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testRejectedEmitDoesNotBlockTheFollowingAcknowledgedEmit() throws {
        make()
        var replies = 0
        socket.emit("rejected")
        socket.emit("next", ack: { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? String, "ok")
            replies += 1
        })
        drain()
        XCTAssertEqual(engine.sentPackets.count, 1)
        let next = try packet(0)
        XCTAssertEqual(next.event, "next")
        XCTAssertEqual(next.id, 0, "a rejected emit must not allocate an acknowledgement ID")
        socket.handleAck(next.id, data: ["ok"])
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testErrorHandlerCanCorrectTheConfigurationAndEmitAgain() throws {
        make()
        var errors = 0
        var completions = 0
        socket.on(clientEvent: .error) { [self] _, _ in
            errors += 1
            manager.ackTimeout = 3600
            socket.emit("corrected")
        }
        socket.emit("rejected", completion: { completions += 1 })
        drain()
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(engine.sentPackets.count, 1)
        let corrected = try packet(0)
        XCTAssertEqual(corrected.event, "corrected")
        XCTAssertEqual(corrected.id, 0)
        socket.handleAck(corrected.id, data: [])
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    func testFiniteTimeoutRetainsRetryBudgetAndQueueProgress() throws {
        make(timeout: 3600)
        var completions = 0
        socket.emit("first", completion: { completions += 1 })
        socket.emit("second", completion: { completions += 1 })
        drain()
        XCTAssertEqual(engine.sentPackets.count, 1)
        // Drive the same timeout settlement deterministically, without sleeps.
        for position in 0..<4 {
            let current = try packet(position)
            socket.ackHandlers.cancelTimedAck(current.id, fireWith: SocketAckError.timeout)
        }
        drain()
        XCTAssertEqual(engine.sentPackets.count, 4)
        XCTAssertEqual(try (0..<4).map { try packet($0).event }, ["first", "first", "second", "second"])
        XCTAssertEqual(try (0..<4).map { try packet($0).id }, [0, 1, 2, 3])
        XCTAssertEqual(completions, 2, "one local completion per emit, not per retry")
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testExplicitAcknowledgementsPreserveNilAndInfiniteTimeouts() throws {
        make()
        var replies = 0
        for (index, timeout) in ([nil, Double.infinity] as [Double?]).enumerated() {
            manager.ackTimeout = timeout
            socket.emit("explicit-ack", ack: { error, _ in
                XCTAssertNil(error)
                replies += 1
            })
            drain()
            XCTAssertEqual(socket.testRetryQueueCount, 1)
            let outgoing = try packet(index)
            XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [outgoing.id])
            XCTAssertEqual(replies, index)
            socket.handleAck(outgoing.id, data: [])
            XCTAssertEqual(socket.testRetryQueueCount, 0)
        }
        XCTAssertEqual(replies, 2)
    }

    func testPerEmitFiniteTimeoutOverridesAnInfiniteDefault() throws {
        make(timeout: .infinity)
        var replies = 0
        socket.timeout(after: 3600).emit("per-emit", ack: { error, _ in
            XCTAssertNil(error)
            replies += 1
        })
        drain()
        XCTAssertEqual(engine.sentPackets.count, 1)
        socket.handleAck(try packet(0).id, data: [])
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    func testPlainEmitWithoutRetriesStillSendsWithoutATimeout() throws {
        make(retries: 0)
        var errors = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        socket.emit("plain")
        drain()
        XCTAssertEqual(engine.sentPackets.count, 1)
        XCTAssertEqual(try packet(0).id, -1)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testArrayEmitAndSendWrappersUseTheSameValidation() {
        make()
        var errors = 0
        var completions = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        socket.emit("array", with: [1], completion: { completions += 1 })
        socket.send(2, completion: { completions += 1 })
        socket.send(with: [3], completion: { completions += 1 })
        drain()
        XCTAssertEqual(errors, 3)
        XCTAssertEqual(completions, 3)
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }

    func testVolatileEmitStillBypassesRetriesWithoutATimeout() throws {
        make()
        var errors = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        socket.volatile.emit("volatile")
        drain()
        XCTAssertEqual(engine.sentPackets.count, 1)
        XCTAssertEqual(try packet(0).id, -1)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }
}
