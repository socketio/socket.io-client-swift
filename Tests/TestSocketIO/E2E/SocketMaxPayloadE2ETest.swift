import XCTest
@testable import SocketIO

/// engine.io v4 servers advertise a `maxPayload` in the handshake. A polling
/// POST above it is answered with HTTP 413 and every packet it carried is
/// discarded, while the session itself stays open.
///
/// The batching rule is pinned deterministically by `SocketEngineTest`, and the
/// server contract by `Fixtures/max-payload-proof.mjs`. What only a real server
/// can show is these two meeting: that the advertised limit actually reaches the
/// engine, and that queued events survive a batch that would exceed it.
final class SocketMaxPayloadE2ETest: XCTestCase {
    /// Small enough that two of the events below never fit into one POST.
    private let serverMaxPayload = 200

    var server: TestServerProcess!
    /// Held for the test's lifetime: `SocketIOClient.manager` is weak, so a
    /// manager kept only in a helper's local scope is gone before the first emit.
    var manager: SocketManager!
    var serverURL: URL { URL(string: "http://127.0.0.1:\(server.port)")! }

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start(maxHttpBufferSize: serverMaxPayload)
    }

    override func tearDown() {
        manager?.disconnect()
        manager = nil
        server.stop()
        super.tearDown()
    }

    private func connectedSocket() -> SocketIOClient {
        manager = SocketManager(socketURL: serverURL, config: [.log(false), .forcePolling(true)])

        let socket = manager.defaultSocket
        let connected = expectation(description: "connect")

        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)

        return socket
    }

    func testEngineTakesMaxPayloadFromTheHandshake() {
        _ = connectedSocket()

        XCTAssertEqual(
            (manager.engine as? SocketEngine)?.maxPayload,
            serverMaxPayload,
            "Without the advertised limit the engine cannot know where to cut a batch"
        )
    }

    /// Ten events of ~137 bytes each against a 200 byte limit. The first one
    /// starts a POST and the rest queue up behind it, so they leave as one batch
    /// far above the limit — a client that ignores `maxPayload` loses all of them
    /// to a single 413.
    func testQueuedEventsSurviveABatchLargerThanTheLimit() {
        let socket = connectedSocket()
        let payload = String(repeating: "x", count: 120)

        let acked = expectation(description: "every event is acked")
        acked.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            socket.emitWithAck("ping", payload).timingOut(after: 5) { data in
                if (data.first as? String) == "pong" { acked.fulfill() }
            }
        }

        wait(for: [acked], timeout: 10)
    }
}
