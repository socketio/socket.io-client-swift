import XCTest
@testable import SocketIO

final class SocketSendE2ETest: XCTestCase {
    var server: TestServerProcess!
    var serverURL: URL { URL(string: "http://127.0.0.1:\(server.port)")! }

    override func setUp() {
        super.setUp(); server = try! TestServerProcess.start()
    }
    override func tearDown() { server.stop(); super.tearDown() }

    func testSendReachesServerOnMessage() {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let socket = manager.defaultSocket

        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let echoed = expectation(description: "server echoes via send")
        socket.on("message") { data, _ in
            if (data.first as? String) == "hello" { echoed.fulfill() }
        }
        socket.send("hello")
        wait(for: [echoed], timeout: 3)
    }

    func testSendWithAckReachesServer() {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let acked = expectation(description: "server acks")
        socket.sendWithAck("ping").timingOut(after: 2) { data in
            if (data.first as? String) == "ack:ping" { acked.fulfill() }
        }
        wait(for: [acked], timeout: 3)
    }

    func testSendArrayForm() {
        let manager = SocketManager(socketURL: serverURL, config: [.log(false)])
        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        let echoed = expectation(description: "server echoes array form")
        socket.on("message") { data, _ in
            if (data.first as? String) == "world" { echoed.fulfill() }
        }
        socket.send(with: ["world"])
        wait(for: [echoed], timeout: 3)
    }
}
