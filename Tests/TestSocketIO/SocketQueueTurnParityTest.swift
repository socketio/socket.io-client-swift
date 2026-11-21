import XCTest
@testable import SocketIO

/// No drain/barrier is inserted between a listener mutation and its event.
/// All operations obey the documented serial handleQueue contract.
final class SocketQueueTurnParityTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var engine: MockEngine!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "test.parity.same-turn")
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.handleQueue(queue), .autoConnect(false), .log(false)])
        socket = manager.defaultSocket
        engine = MockEngine()
        manager.engine = engine
    }

    override func tearDown() {
        queue.sync { socket.clearRecoveryState() }
        queue.sync { }
        socket = nil; manager = nil; engine = nil; queue = nil
        super.tearDown()
    }

    func testOutgoingRegistrationAndBinaryEmitInConnectCallbackSameTurn() {
        queue.sync {
            var seen: [String] = []
            let binary = Data([1, 2, 3])
            socket.on(clientEvent: .connect) { [self] _, _ in
                socket.addAnyOutgoingListener { event in
                    seen.append(event.event)
                    XCTAssertEqual(event.items?.first as? Data, binary)
                }
                socket.emit("my-event", binary)
                XCTAssertEqual(seen, ["my-event"])
            }
            socket.didConnect(toNamespace: "/", payload: ["sid": "s"])
            XCTAssertEqual(seen, ["my-event"])
            XCTAssertEqual(engine.sentPackets.count, 1)
        }
    }

    func testOutgoingRemovalPreventsImmediatelyFollowingEmit() {
        queue.sync {
            socket.setTestStatus(.connected)
            var calls = 0
            let id = socket.addAnyOutgoingListener { _ in calls += 1 }
            socket.emit("before")
            XCTAssertEqual(calls, 1)
            socket.removeAnyOutgoingListener(id: id)
            XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
            socket.emit("after")
            XCTAssertEqual(calls, 1)
        }
    }

    func testOutgoingRemoveAllPreventsImmediatelyFollowingEmit() {
        queue.sync {
            socket.setTestStatus(.connected)
            socket.addAnyOutgoingListener { _ in XCTFail("removed listener") }
            socket.prependAnyOutgoingListener { _ in XCTFail("removed listener") }
            socket.removeAllAnyOutgoingListeners()
            XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
            socket.emit("after")
        }
    }

    func testOutgoingMultiplePrependsPreserveOrderInSameTurn() {
        queue.sync {
            socket.setTestStatus(.connected)
            var order: [Int] = []
            socket.addAnyOutgoingListener { _ in order.append(2) }
            socket.prependAnyOutgoingListener { _ in order.append(1) }
            socket.prependAnyOutgoingListener { _ in order.append(0) }
            socket.emit("my-event", "123")
            XCTAssertEqual(order, [0, 1, 2])
        }
    }

    func testIncomingRegistrationAndRemovalInSameTurn() {
        queue.sync {
            socket.setTestStatus(.connected)
            var seen: [String] = []
            let id = socket.addAnyListener { seen.append($0.event) }
            socket.handleEvent("first", data: [], isInternalMessage: false)
            socket.removeAnyListener(id: id)
            socket.handleEvent("second", data: [], isInternalMessage: false)
            XCTAssertEqual(seen, ["first"])
            XCTAssertEqual(socket.anyListenerCount, 0)
        }
    }

    func testIncomingMultiplePrependsAndRemoveAllInSameTurn() {
        queue.sync {
            socket.setTestStatus(.connected)
            var order: [Int] = []
            socket.addAnyListener { _ in order.append(2) }
            socket.prependAnyListener { _ in order.append(1) }
            socket.prependAnyListener { _ in order.append(0) }
            socket.handleEvent("first", data: [], isInternalMessage: false)
            XCTAssertEqual(order, [0, 1, 2])
            socket.removeAllAnyListeners()
            socket.handleEvent("second", data: [], isInternalMessage: false)
            XCTAssertEqual(order, [0, 1, 2])
            XCTAssertEqual(socket.anyListenerCount, 0)
        }
    }

    func testIncomingSelfRemovalDoesNotDisturbCurrentSnapshot() {
        queue.sync {
            socket.setTestStatus(.connected)
            var seen: [String] = []
            var id: UUID!
            id = socket.addAnyListener { [self] _ in
                seen.append("self")
                socket.removeAnyListener(id: id)
            }
            socket.addAnyListener { _ in seen.append("other") }
            socket.handleEvent("first", data: [], isInternalMessage: false)
            socket.handleEvent("second", data: [], isInternalMessage: false)
            XCTAssertEqual(seen, ["self", "other", "other"])
        }
    }

    func testOutgoingMutationUsesSnapshotButNextEmitSeesNewListener() {
        queue.sync {
            socket.setTestStatus(.connected)
            var seen: [String] = []
            var installed = false
            socket.addAnyOutgoingListener { [self] _ in
                seen.append("first")
                if !installed {
                    installed = true
                    socket.addAnyOutgoingListener { _ in seen.append("new") }
                }
            }
            socket.emit("one")
            XCTAssertEqual(seen, ["first"])
            socket.emit("two")
            XCTAssertEqual(seen, ["first", "first", "new"])
        }
    }

    func testModernIncomingListenersExcludeLifecycleEventsButLegacyStillSeesThem() {
        queue.sync {
            var modern: [String] = []
            var legacy: [String] = []
            socket.addAnyListener { modern.append($0.event) }
            socket.onAny { legacy.append($0.event) }
            socket.didConnect(toNamespace: "/", payload: ["sid": "s"])
            socket.handleEvent("application", data: [], isInternalMessage: false)
            socket.didDisconnect(reason: "test")
            XCTAssertEqual(modern, ["application"])
            XCTAssertEqual(legacy, ["statusChange", "connect", "application", "statusChange", "disconnect"])
        }
    }

    func testOffQueueRegistrationStillSerializesOnTheOwnerQueue() {
        var seen: [String] = []
        socket.addAnyOutgoingListener { event in
            XCTAssertTrue(self.manager.isOnHandleQueue)
            seen.append(event.event)
        }
        queue.sync {
            socket.setTestStatus(.connected)
            socket.emit("queued-registration")
            XCTAssertEqual(seen, ["queued-registration"])
        }
    }

    func testTerminalDisconnectClearsModernAcksBeforeReturningOnOwnerQueue() {
        queue.sync {
            socket.setTestStatus(.connected)
            var order: [String] = []
            socket.on(clientEvent: .disconnect) { _, _ in order.append("disconnect") }
            socket.timeout(after: 60).emit("pending") { error, _ in
                XCTAssertEqual(error as? SocketAckError, .disconnected)
                order.append("ack")
            }
            XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs.count, 1)
            socket.didDisconnect(reason: "test")
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            XCTAssertEqual(order, ["disconnect", "ack"])
        }
    }

    func testReentrantDisconnectListenerCannotSweepSuccessorAck() {
        queue.sync {
            socket.setTestStatus(.connected)
            var oldCalls = 0
            var newCalls = 0
            socket.timeout(after: 60).emit("old") { error, _ in
                XCTAssertEqual(error as? SocketAckError, .disconnected)
                oldCalls += 1
            }
            var replacementID: Int?
            socket.on(clientEvent: .disconnect) { [self] _, _ in
                socket.didConnect(toNamespace: "/", payload: ["sid": "replacement"])
                socket.timeout(after: 60).emit("new") { error, _ in
                    XCTAssertNil(error); newCalls += 1
                }
                replacementID = socket.currentAck
            }
            socket.setReconnecting(reason: "transport close")
            XCTAssertEqual(oldCalls, 1)
            XCTAssertEqual(newCalls, 0)
            XCTAssertEqual(socket.ackHandlers.pendingTimedAckIDs, Set([replacementID!]))
            socket.handleAck(replacementID!, data: ["ok"])
            XCTAssertEqual(newCalls, 1)
        }
    }
}
