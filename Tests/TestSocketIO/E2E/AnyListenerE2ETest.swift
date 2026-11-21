import XCTest
@testable import SocketIO

final class AnyListenerE2ETest: XCTestCase {
    var server: TestServerProcess!
    var serverURL: URL { URL(string: "http://127.0.0.1:\(server.port)")! }

    override func setUp() {
        super.setUp(); server = try! TestServerProcess.start()
    }
    override func tearDown() {
        server.stop(); super.tearDown()
    }

    func testAnyListenerCatchesServerEmittedEvent() throws {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let received = expectation(description: "any-listener fires")
        var capturedEvent: String?
        var capturedItems: [Any]?
        _ = socket.addAnyListener { event in
            if event.event == "hello" {
                capturedEvent = event.event
                capturedItems = event.items
                received.fulfill()
            }
        }

        // Push a server-side broadcast via the admin endpoint.
        let body = try JSONSerialization.data(withJSONObject: ["args": ["world"]])
        let (status, _) = try server.admin("/admin/emit?event=hello", method: "POST", body: body)
        XCTAssertEqual(status, 200)

        wait(for: [received], timeout: 5)
        XCTAssertEqual(capturedEvent, "hello")
        XCTAssertEqual(capturedItems?.first as? String, "world")
    }

    func testMultipleAnyListenersAllReceive() throws {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let bothFired = expectation(description: "both fire")
        bothFired.expectedFulfillmentCount = 2
        _ = socket.addAnyListener { event in
            if event.event == "ping" { bothFired.fulfill() }
        }
        _ = socket.addAnyListener { event in
            if event.event == "ping" { bothFired.fulfill() }
        }

        let body = try JSONSerialization.data(withJSONObject: ["args": []])
        _ = try server.admin("/admin/emit?event=ping", method: "POST", body: body)

        wait(for: [bothFired], timeout: 5)
    }
}
