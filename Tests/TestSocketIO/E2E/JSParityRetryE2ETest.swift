import XCTest
@testable import SocketIO

/// Scenarios adapted from the JavaScript client's own test suite
/// (`socket.io/packages/socket.io-client/test/retry.ts`, v4.8.3), run against
/// the same kind of server it is tested against.
///
/// The JS tests spy on `packetCreate` to observe the wire; the Swift ports
/// observe outgoing packets through `addAnyOutgoingListener` (which fires at
/// send time, per attempt, exactly where JS fires `packetCreate`) and assert
/// the internal queue length through the test accessor, mirroring the JS
/// `socket._queue.length` assertions.
///
/// Ordering/parking tests deliberately use a generous network deadline. A
/// 10ms/50ms deadline measures the CI host's latency, not FIFO correctness.
/// Exact retry budgets and stale callbacks also have controlled unit tests.
/// See `PARITY.md` for the matrix and the review report for coverage limits.
final class JSParityRetryE2ETest: XCTestCase {
    var server: TestServerProcess!
    var manager: SocketManager!

    override func setUp() {
        super.setUp()
        server = try! TestServerProcess.start()
    }

    override func tearDown() {
        manager?.disconnect()
        manager = nil
        server.stop()
        super.tearDown()
    }

    private func makeManager(_ extra: SocketIOClientOption...) -> SocketManager {
        var config: SocketIOClientConfiguration = [.log(false)]
        for option in extra { config.insert(option) }

        manager = SocketManager(socketURL: URL(string: "http://127.0.0.1:\(server.port)")!, config: config)

        return manager
    }

    private func connect(_ socket: SocketIOClient) {
        let connected = expectation(description: "connect")
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        socket.connect()
        wait(for: [connected], timeout: 5)
    }

    /// Waits a fixed interval, for assertions that nothing *further* happens.
    private func settle(_ seconds: TimeInterval) {
        let done = expectation(description: "settled")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    // MARK: retry.ts — "should preserve the order of the packets"

    /// The JS test asserts the exact wire packets (`0`, `2<id>["echo",n]`, …)
    /// and the queue length between emits. The Swift port asserts the same
    /// thing at the observable layer: strict FIFO order of the outgoing
    /// packets, one in-flight head, and an empty queue after all acks.
    func testRetryPreservesTheOrderOfThePackets() {
        let recorded = ParityPacketRecordingManager(
            socketURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            config: [.retries(1), .ackTimeout(2)])
        manager = recorded
        let socket = recorded.defaultSocket

        var outgoing = [String]()
        socket.addAnyOutgoingListener { event in
            outgoing.append("\(event.event) \(event.items?.first ?? 0)")
        }

        var acks = [Int]()

        let allAcked = expectation(description: "third emit acked")

        // The JS test emits right after `io()` — while the handshake is still
        // in flight — so the queue parks all three packets and drains them in
        // order on CONNECT.
        socket.emit("echo", 1) { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(socket.testRetryQueueCount, 2)
            acks.append(data.first as? Int ?? -1)
        }
        XCTAssertEqual(socket.testRetryQueueCount, 1)

        socket.emit("echo", 2) { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(socket.testRetryQueueCount, 1)
            acks.append(data.first as? Int ?? -1)
        }
        XCTAssertEqual(socket.testRetryQueueCount, 2)

        socket.emit("echo", 3) { error, data in
            XCTAssertNil(error)
            XCTAssertEqual(data.first as? Int, 3)
            XCTAssertEqual(socket.testRetryQueueCount, 0)
            acks.append(data.first as? Int ?? -1)
            allAcked.fulfill()
        }
        XCTAssertEqual(socket.testRetryQueueCount, 3)

        connect(socket)

        wait(for: [allAcked], timeout: 5)

        XCTAssertEqual(acks, [1, 2, 3])
        XCTAssertEqual(outgoing, ["echo 1", "echo 2", "echo 3"],
                       "the queue must send strictly in order, one head packet at a time")
        XCTAssertEqual(socket.testRetryQueueCount, 0)
        socket.disconnect()
        XCTAssertEqual(recorded.createdPackets,
                       ["0", "20[\"echo\",1]", "21[\"echo\",2]", "22[\"echo\",3]", "1"])
    }

    // MARK: retry.ts — "should fail when the server does not acknowledge the packet"

    /// `retries: 3` + `ackTimeout: 50ms`: the server receives the packet four
    /// times (1 + 3 retries, fresh ack id per attempt) and the callback then
    /// fires with the timeout error.
    func testRetryFailsWhenTheServerDoesNotAcknowledgeThePacket() {
        let socket = makeManager(.retries(3), .ackTimeout(0.05)).defaultSocket
        connect(socket)

        var count = 0
        let failed = expectation(description: "emit failed after exhausting retries")
        socket.on("ack") { _, _ in count += 1 }

        socket.emit("ack") { err, _ in
            XCTAssertEqual(count, 4, "the server must have received the packet 1 + retries times")
            XCTAssertTrue(err is SocketAckError, "exhausted retries must fail with the typed ack error")
            failed.fulfill()
        }

        wait(for: [failed], timeout: 5)
        XCTAssertEqual(count, 4)
        XCTAssertEqual(socket.testRetryQueueCount, 0, "a discarded packet leaves the queue")
    }

    // MARK: retry.ts — "should not drain the queue while the socket is disconnected"

    /// The queue must not send while disconnected — not even its head. The
    /// parked packet goes out on the next CONNECT and the ack succeeds.
    func testRetryDoesNotDrainTheQueueWhileDisconnected() {
        let socket = makeManager(.retries(3), .ackTimeout(2)).defaultSocket

        var outgoing = 0
        socket.addAnyOutgoingListener { _ in outgoing += 1 }

        var ackError: Error?
        let acked = expectation(description: "acked after connect")
        socket.emit("echo", 1) { err, data in
            ackError = err
            XCTAssertEqual(data.first as? Int, 1, "the ack carries the echo value")
            acked.fulfill()
        }

        settle(0.3)
        XCTAssertEqual(outgoing, 0, "a disconnected queue must not send")
        XCTAssertEqual(socket.testRetryQueueCount, 1, "the emit is parked in the queue, not dropped")
        XCTAssertNil(ackError)

        connect(socket)

        wait(for: [acked], timeout: 5)

        XCTAssertNil(ackError)
        XCTAssertEqual(outgoing, 1, "exactly one send after connecting")
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }

    // MARK: retry.ts — "should not emit a packet twice in the 'connect' handler"

    /// The queue drains (force) before the `connect` event, so an emit made
    /// inside a connect handler is queued once and sent once.
    func testRetryDoesNotEmitAPacketTwiceInTheConnectHandler() {
        let socket = makeManager(.retries(3), .ackTimeout(10)).defaultSocket

        var outgoing = [String]()
        socket.addAnyOutgoingListener { event in outgoing.append(event.event) }

        socket.on(clientEvent: .connect) { _, _ in
            socket.emit("echo")
        }

        connect(socket)
        settle(0.5)

        XCTAssertEqual(outgoing, ["echo"],
                       "the connect-handler emit must go out exactly once, not once per queue drain")
        XCTAssertEqual(socket.testRetryQueueCount, 0)
    }
}
