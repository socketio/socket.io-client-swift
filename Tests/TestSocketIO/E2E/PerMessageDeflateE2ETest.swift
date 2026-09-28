import XCTest
@testable import SocketIO

/// Reproduction for a device log in which every WebSocket upgrade against a
/// server that negotiated `permessage-deflate` failed right after
/// "Switching to WebSockets" with "Socket is not connected", forcing a
/// reconnect loop. The fixture server never negotiated the extension before.
final class PerMessageDeflateE2ETest: XCTestCase {
    var server: TestServerProcess!
    var manager: SocketManager!

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start(extraEnvironment: ["PER_MESSAGE_DEFLATE": "1"])
    }

    override func tearDown() {
        manager?.disconnect()
        manager = nil
        server.stop()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval) {
        let done = expectation(description: "settled")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    func testUpgradeSurvivesPerMessageDeflateAndCarriesAnAck() {
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                                config: [.log(true), .reconnectWait(1)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "connect")
        connected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        let upgraded = expectation(description: "websocket upgrade headers")
        upgraded.assertForOverFulfill = false
        var upgradeHeaders = [String: String]()
        socket.on(clientEvent: .websocketUpgrade) { data, _ in
            upgradeHeaders = data.first as? [String: String] ?? [:]
            upgraded.fulfill()
        }
        var disconnects = [String]()
        socket.on(clientEvent: .disconnect) { data, _ in disconnects.append(String(describing: data.first ?? "")) }
        var reconnectAttempts = 0
        socket.on(clientEvent: .reconnectAttempt) { _, _ in reconnectAttempts += 1 }
        var errors = [String]()
        socket.on(clientEvent: .error) { data, _ in errors.append(String(describing: data)) }

        socket.connect()
        wait(for: [connected, upgraded], timeout: 10)
        let extensions = upgradeHeaders.first { $0.key.lowercased() == "sec-websocket-extensions" }?.value ?? ""
        XCTAssertTrue(extensions.contains("permessage-deflate"), "server must negotiate deflate: \(upgradeHeaders)")

        // Give the engine time to send the upgrade packet over the WebSocket and
        // the polling transport time to retire.
        settle(2)
        XCTAssertEqual(manager.engine?.polling, false, "engine should be on the WebSocket now")
        XCTAssertEqual(manager.engine?.connected, true)

        let acked = expectation(description: "echo over the WebSocket is acknowledged")
        socket.emit("echo", "deflate", ack: { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? String, "deflate")
            acked.fulfill()
        })
        wait(for: [acked], timeout: 5)
        settle(1)
        XCTAssertEqual(disconnects, [])
        XCTAssertEqual(reconnectAttempts, 0)
        XCTAssertEqual(errors, [])
    }
}
