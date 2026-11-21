import XCTest
@testable import SocketIO

final class AutoConnectE2ETest: XCTestCase {
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

    func testAutoConnectJoinsDefaultSocket() {
        let manager = SocketManager(
            socketURL: serverURL,
            config: [.autoConnect(true), .log(false)]
        )

        let connected = expectation(description: "defaultSocket connects")
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            connected.fulfill()
        }

        wait(for: [connected], timeout: 5)
        XCTAssertEqual(manager.defaultSocket.status, .connected)
    }

    func testAutoConnectJoinsNewNamespaceAfterEngineOpen() {
        let manager = SocketManager(socketURL: serverURL, config: [.autoConnect(true), .log(false)])
        defer { manager.disconnect() }
        let defaultReady = expectation(description: "defaultSocket ready")
        manager.defaultSocket.once(clientEvent: .connect) { _, _ in defaultReady.fulfill() }
        wait(for: [defaultReady], timeout: 5)

        let admin = manager.socket(forNamespace: "/admin")
        let joined = expectation(description: "new namespace auto-connects")
        admin.once(clientEvent: .connect) { _, _ in joined.fulfill() }
        wait(for: [joined], timeout: 5)
        XCTAssertEqual(admin.status, .connected)
    }

    func testAutoConnectFalseRequiresExplicitConnectForNewNamespace() {
        let manager = SocketManager(socketURL: serverURL, config: [.autoConnect(false)])
        defer { manager.disconnect() }
        let ready = expectation(description: "defaultSocket ready")
        manager.defaultSocket.once(clientEvent: .connect) { _, _ in ready.fulfill() }
        manager.defaultSocket.connect()
        wait(for: [ready], timeout: 5)

        let admin = manager.socket(forNamespace: "/admin")
        let silent = expectation(description: "new namespace stays inactive")
        silent.isInverted = true
        let token = admin.on(clientEvent: .connect) { _, _ in silent.fulfill() }
        wait(for: [silent], timeout: 0.2)
        admin.off(id: token)
        XCTAssertFalse(admin.active)
        let joined = expectation(description: "explicit connect joins")
        admin.once(clientEvent: .connect) { _, _ in joined.fulfill() }
        admin.connect()
        wait(for: [joined], timeout: 5)
        XCTAssertEqual(admin.status, .connected)
    }

    func testAutoConnectFalseLeavesDefaultDisconnected() {
        let manager = SocketManager(
            socketURL: serverURL,
            config: [.log(false)]  // autoConnect defaults false
        )

        let noConnect = expectation(description: "no auto-connect")
        noConnect.isInverted = true
        manager.defaultSocket.on(clientEvent: .connect) { _, _ in
            noConnect.fulfill()
        }
        wait(for: [noConnect], timeout: 1)

        XCTAssertEqual(manager.status, .notConnected)
        XCTAssertNil(manager.engine)
    }
}
