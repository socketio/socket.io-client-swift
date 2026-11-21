import Foundation
import XCTest
@testable import SocketIO

final class SocketRawViewTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var engine: MockEngine!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        engine = MockEngine()
        manager.engine = engine
        socket.didConnect(toNamespace: "/", payload: ["sid": "test"])
    }
    override func tearDown() {
        socket.clearRecoveryState()
        socket = nil; manager = nil; engine = nil
        super.tearDown()
    }
    private func drain() {
        let done = expectation(description: "owner queue drained")
        manager.handleQueue.socketAsync { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testRawEmitAndBothAcknowledgementViewsPreserveJSONAndAckIDs() throws {
        socket.rawEmitView.emit("raw", "value", 42)
        let ack = SocketAckEmitter(socket: socket, ackNum: 7)
        XCTAssertTrue(ack.expected)
        ack.rawEmitView.with("value", 42)
        ack.rawEmitView.with(["array", 43] as [Any])
        ack.with(["ordinary", 44] as [Any])
        drain()
        XCTAssertEqual(engine.sentPackets.map { $0.0 }, [
            "2[\"raw\",\"value\",42]", "37[\"value\",42]",
            "37[\"array\",43]", "37[\"ordinary\",44]"
        ])
        XCTAssertTrue(engine.sentPackets.allSatisfy { $0.1.isEmpty })
    }

    func testUnrequestedAcknowledgementIsSilentEvenForThrowingPayload() {
        var errors = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        let ack = SocketAckEmitter(socket: socket, ackNum: -1)
        XCTAssertFalse(ack.expected)
        ack.with(ThrowingData())
        ack.with([1] as [Any])
        ack.rawEmitView.with(ThrowingData())
        ack.rawEmitView.with([1] as [Any])
        drain()
        XCTAssertEqual(errors, 0)
        XCTAssertTrue(engine.sentPackets.isEmpty)
    }

    func testThrowingRepresentationsReportOnceAndSendNothingThroughEveryView() {
        var errors: [[Any]] = []
        socket.on(clientEvent: .error) { data, _ in errors.append(data) }
        socket.rawEmitView.emit("bad", ThrowingData())
        socket.rawEmitView.emitWithAck("bad", ThrowingData()).timingOut(after: 0) { _ in
            XCTFail("Invalid legacy emit cannot register an acknowledgement")
        }
        let ack = SocketAckEmitter(socket: socket, ackNum: 7)
        ack.with(ThrowingData())
        ack.rawEmitView.with(ThrowingData())
        drain()
        XCTAssertEqual(errors.count, 4)
        XCTAssertTrue(errors.allSatisfy { $0.count == 3 && $0.last is ThrowingData.ThrowingError })
        XCTAssertTrue(engine.sentPackets.isEmpty)
        XCTAssertEqual(socket.currentAck, -1)
    }

    func testRawAckRejectsBinaryBeforeAllocatingOrRegisteringAnAcknowledgement() {
        for retries in [0, 1] {
            socket.retries = retries
            var errors = 0
            let listener = socket.on(clientEvent: .error) { data, _ in
                XCTAssertTrue(data.last is SocketPacketError)
                errors += 1
            }
            let previousID = socket.currentAck
            socket.rawEmitView.emitWithAck("binary", Data([1, 2])).timingOut(after: 0) { _ in
                XCTFail("Rejected raw emit must not keep a legacy ack")
            }
            socket.rawEmitView.emitWithAck("binary", with: [Data([3])]).timingOut(after: 0) { _ in
                XCTFail("Rejected array overload must not keep a legacy ack")
            }
            drain()
            XCTAssertEqual(errors, 2)
            XCTAssertEqual(socket.currentAck, previousID)
            XCTAssertTrue(engine.sentPackets.isEmpty)
            XCTAssertEqual(socket.testRetryQueueCount, 0)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            socket.off(id: listener)
        }
    }

    func testRawLegacyAcknowledgementIsLazyAndCompletesOnce() throws {
        for arrayOverload in [false, true] {
            let before = engine.sentPackets.count
            let pending = arrayOverload
                ? socket.rawEmitView.emitWithAck("echo", with: [42])
                : socket.rawEmitView.emitWithAck("echo", 42)
            XCTAssertEqual(engine.sentPackets.count, before)
            var replies = 0
            pending.timingOut(after: 0) { data in
                XCTAssertEqual(data.first as? Int, 42)
                replies += 1
            }
            drain()
            let packet = try manager.parseString(engine.sentPackets[before].0)
            XCTAssertEqual(packet.type, .event)
            XCTAssertEqual(packet.args.first as? Int, 42)
            socket.handleAck(packet.id, data: [42])
            socket.handleAck(packet.id, data: [99])
            XCTAssertEqual(replies, 1)
        }
    }

    func testLegacyRetriesReturnNoAckOnceAndUnblockTheFollowingEvent() throws {
        socket.retries = 1
        var failures = 0
        var successes = 0
        socket.rawEmitView.emitWithAck("first", 1).timingOut(after: 100) { data in
            XCTAssertEqual(data.first as? String, SocketAckStatus.noAck.rawValue)
            failures += 1
        }
        socket.rawEmitView.emitWithAck("second", 2).timingOut(after: 100) { data in
            XCTAssertEqual(data.first as? String, "ok")
            successes += 1
        }
        for index in 0...1 {
            let id = try manager.parseString(engine.sentPackets[index].0).id
            socket.ackHandlers.cancelTimedAck(id, fireWith: SocketAckError.timeout)
            socket.handleAck(id, data: ["late"])
        }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(engine.sentPackets.count, 3)
        let last = try manager.parseString(engine.sentPackets[2].0)
        XCTAssertEqual(last.event, "second")
        socket.handleAck(last.id, data: ["ok"])
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
    }
}
