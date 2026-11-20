import Foundation
import XCTest
@testable import SocketIO

/// Regressions for the 2026-11-20 security scan: credential reuse, stale auth,
/// namespace revival, log redaction and crash-safe configuration.
final class SocketSecurityHardeningTest: XCTestCase {
    private let url = URL(string: "http://localhost:1/")!

    // MARK: Reused engine (scan finding A)

    func testRemovedCredentialsDoNotSurviveOnReusedEngine() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "session", .value: "previous-user", .domain: "localhost", .path: "/"
        ]))
        let manager = SocketManager(socketURL: url, config: [
            .autoConnect(false), .forcePolling(true),
            .extraHeaders(["Authorization": "Bearer previous-user"]),
            .cookies([cookie]), .connectParams(["token": "previous-user"]), .withCredentials(true)
        ])
        let engine = SocketEngine(client: manager, url: url, config: manager.config)
        manager.engine = engine
        defer { engine.disconnect(reason: "test") }
        XCTAssertEqual(engine.extraHeaders?["Authorization"], "Bearer previous-user")

        manager.config = [.autoConnect(false), .forcePolling(true)]

        XCTAssertTrue(manager.engine === engine)
        engine.engineQueue.sync {
            XCTAssertNil(engine.extraHeaders)
            XCTAssertNil(engine.cookies)
            XCTAssertNil(engine.connectParams)
            XCTAssertFalse(engine.withCredentials)
            var request = engine.createPollingRequest(for: engine.urlPollingHandshake)
            engine.addHeaders(to: &request)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.url?.absoluteString.contains("previous-user") ?? true)
            XCTAssertTrue(engine.forcePolling, "options that are still configured keep applying")
        }
    }

    // MARK: Scheme downgrade (finding E)

    func testSecureFalseDoesNotDowngradeASecureURL() {
        for raw in ["wss://example.test/", "https://example.test/", "HTTPS://example.test/"] {
            let secureURL = URL(string: raw)!
            let manager = SocketManager(socketURL: secureURL, config: [.autoConnect(false), .secure(false)])
            let engine = SocketEngine(client: manager, url: secureURL, config: manager.config)
            XCTAssertEqual(engine.urlPolling.scheme, "https", raw)
            XCTAssertEqual(engine.urlWebSocket.scheme, "wss", raw)
        }

        let plain = URL(string: "http://example.test/")!
        let manager = SocketManager(socketURL: plain, config: [.autoConnect(false), .secure(true)])
        let engine = SocketEngine(client: manager, url: plain, config: manager.config)
        XCTAssertEqual(engine.urlPolling.scheme, "https", "an explicit .secure(true) still upgrades")
        XCTAssertEqual(engine.urlWebSocket.scheme, "wss")
    }

    // MARK: Crash-safe configuration (finding K)

    func testExtremeReconnectWaitSaturatesInsteadOfTrapping() {
        let manager = SocketManager(socketURL: url, config: [
            .autoConnect(false), .reconnectWait(Int.min), .reconnectWaitMax(Int.min)
        ])
        XCTAssertEqual(manager.reconnectWait, Int.max)
        XCTAssertEqual(manager.reconnectWaitMax, Int.max)
        XCTAssertTrue(manager.reconnectInterval(attempts: 3).isFinite)

        manager.config = [.autoConnect(false), .reconnectWait(-3)]
        XCTAssertEqual(manager.reconnectWait, 3, "negative values keep their magnitude as before")
    }

    func testRelativePathDoesNotCrashURLConstruction() {
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false), .path("socket.io")])
        let engine = SocketEngine(client: manager, url: url, config: manager.config)
        XCTAssertEqual(engine.socketPath, "/socket.io/")
        XCTAssertEqual(engine.urlPolling.path, "/socket.io/")
        XCTAssertEqual(engine.urlWebSocket.path, "/socket.io/")
    }

    // MARK: Header injection (finding M)

    func testExtraHeaderWithLineBreakIsNotSent() {
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: url, config: [
            .extraHeaders(["X-Ok": "1", "X-Bad": "a\r\nX-Injected: 1"])
        ])
        var request = URLRequest(url: url)
        engine.addHeaders(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ok"), "1")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Bad"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Injected"))
    }

    // MARK: Engine JSON depth (DS-03)

    func testEngineJSONRejectsExcessiveNesting() throws {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        XCTAssertThrowsError(try "{\"sid\":\"x\",\"a\":\(deep)}".toDictionary())
        XCTAssertEqual(try "{\"sid\":\"x\",\"upgrades\":[]}".toDictionary()["sid"] as? String, "x")
    }

    // MARK: Log redaction (finding D)

    func testLogRedactionHidesConnectAuthAndQueryValues() {
        XCTAssertEqual(SocketLogRedaction.socketIOPacket("0{\"token\":\"secret\"}"), "0<redacted>")
        XCTAssertEqual(SocketLogRedaction.socketIOPacket("0/admin,{\"token\":\"secret\"}"), "0/admin,<redacted>")
        XCTAssertEqual(SocketLogRedaction.socketIOPacket("0/admin,"), "0/admin,")
        XCTAssertEqual(SocketLogRedaction.socketIOPacket("2[\"chat\",\"hi\"]"), "2[\"chat\",\"hi\"]")
        XCTAssertEqual(SocketLogRedaction.enginePayload("40{\"token\":\"secret\"}\u{1e}42[\"a\"]\u{1e}2"),
                       "40<redacted>\u{1e}42[\"a\"]\u{1e}2")

        let logged = SocketLogRedaction.url(URL(string:
            "https://user:pass@host.test:8443/socket.io/?EIO=4&transport=polling&token=secret&sid=S1"))
        XCTAssertEqual(logged, "https://host.test:8443/socket.io/?EIO=4&transport=polling&token=REDACTED&sid=S1")
        XCTAssertFalse(logged.contains("secret"))
        XCTAssertFalse(logged.contains("pass"))
    }

    // MARK: Stale auth callback (finding B)

    func testLateAuthCallbackAfterDisconnectSendsNoConnect() {
        let queue = DispatchQueue(label: "test.security.auth")
        let manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue), .autoConnect(false)])
        let engine = CaptureEngine()
        let socket = manager.defaultSocket
        var pending: SocketAuthCallback?
        queue.sync {
            manager.engine = engine
            manager.setTestStatus(.connected)
        }
        socket.setAuth { callback in pending = callback }
        queue.sync {}
        queue.sync { socket.connect(timeoutAfter: 0, withHandler: nil) }
        queue.sync {}
        XCTAssertNotNil(pending, "connect must ask the provider")

        queue.sync { socket.disconnect() }
        pending?(["token": "previous-user"])
        queue.sync {}
        queue.sync {}

        XCTAssertFalse(engine.sentPackets.contains { $0.hasPrefix("0") },
                       "a retired attempt must not send CONNECT: \(engine.sentPackets)")
        XCTAssertNotEqual(socket.status, .connecting)
    }

    func testAuthCallbackForTheCurrentAttemptStillConnects() {
        let queue = DispatchQueue(label: "test.security.auth.current")
        let manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue), .autoConnect(false)])
        let engine = CaptureEngine()
        let socket = manager.defaultSocket
        var pending: SocketAuthCallback?
        queue.sync {
            manager.engine = engine
            manager.setTestStatus(.connected)
        }
        socket.setAuth { callback in pending = callback }
        queue.sync {}
        queue.sync { socket.connect(timeoutAfter: 0, withHandler: nil) }
        queue.sync {}

        pending?(["token": "current-user"])
        queue.sync {}
        queue.sync {}

        XCTAssertEqual(engine.sentPackets.filter { $0.hasPrefix("0") }, ["0/,{\"token\":\"current-user\"}"])
    }

    // MARK: Namespace revival (finding C)

    func testDisconnectedSocketIgnoresServerConnectAndEvents() throws {
        let manager = SocketManager(socketURL: url, config: [.log(false), .autoConnect(false)])
        let engine = CaptureEngine()
        manager.engine = engine
        let socket = manager.defaultSocket
        XCTAssertFalse(socket.active)
        var connects = 0
        var events = 0
        socket.on(clientEvent: .connect) { _, _ in connects += 1 }
        socket.on("news") { _, _ in events += 1 }

        socket.handlePacket(try manager.parseString("2[\"news\",1]"))
        socket.handlePacket(try manager.parseString("0{\"sid\":\"server-chosen\"}"))

        XCTAssertNotEqual(socket.status, .connected)
        XCTAssertEqual(connects, 0)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 0)
        XCTAssertTrue(engine.sentPackets.isEmpty)
    }

    func testConnectingSocketStillBuffersAndAcceptsConnect() throws {
        let manager = SocketManager(socketURL: url, config: [.log(false), .autoConnect(false)])
        manager.engine = CaptureEngine()
        let socket = manager.defaultSocket
        socket.setTestStatus(.connecting)
        var events = 0
        socket.on("news") { _, _ in events += 1 }

        socket.handlePacket(try manager.parseString("2[\"news\",1]"))
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 1)
        socket.handlePacket(try manager.parseString("0{\"sid\":\"s1\"}"))

        XCTAssertEqual(socket.status, .connected)
        XCTAssertEqual(events, 1)
    }

    // MARK: Replay quota (finding J)

    func testReplayQuotaCountsTheEventName() throws {
        let limits = SocketBufferLimits(maximumRecoveryReplayBytes: 16)
        let manager = SocketManager(socketURL: url, config: [.log(false), .autoConnect(false), .bufferLimits(limits)])
        let engine = MockEngine()
        manager.engine = engine
        let socket = manager.defaultSocket
        socket.setTestStatus(.connecting)
        var errors = [SocketBufferLimitError]()
        socket.on(clientEvent: .error) { data, _ in
            if let error = data.first as? SocketBufferLimitError { errors.append(error) }
        }

        // 20 bytes of event name plus an 8-byte number exceed 16 bytes; the
        // arguments alone (8 bytes) would not.
        socket.handlePacket(try manager.parseString("2[\"\(String(repeating: "n", count: 20))\",1]"))

        XCTAssertEqual(errors.first?.buffer, .recoveryReplay)
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 0)
    }
}
