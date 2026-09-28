import XCTest
@testable import SocketIO

/// Phase 9 — Bundle 3: E2E coverage for `socket.timeout(after:).emit(...)`
/// against the real Node socket.io test server.
///
/// Mirrors the JS reference behavior:
/// - Server ack arrives within window  → `(nil, [pong])`
/// - Server never acks within window   → `(.timeout, [])`
final class SocketTimedEmitterE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var managers = [SocketManager]()

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        managers.removeAll()
        super.tearDown()
    }

    private func makeClient() -> (SocketManager, SocketIOClient) {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        let manager = SocketManager(socketURL: url, config: [.log(false), .reconnects(false)])
        managers.append(manager)
        return (manager, manager.defaultSocket)
    }

    func testServerAckArrivesBeforeTimeout() {
        let (_, socket) = makeClient()
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let acked = expectation(description: "server ack")
        socket.timeout(after: 2).emit("ping") { err, data in
            XCTAssertNil(err)
            XCTAssertEqual(data.first as? String, "pong")
            acked.fulfill()
        }
        wait(for: [acked], timeout: 3)
    }

    func testTimeoutWhenServerNeverAcks() {
        let (_, socket) = makeClient()
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let timedOut = expectation(description: ".timeout")
        socket.timeout(after: 0.3).emit("never_ack") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 2)
    }
}
