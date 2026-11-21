import XCTest
@testable import SocketIO

/// Default ack timeout (`SocketManager.ackTimeout` / `.ackTimeout`), JS-aligned
/// with `_registerAckCallback` in `socket.io-client/lib/socket.ts` when
/// `flags.timeout` is unset and `ackTimeout` is (or is not) configured.
///
/// - default set   → the ack is `withError`: `.timeout` on timeout (packet
///   dropped from the send buffer), `.disconnected` on disconnect.
/// - default unset → a plain ack: no timer, never called with an error.
final class SocketAckTimeoutTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var engine: CaptureEngine!

    private func makeSocket(config: SocketIOClientConfiguration) {
        manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: config)
        socket = manager.defaultSocket
        engine = CaptureEngine()
        manager.engine = engine
    }

    private func connect() {
        socket.didConnect(toNamespace: "/", payload: ["sid": "s1"])
    }

    /// Lets emitTimed's handleQueue hop register the ack before the test
    /// proceeds (e.g. to disconnect or read the captured packet).
    private func waitForAckRegistration() {
        let registered = expectation(description: "ack registered")
        manager.handleQueue.socketAsync { registered.fulfill() }
        wait(for: [registered], timeout: 2)
    }

    func testDefaultTimeoutAppliesToEmitWithAck() {
        makeSocket(config: [.log(false), .ackTimeout(0.1)])
        connect()

        let timedOut = expectation(description: "default timeout fires")
        socket.emit("unknown", ack: { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            timedOut.fulfill()
        })

        wait(for: [timedOut], timeout: 2)
        XCTAssertEqual(engine.sentPackets.count, 1, "The packet must still go out; only the wait is bounded")
    }

    func testDefaultTimeoutFailsAckOnDisconnect() {
        makeSocket(config: [.log(false), .ackTimeout(10)])
        connect()

        let disconnected = expectation(description: "ack fails on disconnect")
        socket.emit("unknown", ack: { err, _ in
            XCTAssertEqual(err as? SocketAckError, .disconnected)
            disconnected.fulfill()
        })

        waitForAckRegistration()
        socket.didDisconnect(reason: "transport close")

        wait(for: [disconnected], timeout: 2)
    }

    func testNoDefaultMeansPlainAckNeverCalledWithError() {
        makeSocket(config: [.log(false)])
        connect()

        let neverCalled = expectation(description: "plain ack is never called")
        neverCalled.isInverted = true
        socket.emit("unknown", ack: { _, _ in
            neverCalled.fulfill()
        })

        waitForAckRegistration()
        socket.didDisconnect(reason: "transport close")

        wait(for: [neverCalled], timeout: 1)
    }

    func testPerEmitTimeoutWinsOverTheDefault() {
        makeSocket(config: [.log(false), .ackTimeout(10)])
        connect()

        let timedOut = expectation(description: "per-emit timeout fires")
        socket.timeout(after: 0.1).emit("unknown") { err, _ in
            XCTAssertEqual(err as? SocketAckError, .timeout)
            timedOut.fulfill()
        }

        wait(for: [timedOut], timeout: 2)
    }

    func testServerAckDeliversDataWithNilError() throws {
        makeSocket(config: [.log(false), .ackTimeout(5)])
        connect()

        let acked = expectation(description: "server ack delivered")
        var receivedError: Error?
        var receivedData: [Any] = []
        socket.emit("unknown", ack: { err, data in
            receivedError = err
            receivedData = data
            acked.fulfill()
        })

        waitForAckRegistration()

        let sent = try XCTUnwrap(engine.lastSent)
        XCTAssertTrue(sent.hasPrefix("2"), "Expected an event packet, got \(sent)")
        var remainder = String(sent.dropFirst())
        if remainder.hasPrefix("/") {
            guard let comma = remainder.firstIndex(of: ",") else {
                XCTFail("Could not parse namespace from \(sent)")
                return
            }
            remainder = String(remainder[remainder.index(after: comma)...])
        }
        let ackId = try XCTUnwrap(Int(String(remainder.prefix(while: { $0.isNumber })) ),
                                  "Could not parse ack id from \(sent)")

        socket.handleAck(ackId, data: ["pong"])

        wait(for: [acked], timeout: 2)
        XCTAssertNil(receivedError)
        XCTAssertEqual(receivedData.first as? String, "pong")
    }
}
