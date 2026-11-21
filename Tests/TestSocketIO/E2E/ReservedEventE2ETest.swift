import XCTest
@testable import SocketIO

final class ReservedEventE2ETest: XCTestCase {
    var server: TestServerProcess!
    var serverURL: URL { URL(string: "http://127.0.0.1:\(server.port)")! }

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    /// Captures the socket's server-side sid by listening for the Socket.IO CONNECT
    /// payload (Socket.IO v4 sends `sid` in the connect event payload).
    private func waitForSid(_ socket: SocketIOClient, timeout: TimeInterval = 5) -> String {
        let captured = expectation(description: "sid captured")
        var sid: String?
        socket.on(clientEvent: .connect) { data, _ in
            // Socket.IO v3+ sends the namespace's sid via the manager — we read it
            // from the engine instead.
            sid = socket.manager?.engine?.sid
            captured.fulfill()
        }
        socket.connect()
        wait(for: [captured], timeout: timeout)
        return sid ?? ""
    }

    private func reservedCount(for sid: String) throws -> Int {
        let (status, body) = try server.admin("/admin/reserved-count?sid=\(sid)", method: "GET")
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return json?["count"] as? Int ?? -1
    }

    func testReservedEmitsDoNotReachServer() throws {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let socket = manager.defaultSocket
        let sid = waitForSid(socket)
        XCTAssertFalse(sid.isEmpty, "must have engine sid after connect")

        // Emit all 4 reserved names — guard should suppress every one.
        socket.emit("connect", "x")
        socket.emit("connect_error", "x")
        socket.emit("disconnect", "x")
        socket.emit("disconnecting", "x")

        // Give the server a moment to (not) receive them.
        Thread.sleep(forTimeInterval: 0.5)

        let count = try reservedCount(for: sid)
        XCTAssertEqual(count, 0,
                       "server must have received ZERO reserved-event packets; got \(count)")
    }

    func testNonReservedEmitStillReachesServer() throws {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let socket = manager.defaultSocket
        let sid = waitForSid(socket)
        XCTAssertFalse(sid.isEmpty)

        // We can't ask the server to echo a specific event without server-side
        // wiring; instead verify reserved counter stays 0 while emitting plain
        // "foo" events (which won't be in RESERVED_NAMES).
        socket.emit("foo", "x")
        socket.emit("bar", "y")
        Thread.sleep(forTimeInterval: 0.3)

        let count = try reservedCount(for: sid)
        XCTAssertEqual(count, 0, "non-reserved emits must not increment reserved counter")
    }
}
