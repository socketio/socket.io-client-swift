//
//  SocketVolatileTest.swift
//  Socket.IO-Client-Swift
//
//  Phase 7 Task 3 — behavior tests for the volatile-emit gate. Drives a
//  `MockEngine` whose `writable` flag is test-controlled, then asserts the
//  expected drop / pass-through behavior of `socket.volatile.emit(...)`.
//
//  JS reference: `socket.io-client/lib/socket.ts emit()` body —
//      const discardPacket = this.flags.volatile && !this.io.engine?.transport?.writable;
//
//  Drop must be silent: no `.error`, no outgoing-listener fire, no buffering.
//

import XCTest
@testable import SocketIO

final class SocketVolatileTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var mockEngine: MockEngine!

    override func setUp() {
        super.setUp()
        let queue = DispatchQueue(label: "test.SocketVolatileTest.handleQueue")
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.log(false), .handleQueue(queue)])
        mockEngine = MockEngine()
        manager.engine = mockEngine
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    override func tearDown() {
        socket = nil
        mockEngine = nil
        manager = nil
        super.tearDown()
    }

    /// Block until any work already enqueued on `handleQueue` has run.
    private func drain() { manager.handleQueue.sync { } }

    func testVolatileEmitWhileWritableSends() {
        mockEngine.writable = true
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1,
                       "writable transport: volatile sends")
    }

    func testVolatileEmitWhileNotWritableDrops() {
        mockEngine.writable = false
        var errorFired = 0
        socket.on(clientEvent: .error) { _, _ in errorFired += 1 }
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 0,
                       "not-writable: volatile must drop, no engine.send")
        XCTAssertEqual(errorFired, 0,
                       "volatile drop must NOT fire .error (JS-aligned)")
    }

    func testNonVolatileEmitWhileNotWritableSurfacesErrorOrSends() {
        // Non-volatile emit on a not-writable transport: the volatile gate
        // is bypassed (volatile=false). The connected-state guard then runs;
        // since status==.connected here, the packet still goes through.
        // The engine owns transport backpressure for reliable packets.
        mockEngine.writable = false
        socket.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1,
                       "non-volatile emit still calls engine.send (Swift backcompat)")
    }

    func testVolatileEmitWhileNotConnectedDrops() {
        // Volatile gate fires BEFORE the connected check, so even with a
        // disconnected status a not-writable transport drops the packet
        // silently without adding it to the ordinary pre-connect send buffer.
        socket.setTestStatus(.disconnected)
        mockEngine.writable = false
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 0)
    }

    func testOrdinaryEventViaVolatileStillSendsWhenWritable() {
        mockEngine.writable = true
        socket.volatile.emit("foo", "x")
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1)
    }

    func testVolatileEmitArrayForm() {
        mockEngine.writable = true
        socket.volatile.emit("foo", with: ["a", "b"])
        drain()
        XCTAssertEqual(mockEngine.sentPackets.count, 1)
    }

    func testVolatileCompletionFiresEvenOnDrop() {
        mockEngine.writable = false
        var completed = false
        socket.volatile.emit("foo", "x") { completed = true }
        // The completion is hopped onto handleQueue.async — drain twice to
        // wait for both the emit work and the wrapped completion hop.
        drain()
        drain()
        XCTAssertTrue(completed,
                      "completion must fire even on drop (caller contract)")
    }
}

extension SocketVolatileTest {
    func testDroppedVolatileAcknowledgementCannotBlockReliableAcknowledgement() throws {
        for connected in [false, true] {
            try manager.handleQueue.sync {
                socket.setTestStatus(connected ? .connected : .notConnected)
                mockEngine.writable = false
                var droppedAcks = 0
                var reliableAcks = 0
                let before = mockEngine.sentPackets.count
                let previousID = socket.currentAck
                socket.volatile.emit("getId", ack: { _, _ in droppedAcks += 1 })
                XCTAssertEqual(socket.currentAck, previousID)
                XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
                XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 0)
                socket.emit("getId", ack: { error, data in
                    XCTAssertNil(error)
                    XCTAssertEqual(data.first as? String, "server-id")
                    reliableAcks += 1
                })
                mockEngine.writable = true
                if !connected { socket.didConnect(toNamespace: "/", payload: ["sid": "server-id"]) }
                XCTAssertEqual(mockEngine.sentPackets.count, before + 1)
                let packet = try manager.parseString(mockEngine.sentPackets.last!.0)
                XCTAssertEqual(packet.event, "getId")
                socket.handleAck(packet.id, data: ["server-id"])
                XCTAssertEqual(reliableAcks, 1)
                XCTAssertEqual(droppedAcks, 0)
                XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            }
        }
    }

    func testWritableVolatileAcknowledgementBypassesRetriesAndCompletesOnce() throws {
        try manager.handleQueue.sync {
            socket.retries = 2
            mockEngine.writable = true
            var calls = 0
            socket.volatile.emit("getId", with: [], ack: { error, data in
                XCTAssertNil(error)
                XCTAssertEqual(data.first as? String, "server-id")
                calls += 1
            })
            XCTAssertEqual(socket.testRetryQueueCount, 0)
            XCTAssertEqual(mockEngine.sentPackets.count, 1)
            let packet = try manager.parseString(mockEngine.sentPackets[0].0)
            XCTAssertEqual(packet.event, "getId")
            socket.handleAck(packet.id, data: ["server-id"])
            socket.handleAck(packet.id, data: ["duplicate"])
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
        }
    }

    func testDroppedVolatileAcknowledgementStillUsesConfiguredTimeout() {
        let expired = expectation(description: "dropped packet ack timeout")
        manager.handleQueue.sync {
            socket.ackTimeout = 0
            socket.retries = 3
            mockEngine.writable = false
            socket.volatile.emit("getId", ack: { error, _ in
                XCTAssertEqual(error as? SocketAckError, .timeout)
                expired.fulfill()
            })
            XCTAssertEqual(socket.testRetryQueueCount, 0)
            XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 0)
            XCTAssertTrue(mockEngine.sentPackets.isEmpty)
        }
        wait(for: [expired], timeout: 3)
        manager.handleQueue.sync { XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty) }
    }

    func testUnencodableVolatileAcknowledgementFailsBeforeRegistration() {
        manager.handleQueue.sync {
            var calls = 0
            var errors = 0
            socket.on(clientEvent: .error) { _, _ in errors += 1 }
            socket.volatile.emit("bad", ThrowingData(), ack: { error, _ in
                XCTAssertTrue(error is ThrowingData.ThrowingError)
                calls += 1
            })
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(errors, 1)
            XCTAssertEqual(socket.currentAck, -1)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            XCTAssertTrue(mockEngine.sentPackets.isEmpty)
        }
    }
}
