import XCTest
@testable import SocketIO

final class SocketActiveE2ETest: XCTestCase {
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

    /// Critical: `active` must remain `true` across an engine-close + reconnect cycle.
    /// JS-aligned per `socket.io-client/lib/socket.ts` `get active()` returning `!!this.subs`,
    /// where `subs` is set in `connect()` and cleared only in user `disconnect()`.
    func testActiveSurvivesEngineClose() throws {
        let manager = SocketManager(socketURL: serverURL,
                                    config: [.reconnects(true), .reconnectAttempts(3),
                                             .reconnectWait(1), .log(false)])
        let socket = manager.defaultSocket

        let firstConnect = expectation(description: "first connect")
        socket.on(clientEvent: .connect) { _, _ in firstConnect.fulfill() }
        socket.connect()
        wait(for: [firstConnect], timeout: 5)

        XCTAssertTrue(socket.active, "active true after initial connect")
        // Server's `/admin/kill-transport` resolves the sid via
        // `io.sockets.sockets.get(sid)` — namespace socket id, which on the
        // client maps to `SocketIOClient.sid` (NOT the engine.io sid).
        guard let sid = socket.sid, !sid.isEmpty else {
            XCTFail("socket sid not available"); return
        }

        // Force engine-close via admin endpoint; client should auto-reconnect.
        let reconnected = expectation(description: "reconnect")
        var reconnectFired = false
        socket.on(clientEvent: .reconnect) { _, _ in
            if !reconnectFired { reconnectFired = true; reconnected.fulfill() }
        }
        let (status, _) = try server.admin("/admin/kill-transport?sid=\(sid)", method: "POST")
        XCTAssertEqual(status, 200)

        // While engine is closed and reconnecting, active MUST stay true.
        // Sample twice during the gap.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(socket.active, "active must remain true during reconnect window")

        wait(for: [reconnected], timeout: 10)
        XCTAssertTrue(socket.active, "active still true after reconnect")

        // Now user disconnect — active must flip false.
        socket.disconnect()
        XCTAssertFalse(socket.active, "active false after explicit disconnect")
    }

    func testNamespacesIndependent() {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let defaultSocket = manager.defaultSocket
        let admin = manager.socket(forNamespace: "/admin")

        let bothConnected = expectation(description: "both namespaces connect")
        bothConnected.expectedFulfillmentCount = 2
        defaultSocket.on(clientEvent: .connect) { _, _ in bothConnected.fulfill() }
        admin.on(clientEvent: .connect) { _, _ in bothConnected.fulfill() }
        defaultSocket.connect()
        admin.connect()
        wait(for: [bothConnected], timeout: 5)

        XCTAssertTrue(defaultSocket.active)
        XCTAssertTrue(admin.active)

        admin.disconnect()
        XCTAssertFalse(admin.active)
        XCTAssertTrue(defaultSocket.active, "disconnecting /admin must not affect / active")
    }
}
