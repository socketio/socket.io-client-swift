import XCTest
@testable import SocketIO

final class SocketAnyOutgoingListenersTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        let queue = DispatchQueue(label: "test.SocketAnyOutgoingListenersTest.handleQueue")
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.log(false), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    private func drain() {
        manager.handleQueue.sync { /* barrier */ }
    }

    func testAddAnyOutgoingListener() {
        var captured: SocketAnyEvent?
        let id = socket.addAnyOutgoingListener { event in captured = event }
        XCTAssertNotNil(id)
        drain()
        socket.emit("foo", "bar")
        XCTAssertEqual(captured?.event, "foo")
        XCTAssertEqual(captured?.items?.first as? String, "bar")
    }

    func testCountAndRemoveAll() {
        XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
        _ = socket.addAnyOutgoingListener { _ in }
        _ = socket.addAnyOutgoingListener { _ in }
        drain()
        XCTAssertEqual(socket.anyOutgoingListenerCount, 2)
        socket.removeAllAnyOutgoingListeners(); drain()
        XCTAssertEqual(socket.anyOutgoingListenerCount, 0)
    }

    func testRemoveById() {
        var firedA = 0, firedB = 0
        let idA = socket.addAnyOutgoingListener { _ in firedA += 1 }
        _ = socket.addAnyOutgoingListener { _ in firedB += 1 }
        drain()
        socket.removeAnyOutgoingListener(id: idA); drain()
        socket.emit("foo", "x")
        XCTAssertEqual(firedA, 0)
        XCTAssertEqual(firedB, 1)
    }

    func testPrependFiresFirst() {
        var order: [Int] = []
        _ = socket.addAnyOutgoingListener { _ in order.append(1) }
        _ = socket.prependAnyOutgoingListener { _ in order.append(0) }
        drain()
        socket.emit("foo", "x")
        XCTAssertEqual(order, [0, 1])
    }

    func testReturnedUUIDsAreUnique() {
        let id1 = socket.addAnyOutgoingListener { _ in }
        let id2 = socket.addAnyOutgoingListener { _ in }
        let id3 = socket.prependAnyOutgoingListener { _ in }
        XCTAssertNotEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
        XCTAssertNotEqual(id2, id3)
    }

    func testRemoveUnknownIdNoop() {
        socket.removeAnyOutgoingListener(id: UUID())  // matches JS offAnyOutgoing
        drain()
    }

    func testDisconnectedEmitDoesNotFireOutgoing() {
        var fired = 0
        _ = socket.addAnyOutgoingListener { _ in fired += 1 }
        drain()
        socket.setTestStatus(.disconnected)
        socket.emit("foo", "x")  // surfaces .error, no packet, no outgoing fire
        XCTAssertEqual(fired, 0,
                       "outgoing listener must NOT fire on disconnected emit (JS-aligned)")
    }

    func testAckFramesDoNotFireOutgoing() {
        var fired = 0
        _ = socket.addAnyOutgoingListener { _ in fired += 1 }
        drain()
        socket.emitAck(1, with: ["x"])
        XCTAssertEqual(fired, 0, "ack response frames must not fire outgoing listeners")
    }

    func testNamespaceIsolation() {
        let admin = manager.socket(forNamespace: "/admin")
        admin.setTestStatus(.connected)
        var defaultFired = 0
        var adminFired = 0
        _ = socket.addAnyOutgoingListener { _ in defaultFired += 1 }
        _ = admin.addAnyOutgoingListener { _ in adminFired += 1 }
        drain()
        socket.emit("foo", "x")
        XCTAssertEqual(defaultFired, 1)
        XCTAssertEqual(adminFired, 0, "/admin listener must not see / emits")
    }

    func testEmitWithAckTriggersOutgoing() {
        // emitWithAck routes through the same funnel; the ack id is allocated
        // separately, so the outgoing listener still sees the event name + items
        // (without the internal ack id). The actual emit only happens when
        // `.timingOut(after:)` is called on the returned `OnAckCallback`.
        var captured: SocketAnyEvent?
        _ = socket.addAnyOutgoingListener { event in captured = event }
        drain()
        socket.emitWithAck("foo", "x").timingOut(after: 0) { _ in }
        XCTAssertEqual(captured?.event, "foo")
        XCTAssertEqual(captured?.items?.first as? String, "x")
    }

    // MARK: socket.ts > onAnyOutgoing — "should call listener with binary data"

    /// The listener sees the argument the caller passed, not the placeholder
    /// the encoder puts on the wire — JS hands it the `Uint8Array`, this client
    /// hands it the `Data`.
    func testCallsListenerWithBinaryData() {
        let payload = Data([1, 2, 3])
        var captured: SocketAnyEvent?
        _ = socket.addAnyOutgoingListener { event in captured = event }
        drain()

        socket.emit("my-event", payload)

        XCTAssertEqual(captured?.event, "my-event")
        XCTAssertEqual(captured?.items?.first as? Data, payload)
    }

    /// The same for binary nested inside a dictionary.
    func testCallsListenerWithNestedBinaryData() {
        let payload = Data([4, 5, 6])
        var captured: SocketAnyEvent?
        _ = socket.addAnyOutgoingListener { event in captured = event }
        drain()

        socket.emit("my-event", ["bin": payload])

        XCTAssertEqual((captured?.items?.first as? [String: Any])?["bin"] as? Data, payload)
    }
}
