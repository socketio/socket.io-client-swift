import XCTest
@testable import SocketIO

/// Manager-level connection timeout (`SocketManager.connectTimeout`), JS-aligned with
/// `Manager.open()` in `socket.io-client/lib/manager.ts`. Unit tests only: the fake
/// engine below never completes the engine.io handshake unless told to, so no server
/// is needed.
final class SocketConnectTimeoutTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!

    override func tearDown() {
        manager?.disconnect()
        manager = nil
        socket = nil
        super.tearDown()
    }

    private func makeManager(_ options: SocketIOClientOption...) {
        var config: SocketIOClientConfiguration = [.log(false)]
        for option in options {
            config.insert(option)
        }

        manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: config)
        socket = manager.defaultSocket
    }

    @discardableResult
    private func installFake(onConnect: (() -> Void)? = nil) -> TimeoutTestEngine {
        let fake = TimeoutTestEngine(client: manager, url: manager.socketURL, options: nil)
        fake.onConnect = onConnect
        // The manager only calls addEngine() when engine == nil, so assigning the
        // fake first keeps the real engine out of the picture.
        manager.engine = fake

        return fake
    }

    func testTimeoutFiresWhenEngineNeverOpens() {
        makeManager(.connectTimeout(0.2), .reconnects(false))
        installFake()

        let timedOut = expectation(description: "timeout error")
        timedOut.assertForOverFulfill = false
        var message: String?
        socket.on(clientEvent: .connectError) { data, _ in
            message = data.first as? String
            timedOut.fulfill()
        }

        let disconnected = expectation(description: "disconnect after timeout")
        disconnected.assertForOverFulfill = false
        socket.on(clientEvent: .disconnect) { _, _ in disconnected.fulfill() }

        socket.connect()

        wait(for: [timedOut, disconnected], timeout: 3)
        XCTAssertEqual(message, "timeout")
        XCTAssertNotEqual(manager.status, .connected)
    }

    func testTimeoutStartsReconnectLoop() {
        makeManager(.connectTimeout(0.2), .reconnects(true), .reconnectAttempts(1), .reconnectWait(1))
        installFake()

        let timedOut = expectation(description: "timeout error")
        timedOut.assertForOverFulfill = false
        socket.on(clientEvent: .connectError) { _, _ in timedOut.fulfill() }

        let attempted = expectation(description: "reconnect attempt")
        attempted.assertForOverFulfill = false
        var attemptNumber: Int?
        socket.on(clientEvent: .reconnectAttempt) { data, _ in
            attemptNumber = data.first as? Int
            attempted.fulfill()
        }

        // JS `Manager.open(fn)`'s error callback: a failed attempt reports
        // `reconnect_error` with the reason before the budget runs out.
        let attemptFailed = expectation(description: "reconnect error")
        attemptFailed.assertForOverFulfill = false
        var attemptError: String?
        socket.on(clientEvent: .reconnectError) { data, _ in
            attemptError = data.first as? String
            attemptFailed.fulfill()
        }

        // `reconnect_failed` replaced the Swift-only `.disconnect("Reconnect Failed")` in 17.0.0.
        let failed = expectation(description: "reconnect failed")
        failed.assertForOverFulfill = false
        socket.on(clientEvent: .reconnectFailed) { data, _ in
            XCTAssertTrue(data.isEmpty, "JS `reconnect_failed` carries no payload")
            failed.fulfill()
        }

        socket.connect()

        wait(for: [timedOut, attempted, attemptFailed, failed], timeout: 8)
        XCTAssertEqual(attemptNumber, 1, "JS emits the 1-based attempt number")
        XCTAssertEqual(attemptError, "timeout")
    }

    func testAFailedReconnectCycleCanBeStartedAgain() {
        makeManager(.connectTimeout(0.1), .reconnects(true), .reconnectAttempts(1), .reconnectWait(1))
        installFake()

        let firstFailed = expectation(description: "first reconnect failed")
        firstFailed.assertForOverFulfill = false
        let secondAttempt = expectation(description: "new reconnect attempt after connect()")
        secondAttempt.assertForOverFulfill = false
        let secondFailed = expectation(description: "second reconnect failed")
        secondFailed.assertForOverFulfill = false

        var failures = 0
        socket.on(clientEvent: .reconnectAttempt) { _, _ in
            if failures >= 1 {
                secondAttempt.fulfill()
            }
        }
        socket.on(clientEvent: .reconnectFailed) { _, _ in
            failures += 1
            if failures == 1 {
                firstFailed.fulfill()
                self.socket.connect()
            } else if failures == 2 {
                secondFailed.fulfill()
            }
        }

        socket.connect()

        wait(for: [firstFailed, secondAttempt, secondFailed], timeout: 8)
    }

    func testNoTimeoutWhenEngineOpensInTime() {
        makeManager(.connectTimeout(1))
        installFake {
            DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.05) {
                self.manager.engineDidOpen(reason: "Connect")
                self.manager.parseEngineMessage("0/,{\"sid\":\"fake-sid\"}")
            }
        }

        let errored = expectation(description: "must not error")
        errored.isInverted = true
        socket.on(clientEvent: .connectError) { _, _ in errored.fulfill() }

        let connected = expectation(description: "socket connected")
        connected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }

        socket.connect()

        wait(for: [connected], timeout: 3)
        XCTAssertEqual(socket.status, .connected)
        // The 1 s timer must stay silent past its deadline.
        wait(for: [errored], timeout: 1.5)
    }

    func testManualDisconnectCancelsTimeout() {
        makeManager(.connectTimeout(0.3))
        installFake()

        let errored = expectation(description: "must not error")
        errored.isInverted = true
        socket.on(clientEvent: .connectError) { _, _ in errored.fulfill() }

        let disconnected = expectation(description: "disconnect")
        disconnected.assertForOverFulfill = false
        socket.on(clientEvent: .disconnect) { _, _ in disconnected.fulfill() }

        socket.connect()

        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.1) {
            self.manager.disconnect()
        }

        wait(for: [disconnected], timeout: 3)
        // The 0.3 s timer must stay silent past its deadline.
        wait(for: [errored], timeout: 0.8)
    }

    func testInfinityDisablesTimeout() {
        makeManager(.connectTimeout(.infinity))
        installFake()

        let errored = expectation(description: "must not error")
        errored.isInverted = true
        socket.on(clientEvent: .connectError) { _, _ in errored.fulfill() }

        socket.connect()

        XCTAssertEqual(manager.status, .connecting)
        wait(for: [errored], timeout: 0.8)
    }

    func testLateOpenIsIgnored() {
        makeManager(.connectTimeout(0.1), .reconnects(false))
        installFake {
            DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.5) {
                self.manager.engineDidOpen(reason: "Connect")
            }
        }

        let timedOut = expectation(description: "timeout error")
        timedOut.assertForOverFulfill = false
        socket.on(clientEvent: .connectError) { _, _ in timedOut.fulfill() }

        socket.connect()

        wait(for: [timedOut], timeout: 3)

        // Wait until the late open has arrived.
        let settled = expectation(description: "settled")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertNotEqual(manager.status, .connected)
        XCTAssertNotEqual(socket.status, .connected)
    }
}

/// Same stored-property shape as `TestEngine` in `SocketSideEffectTest.swift` so it
/// conforms to `SocketEngineSpec`, except `connect()` runs an optional closure and
/// `disconnect(reason:)` reports the close back to the manager like a real engine
/// that never opened would (`closeOutEngine` -> `client?.engineDidClose`).
private final class TimeoutTestEngine: SocketEngineSpec {
    weak var client: SocketEngineClient?
    private(set) var closed = false
    private(set) var connected = false
    var connectParams: [String: Any]? = nil
    private(set) var cookies: [HTTPCookie]? = nil
    private(set) var engineQueue = DispatchQueue.main
    var extraHeaders: [String: String]? = nil
    private(set) var fastUpgrade = false
    private(set) var forcePolling = false
    private(set) var forceWebsockets = false
    private(set) var polling = false
    private(set) var probing = false
    private(set) var sid = ""
    private(set) var socketPath = ""
    private(set) var urlPolling = URL(string: "http://localhost/")!
    private(set) var urlWebSocket = URL(string: "http://localhost/")!


    var onConnect: (() -> Void)?

    required init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.client = client
    }

    func connect() {
        onConnect?()
    }

    func didError(reason: String) { }
    func disconnect(reason: String) {
        client?.engineDidClose(reason: reason)
    }
    func doFastUpgrade() { }
    func flushWaitingForPostToWebSocket() { }
    func parseEngineData(_ data: Data) { }
    func parseEngineMessage(_ message: String) { }
    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) { }
}
