import XCTest
@testable import SocketIO

final class SocketPerSocketConnectTimeoutTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.autoConnect(false), .reconnects(false)])
        manager.engine = MockEngine()
        socket = manager.defaultSocket
    }

    override func tearDown() {
        manager.disconnect()
        socket = nil
        manager = nil
        super.tearDown()
    }

    private func letTimerDeadlinePass() {
        let settled = expectation(description: "past original connect deadline")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }

    func testSuccessfulConnectCannotTimeOutLaterReconnect() {
        socket.connect(timeoutAfter: 0.02) { XCTFail("successful attempt timed out") }
        socket.didConnect(toNamespace: "/", payload: ["sid": "first"])
        socket.setReconnecting(reason: "transport close")
        letTimerDeadlinePass()
        XCTAssertEqual(socket.status, .connecting)
        XCTAssertTrue(socket.active)
    }

    func testSynchronousSuccessDuringStatusChangeCancelsDeadline() {
        var first = true
        socket.on(clientEvent: .statusChange) { [self] _, _ in
            guard first, socket.status == .connecting else { return }
            first = false
            socket.didConnect(toNamespace: "/", payload: ["sid": "sync"])
        }
        socket.connect(timeoutAfter: 0.02) { XCTFail("synchronous success timed out") }
        socket.setReconnecting(reason: "transport close")
        letTimerDeadlinePass()
        XCTAssertEqual(socket.status, .connecting)
    }

    func testNewUntimedAttemptCancelsOldDeadline() {
        socket.connect(timeoutAfter: 0.02) { XCTFail("superseded attempt timed out") }
        socket.connect()
        letTimerDeadlinePass()
        XCTAssertEqual(socket.status, .connecting)
    }

    func testDisconnectAndReconnectCancelOldDeadline() {
        socket.connect(timeoutAfter: 0.02) { XCTFail("disconnected attempt timed out") }
        socket.disconnect()
        socket.connect()
        letTimerDeadlinePass()
        XCTAssertEqual(socket.status, .connecting)
    }

    func testUnsuccessfulAttemptStillCallsHandlerExactlyOnce() {
        var calls = 0
        socket.connect(timeoutAfter: 0.02) { calls += 1 }
        letTimerDeadlinePass()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(socket.status, .disconnected)
        XCTAssertTrue(socket.active, "a namespace timeout remains reconnectable")
        XCTAssertTrue(manager.nsps[socket.nsp] === socket)
        XCTAssertTrue((manager.engine as! MockEngine).disconnectReasons.isEmpty)
    }

    func testTimeoutNotifiesDisconnectAndClearsOnlyUnbufferedAcks() {
        var events = [String]()
        socket.on(clientEvent: .disconnect) { _, _ in events.append("disconnect") }
        socket.connect(timeoutAfter: 0.02) { events.append("timeout") }
        socket.ackHandlers.addTimedAck(99, on: manager.handleQueue, callback: { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            events.append("ack")
        }, timeout: 10)
        socket.timeout(after: 10).emit("buffered", ack: { _, _ in
            XCTFail("an unsent packet must keep its acknowledgement")
        })

        letTimerDeadlinePass()

        XCTAssertEqual(events, ["disconnect", "ack", "timeout"])
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [0])
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 1)
    }

    func testStatusChangeReconnectKeepsReplacementDeadline() {
        let replacementTimedOut = expectation(description: "replacement attempt times out")
        var replaced = false
        var disconnects = 0
        socket.on(clientEvent: .disconnect) { _, _ in disconnects += 1 }
        socket.on(clientEvent: .statusChange) { [self] _, _ in
            guard !replaced, socket.status == .disconnected else { return }
            replaced = true
            socket.connect(timeoutAfter: 0.02) { replacementTimedOut.fulfill() }
        }
        socket.connect(timeoutAfter: 0.02) { XCTFail("superseded timeout handler ran") }

        wait(for: [replacementTimedOut], timeout: 1)

        XCTAssertTrue(replaced)
        XCTAssertEqual(disconnects, 2)
        XCTAssertEqual(socket.status, .disconnected)
        XCTAssertTrue(socket.active)
    }

    private func assertTimeoutCallbackCanReconnect(on event: SocketClientEvent) {
        manager.setTestStatus(.connected)
        var replaced = false
        var replies = 0
        socket.on(clientEvent: event) { [self] _, _ in
            guard !replaced, socket.status == .disconnected else { return }
            replaced = true
            socket.connect()
            socket.didConnect(toNamespace: "/", payload: ["sid": "replacement"])
            socket.timeout(after: 10).emit("replacement", ack: { error, _ in
                XCTAssertNil(error)
                replies += 1
            })
        }
        socket.connect(timeoutAfter: 0.02) { XCTFail("superseded timeout handler ran") }

        letTimerDeadlinePass()

        XCTAssertTrue(replaced)
        XCTAssertEqual(socket.status, .connected)
        XCTAssertEqual(socket.sid, "replacement")
        XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, [0])
        let packets = (manager.engine as! MockEngine).sentPackets.map { $0.0 }
        XCTAssertEqual(Array(packets.prefix(3)), ["0/,", "1/,", "0/,"],
                       "the old namespace must leave before the replacement joins")
        socket.handleAck(0, data: ["ok"])
        XCTAssertEqual(replies, 1)
    }

    func testStatusChangeReconnectPreservesNewSessionAndAck() {
        assertTimeoutCallbackCanReconnect(on: .statusChange)
    }

    func testDisconnectCallbackCanReconnectWithoutOldTimeoutHandler() {
        assertTimeoutCallbackCanReconnect(on: .disconnect)
    }

    func testAuthChangesDoNotCancelConnectTimeout() {
        var calls = 0
        socket.connect(timeoutAfter: 0.02) { calls += 1 }
        socket.setAuth { callback in callback(["token": "new"]) }
        socket.clearAuth()

        letTimerDeadlinePass()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(socket.status, .disconnected)
    }

    func testResetBeforeSuccessStillReportsTimeout() {
        var calls = 0
        socket.connect(timeoutAfter: 0.02) { calls += 1 }
        socket.abortPendingConnect()
        letTimerDeadlinePass()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(socket.status, .notConnected)
    }
}
