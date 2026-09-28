import XCTest
@testable import SocketIO

/// Ports the ordering and immediate-listener assertions, not merely similar
/// test names. Polling and WebSocket run as independent cases in XCTest.
final class JSParityFollowupE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var manager: SocketManager!

    override func setUpWithError() throws {
        server = try TestServerProcess.start()
    }

    override func tearDown() {
        manager?.disconnect()
        manager = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func socket(_ options: [SocketIOClientOption]) -> SocketIOClient {
        var config: SocketIOClientConfiguration = [.log(false), .autoConnect(false)]
        for option in options { config.insert(option) }
        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:\(server.port)")!, config: config)
        return manager.defaultSocket
    }

    // JS-082 socket.ts: a buffered first emit must precede an emit issued by
    // the connect handler; the assertion observes real server acknowledgements.
    private func assertConnectHandlerOrdering(_ options: [SocketIOClientOption]) {
        let socket = self.socket(options)
        var replies: [String] = []
        let done = expectation(description: "both server acknowledgements")
        done.expectedFulfillmentCount = 2
        socket.once(clientEvent: .connect) { _, _ in
            socket.emit("echo", "second", ack: { error, data in
                XCTAssertNil(error)
                XCTAssertEqual(data.first as? String, "second")
                replies.append("second")
                done.fulfill()
            })
        }
        socket.emit("echo", "first", ack: { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? String, "first")
            replies.append("first")
            done.fulfill()
        })
        socket.connect()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(replies, ["first", "second"])
    }

    func testBufferedEmitPrecedesConnectHandlerEmitPolling() {
        assertConnectHandlerOrdering([.forcePolling(true)])
    }
    func testBufferedEmitPrecedesConnectHandlerEmitWebSocket() {
        assertConnectHandlerOrdering([.forceWebsockets(true)])
    }
    func testBufferedEmitPrecedesConnectHandlerEmitWithUpgradeEnabled() {
        assertConnectHandlerOrdering([])
    }

    // JS-090/091: install from inside connect, then immediately emit binary.
    // No queue hop or drain is allowed between the two operations.
    private func assertImmediateOutgoingListener(_ options: [SocketIOClientOption]) {
        let socket = self.socket(options)
        let payload = Data([1, 2, 3])
        var calls = 0
        let done = expectation(description: "binary acknowledged")
        socket.once(clientEvent: .connect) { _, _ in
            socket.addAnyOutgoingListener { event in
                XCTAssertEqual(event.event, "echo")
                XCTAssertEqual(event.items?.first as? Data, payload)
                calls += 1
            }
            socket.emit("echo", payload, ack: { error, data in
                XCTAssertNil(error)
                XCTAssertEqual(data.first as? Data, payload)
                done.fulfill()
            })
            XCTAssertEqual(calls, 1)
        }
        socket.connect()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(calls, 1)
    }

    func testImmediateOutgoingListenerReceivesBinaryPolling() {
        assertImmediateOutgoingListener([.forcePolling(true)])
    }
    func testImmediateOutgoingListenerReceivesBinaryWebSocket() {
        assertImmediateOutgoingListener([.forceWebsockets(true)])
    }

    /// Transferable part of Engine.IO binary/UTF-8 cases. This is a Socket.IO
    /// round trip through the native engine, not a standalone JS engine API port.
    private func assertMixedBinaryAndUnicode(_ options: [SocketIOClientOption]) {
        let socket = self.socket(options)
        let done = expectation(description: "mixed payloads in order")
        done.expectedFulfillmentCount = 3
        let text = "€ café こんにちは 👩🏽‍💻 🦧"
        let binaries = [Data(), Data([0, 1, 127, 128, 255]), Data(repeating: 0xa5, count: 1024)]
        var order: [Int] = []
        socket.once(clientEvent: .connect) { _, _ in
            for (index, bytes) in binaries.enumerated() {
                let value: [String: Any] = ["text": text, "bytes": bytes, "index": index]
                socket.emit("echo", value, ack: { error, data in
                    XCTAssertNil(error)
                    let echoed = data.first as? [String: Any]
                    XCTAssertEqual(echoed?["text"] as? String, text)
                    XCTAssertEqual(echoed?["bytes"] as? Data, bytes)
                    XCTAssertEqual(echoed?["index"] as? Int, index)
                    order.append(index)
                    done.fulfill()
                })
            }
        }
        socket.connect()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testMixedBinaryAndUnicodePollingRoundTrip() {
        assertMixedBinaryAndUnicode([.forcePolling(true)])
    }
    func testMixedBinaryAndUnicodeWebSocketRoundTrip() {
        assertMixedBinaryAndUnicode([.forceWebsockets(true)])
    }

    /// A real remote transport close must fail a sent timed acknowledgement,
    /// even though the manager is about to reconnect automatically.
    private func assertRemoteDropClearsAck(_ options: [SocketIOClientOption]) throws {
        let socket = self.socket(options + [.reconnectWait(0)])
        let connected = expectation(description: "initial connect")
        socket.once(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 10)
        let failed = expectation(description: "disconnect fails the outstanding ack")
        let reconnected = expectation(description: "automatic reconnection")
        var order: [String] = []
        socket.once(clientEvent: .disconnect) { _, _ in order.append("disconnect") }
        socket.once(clientEvent: .connect) { _, _ in
            order.append("connect")
            reconnected.fulfill()
        }
        socket.timeout(after: 60).emit("never_ack") { error, _ in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            order.append("ack")
            failed.fulfill()
        }
        let sid = try XCTUnwrap(socket.sid)
        let (status, _) = try server.admin("/admin/kill-transport?sid=\(sid)")
        XCTAssertEqual(status, 200)
        wait(for: [failed, reconnected], timeout: 10)
        XCTAssertEqual(order, ["disconnect", "ack", "connect"])
    }

    func testRemoteDropClearsTimedAckPolling() throws {
        try assertRemoteDropClearsAck([.forcePolling(true)])
    }
    func testRemoteDropClearsTimedAckWebSocket() throws {
        try assertRemoteDropClearsAck([.forceWebsockets(true)])
    }
}
