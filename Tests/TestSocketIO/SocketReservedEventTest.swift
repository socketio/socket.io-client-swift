import XCTest
@testable import SocketIO

final class SocketReservedEventTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var errorCaptures: [[Any]]!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        socket = manager.defaultSocket
        errorCaptures = []
        socket.on(clientEvent: .error) { [weak self] data, _ in
            self?.errorCaptures.append(data)
        }
        socket.setTestStatus(.connected)
    }

    func testReservedConnectEmitFiresErrorClientEvent() {
        socket.emit("connect", "x")
        XCTAssertEqual(errorCaptures.count, 1, "user .on(clientEvent: .error) listener must fire for reserved emit")
        let payload = errorCaptures.first?.first as? String
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload!.contains("connect"), "error message must mention the reserved name")
        XCTAssertTrue(payload!.contains("reserved"), "error message must say 'reserved'")
    }

    func testOriginalReservedDisconnectingEmitFailsBeforeBuffering() {
        let socket = manager.socket(forNamespace: "/no")
        var errors = [String]()
        socket.on(clientEvent: .error) { data, _ in
            if let message = data.first as? String { errors.append(message) }
        }
        socket.emit("disconnecting", "goodbye")
        XCTAssertEqual(errors, ["\"disconnecting\" is a reserved event name"])
        XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 0)
    }

    func testAllFourReservedNamesFire() {
        for name in ["connect", "connect_error", "disconnect", "disconnecting"] {
            errorCaptures = []
            socket.emit(name, "x")
            XCTAssertEqual(errorCaptures.count, 1, "\(name) must fire .error clientEvent")
        }
    }

    func testCaseSensitivity() {
        socket.emit("Connect", "x")
        socket.emit("CONNECT", "x")
        XCTAssertEqual(errorCaptures.count, 0, "case variants must NOT trigger guard")
    }

    func testWhitespaceVariant() {
        socket.emit(" connect", "x")
        XCTAssertEqual(errorCaptures.count, 0, "whitespace variants must NOT trigger guard")
    }

    func testNormalEventEmits() {
        socket.emit("foo", "x")
        XCTAssertEqual(errorCaptures.count, 0, "non-reserved emit must not trigger guard")
    }

    func testEmitAckIsAckTrueDoesNotTrigger() {
        // emitAck(_:with:) calls internal emit(..., isAck: true) — first item of an ack frame
        // is the ack id, not an event name; reserved guard must not fire even if items
        // happen to start with a reserved-name string.
        socket.emitAck(1, with: ["connect"])
        XCTAssertEqual(errorCaptures.count, 0, "isAck=true frames must bypass reserved guard")
    }

    func testRawViewReservedEmitTriggersGuard() {
        // SocketRawView.emit calls the internal funnel directly — guard placement
        // at the funnel ensures raw-view callers are also covered.
        socket.rawEmitView.emit("connect", "x")
        XCTAssertEqual(errorCaptures.count, 1, "SocketRawView.emit must trigger reserved guard")
    }

    func testRawViewWithItemsArrayCovered() {
        socket.rawEmitView.emit("disconnect", with: ["x"] as [Any])
        XCTAssertEqual(errorCaptures.count, 1, "SocketRawView.emit(with:) must trigger reserved guard")
    }
}
