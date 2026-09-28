import XCTest
@testable import SocketIO

final class SocketAnyListenersTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        // Use a custom (non-main) handleQueue so the synchronous `drain()` barrier
        // below cannot deadlock when tests run on the main thread.
        let queue = DispatchQueue(label: "test.SocketAnyListenersTest.handleQueue")
        manager = SocketManager(
            socketURL: URL(string: "http://localhost")!,
            config: [.log(false), .handleQueue(queue)]
        )
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    /// Drains pending handleQueue work — call after add/remove to ensure
    /// the async mutation has happened before triggering events.
    private func drain() {
        manager.handleQueue.sync { /* barrier */ }
    }

    func testAddAnyListenerFires() {
        var captured: SocketAnyEvent?
        let id = socket.addAnyListener { event in captured = event }
        XCTAssertNotNil(id)
        drain()
        socket.handleEvent("foo", data: ["bar"], isInternalMessage: false)
        XCTAssertEqual(captured?.event, "foo")
        XCTAssertEqual(captured?.items?.first as? String, "bar")
    }

    func testAnyListenerCount() {
        XCTAssertEqual(socket.anyListenerCount, 0)
        _ = socket.addAnyListener { _ in }
        _ = socket.addAnyListener { _ in }
        drain()
        XCTAssertEqual(socket.anyListenerCount, 2)
    }

    func testRemoveAnyListenerById() {
        var firedA = 0
        var firedB = 0
        let idA = socket.addAnyListener { _ in firedA += 1 }
        _ = socket.addAnyListener { _ in firedB += 1 }
        drain()
        socket.removeAnyListener(id: idA)
        drain()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(firedA, 0, "removed listener must not fire")
        XCTAssertEqual(firedB, 1, "other listener still fires")
    }

    func testRemoveAnyListenerUnknownIdNoop() {
        socket.removeAnyListener(id: UUID())  // matches JS offAny — silent no-op
        drain()
    }

    func testRemoveAllAnyListeners() {
        var fired = 0
        _ = socket.addAnyListener { _ in fired += 1 }
        _ = socket.addAnyListener { _ in fired += 1 }
        drain()
        socket.removeAllAnyListeners()
        drain()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(socket.anyListenerCount, 0)
    }

    func testLegacyAnyHandlerStillFiresAlongsideNewListeners() {
        var legacyFired = 0
        var newFired = 0
        socket.onAny { _ in legacyFired += 1 }
        _ = socket.addAnyListener { _ in newFired += 1 }
        drain()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(legacyFired, 1)
        XCTAssertEqual(newFired, 1)
    }

    func testPrependAnyListenerFiresFirst() {
        var order: [Int] = []
        _ = socket.addAnyListener { _ in order.append(1) }
        _ = socket.addAnyListener { _ in order.append(2) }
        _ = socket.prependAnyListener { _ in order.append(0) }
        drain()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testRegistrationOrderPreserved() {
        var order: [Int] = []
        _ = socket.addAnyListener { _ in order.append(1) }
        _ = socket.addAnyListener { _ in order.append(2) }
        _ = socket.addAnyListener { _ in order.append(3) }
        drain()
        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testReturnedUUIDsAreUnique() {
        let id1 = socket.addAnyListener { _ in }
        let id2 = socket.addAnyListener { _ in }
        let id3 = socket.prependAnyListener { _ in }
        XCTAssertNotEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
        XCTAssertNotEqual(id2, id3)
    }

    func testListenerSelfRemovalDuringDispatch() {
        var ids: [UUID] = []
        var fired = [false, false, false]
        ids.append(socket.addAnyListener { _ in fired[0] = true })
        ids.append(socket.addAnyListener { [weak self] _ in
            fired[1] = true
            self?.socket.removeAnyListener(id: ids[1])  // remove self mid-dispatch
        })
        ids.append(socket.addAnyListener { _ in fired[2] = true })
        drain()

        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(fired, [true, true, true],
                       "self-removal must not break iteration; later listeners still fire")
    }

    func testListenerRegistersNewListenerMidDispatch() {
        var firedFirst = 0
        var firedSecond = 0
        _ = socket.addAnyListener { [weak self] _ in
            firedFirst += 1
            _ = self?.socket.addAnyListener { _ in firedSecond += 1 }
        }
        drain()

        socket.handleEvent("foo", data: [], isInternalMessage: false)
        XCTAssertEqual(firedFirst, 1)
        XCTAssertEqual(firedSecond, 0,
                       "newly-registered listener must NOT fire in current dispatch (snapshot semantics)")

        drain()
        socket.handleEvent("bar", data: [], isInternalMessage: false)
        XCTAssertEqual(firedSecond, 1, "newly-registered listener fires on next event")
    }

    func testAckResponseDoesNotTriggerAnyListener() {
        var fired = 0
        _ = socket.addAnyListener { _ in fired += 1 }
        drain()
        socket.emitAck(1, with: ["x"])  // ack frame — should NOT trigger via dispatchEvent
        drain()
        XCTAssertEqual(fired, 0,
                       "ack response frames flow through emit funnel, not dispatchEvent")
    }
}
