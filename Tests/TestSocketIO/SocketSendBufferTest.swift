import XCTest
@testable import SocketIO

/// JS keeps an emit made while the socket is not connected in `socket.sendBuffer`
/// and writes it on the next CONNECT (`emit()` / `emitBuffered()` in
/// `socket.io-client/lib/socket.ts`). This client used to drop it and report
/// "Tried emitting when not connected" instead.
final class SocketSendBufferTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var engine: CaptureEngine!

    override func setUp() {
        super.setUp()

        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        engine = CaptureEngine()
        manager.engine = engine
    }

    private func connect() {
        socket.didConnect(toNamespace: "/", payload: ["sid": "s1"])
    }

    private func expectedPacket(_ data: [Any], ack: Int = -1) -> String {
        return SocketPacket.packetFromEmit(data, id: ack, nsp: "/", ack: false).packetString
    }

    func testEmitWhileDisconnectedIsSentOnConnect() {
        socket.emit("msg", "hello")

        XCTAssertTrue(engine.sentPackets.isEmpty, "Nothing can go out before the socket is connected")

        connect()

        XCTAssertEqual(engine.sentPackets, [expectedPacket(["msg", "hello"])])
    }

    func testBufferedEmitsKeepTheirOrder() {
        socket.emit("first", "1")
        socket.emit("second", "2")
        socket.emit("third", "3")

        connect()

        XCTAssertEqual(engine.sentPackets, [
            expectedPacket(["first", "1"]),
            expectedPacket(["second", "2"]),
            expectedPacket(["third", "3"])
        ])
    }

    func testNoErrorIsReportedForABufferedEmit() {
        var errors = [[Any]]()
        socket.on(clientEvent: .error) { data, _ in errors.append(data) }

        socket.emit("msg", "hello")
        connect()

        XCTAssertTrue(errors.isEmpty, "A buffered emit is owed, not a failure")
    }

    /// The buffer is what survives a disconnect — clearing it would be the very
    /// data loss this exists to prevent.
    func testBufferSurvivesADisconnectAndFlushesOnReconnect() {
        connect()
        socket.didDisconnect(reason: "transport close")

        socket.emit("while-down", "x")
        XCTAssertTrue(engine.sentPackets.isEmpty)

        connect()

        XCTAssertEqual(engine.sentPackets, [expectedPacket(["while-down", "x"])])
    }

    /// JS fires the outgoing listeners in `emitBuffered()`, i.e. when the packet
    /// is actually written, not when it was handed to the buffer.
    func testOutgoingListenersFireWhenTheBufferIsFlushed() {
        var seen = [String]()
        _ = socket.addAnyOutgoingListener { event in seen.append(event.event) }

        // Listener registration is serialized through handleQueue, so let it land
        // before emitting.
        let registered = expectation(description: "listener registered")
        manager.handleQueue.socketAsync { registered.fulfill() }
        wait(for: [registered], timeout: 2)

        socket.emit("msg", "hello")
        XCTAssertTrue(seen.isEmpty, "Nothing has been written yet")

        connect()

        XCTAssertEqual(seen, ["msg"])
    }

    /// Ack *responses* are not buffered: JS does not queue them either, and
    /// replaying one into a session the server no longer knows is meaningless.
    func testAckResponsesAreNotBuffered() {
        let reported = expectation(description: ".error fired")
        socket.on(clientEvent: .error) { _, _ in reported.fulfill() }

        socket.emitAck(7, with: ["ok"])

        wait(for: [reported], timeout: 1)
        XCTAssertTrue(engine.sentPackets.isEmpty)

        connect()

        XCTAssertTrue(engine.sentPackets.isEmpty, "A stale ack must not surface on the next connect")
    }

    /// JS removes the packet from `sendBuffer` when its ack times out
    /// (`_registerAckCallback`), so an emit the caller already gave up on is not
    /// delivered later by a reconnect.
    func testATimedOutEmitIsDroppedFromTheBuffer() {
        let timedOut = expectation(description: "ack times out")

        socket.timeout(after: 0.05).emit("event") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            XCTAssertEqual(self.socket.testRetainedBuffers.sendPackets, 0)
            timedOut.fulfill()
        }

        wait(for: [timedOut], timeout: 2)

        connect()

        XCTAssertTrue(engine.sentPackets.isEmpty, "The caller already saw this emit fail")
    }

    /// `clearRecoveryState()` is the identity-swap path. Unlike a disconnect, the
    /// previous user's queued events must not reach the successor session.
    func testClearRecoveryStateDropsTheBuffer() {
        socket.emit("previous-user", "secret")

        socket.clearRecoveryState()
        connect()

        XCTAssertTrue(engine.sentPackets.isEmpty, "Queued events must not cross an identity change")
    }

    /// JS `_clearAcks` skips acks whose packet is still buffered: it has not
    /// reached the server, so the ack is still owed after the reconnect.
    func testABufferedEmitsAckIsNotFailedOnDisconnect() {
        var outcomes = [Error?]()

        socket.timeout(after: 10).emit("msg", "hello") { err, _ in outcomes.append(err) }

        // Let emitTimed's handleQueue hop register the ack before disconnecting.
        let registered = expectation(description: "ack registered")
        manager.handleQueue.socketAsync { registered.fulfill() }
        wait(for: [registered], timeout: 2)

        socket.didDisconnect(reason: "transport close")

        let settled = expectation(description: "clearTimedAcks ran")
        manager.handleQueue.socketAsync { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(outcomes.isEmpty, "The packet never left, so its ack is still outstanding")

        connect()

        XCTAssertEqual(engine.sentPackets.count, 1, "And it goes out once the socket is back")
    }
}
