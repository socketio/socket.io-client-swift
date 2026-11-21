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
        // `URL.path` drops the trailing slash; compare the encoded path.
        XCTAssertEqual(URLComponents(url: engine.urlPolling, resolvingAgainstBaseURL: false)?.path, "/socket.io/")
        XCTAssertEqual(URLComponents(url: engine.urlWebSocket, resolvingAgainstBaseURL: false)?.path, "/socket.io/")
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

    // MARK: Gemini follow-up (F-01 … F-04)

    func testSetAuthThenConnectOnTheHandleQueueUsesTheNewProvider() {
        let queue = DispatchQueue(label: "test.security.auth.same-turn")
        let manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue), .autoConnect(false)])
        let engine = CaptureEngine()
        let socket = manager.defaultSocket
        queue.sync {
            manager.engine = engine
            manager.setTestStatus(.connected)
            socket.setAuth { callback in callback(["token": "new-user"]) }
            socket.connect(timeoutAfter: 0, withHandler: nil)
        }
        queue.sync {}
        queue.sync {}

        XCTAssertEqual(engine.sentPackets.filter { $0.hasPrefix("0") }, ["0/,{\"token\":\"new-user\"}"])
    }

    func testLateAsyncAuthFailureDoesNotAbortANewerAttempt() {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        }
        let queue = DispatchQueue(label: "test.security.auth.async")
        let manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue), .autoConnect(false)])
        manager.engine = CaptureEngine()
        let socket = manager.defaultSocket
        let calls = Calls()
        var errors = 0
        socket.on(clientEvent: .error) { _, _ in errors += 1 }
        socket.setAuth {
            if calls.next() == 1 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                throw URLError(.userAuthenticationRequired)
            }
            return ["token": "fresh"]
        }
        queue.sync {}
        queue.sync {
            manager.setTestStatus(.connected)
            socket.connect(timeoutAfter: 0, withHandler: nil)
        }
        // A newer resolution of the same attempt (e.g. after the engine reopened).
        let newer = expectation(description: "newer resolution completed")
        queue.async { socket.resolveConnectPayload(explicit: nil) { _ in newer.fulfill() } }
        wait(for: [newer], timeout: 2)

        Thread.sleep(forTimeInterval: 0.6)
        queue.sync {}
        queue.sync {
            XCTAssertEqual(errors, 0, "the retired provider call must not report its failure")
            XCTAssertEqual(socket.status, .connecting, "the retired provider call must not abort the newer attempt")
        }
    }

    func testRelativePathBeforeConnectParamsDoesNotCrash() {
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: url,
                                  config: [.path("socket.io"), .connectParams(["token": "t"])])
        XCTAssertEqual(engine.socketPath, "/socket.io/")
        XCTAssertTrue(engine.urlPolling.absoluteString.contains("/socket.io/?"))
    }

    func testParserLogDoesNotContainTheRecoveryPid() {
        final class CaptureLogger: SocketLogger {
            var log = true
            var lines = [String]()
            func log(_ message: @autoclosure () -> String, type: String) { lines.append(message()) }
            func error(_ message: @autoclosure () -> String, type: String) { lines.append(message()) }
        }
        let logger = CaptureLogger()
        DefaultSocketLogger.Logger = logger
        defer { DefaultSocketLogger.Logger = DefaultSocketLogger() }
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])

        XCTAssertNotNil(manager.parseSocketMessage("0{\"sid\":\"s1\",\"pid\":\"recovery-secret\"}"))

        XCTAssertFalse(logger.lines.isEmpty)
        XCTAssertFalse(logger.lines.contains { $0.contains("recovery-secret") }, "\(logger.lines)")
    }

    func testDisconnectedSocketIgnoresServerDisconnectAndConnectError() {
        let manager = SocketManager(socketURL: url, config: [.log(false), .autoConnect(false)])
        manager.engine = CaptureEngine()
        let socket = manager.defaultSocket
        var lifecycle = [String]()
        socket.on(clientEvent: .disconnect) { _, _ in lifecycle.append("disconnect") }
        socket.on(clientEvent: .connectError) { _, _ in lifecycle.append("connect_error") }

        socket.handlePacket(SocketPacket(type: .disconnect, data: [], id: -1, nsp: "/", placeholders: 0))
        socket.handlePacket(SocketPacket(type: .error, data: ["denied"], id: -1, nsp: "/", placeholders: 0))

        XCTAssertEqual(lifecycle, [])
        XCTAssertEqual(socket.status, .notConnected)
    }

    // MARK: Cross-queue configuration (Gemini F-06)

    func testReceivePermitsAreReleasedWhenLimitsChangeInFlight() {
        let queue = DispatchQueue(label: "test.security.permits")
        let bounded = SocketBufferLimits(maximumUnparsedPackets: 10)
        let manager = SocketManager(socketURL: url, config: [
            .log(false), .autoConnect(false), .handleQueue(queue), .bufferLimits(bounded)
        ])
        queue.suspend()
        manager.parseEngineMessage("2[\"x\"]")
        XCTAssertEqual(manager.testReceiveBacklog.packets, 1)

        manager.config = [.log(false), .autoConnect(false), .handleQueue(queue), .bufferLimits(.unlimited)]
        queue.resume()
        queue.sync {}

        XCTAssertEqual(manager.testReceiveBacklog.packets, 0, "a counted permit is released under new limits")
        XCTAssertEqual(manager.testReceiveBacklog.bytes, 0)

        manager.config = [.log(false), .autoConnect(false), .handleQueue(queue), .bufferLimits(bounded)]
        manager.parseEngineMessage("2[\"y\"]")
        queue.sync {}
        XCTAssertEqual(manager.testReceiveBacklog.packets, 0)
    }

    func testManagerStateCanBeReconfiguredWhileTheEngineQueueReadsIt() {
        let manager = SocketManager(socketURL: url, config: [.log(false), .autoConnect(false)])
        let limits = SocketBufferLimits(maximumUnparsedPackets: 1_000_000)
        final class Box: @unchecked Sendable { let manager: SocketManager; init(_ m: SocketManager) { manager = m } }
        let box = Box(manager)
        let reader = DispatchQueue(label: "test.security.reader")
        let done = expectation(description: "concurrent reads finished")
        reader.async {
            // What engine-queue callbacks read while the app reconfigures.
            for _ in 0..<2_000 {
                _ = box.manager.bufferLimits.boundsReceive
                _ = box.manager.handleQueue
                _ = box.manager.engine
            }
            done.fulfill()
        }
        for index in 0..<2_000 {
            manager.config = [.log(false), .autoConnect(false),
                              .bufferLimits(index.isMultiple(of: 2) ? limits : .unlimited)]
        }
        wait(for: [done], timeout: 10)
    }
}

// MARK: Redirect cookies (Gemini F-05)

extension SocketSecurityHardeningTest {
    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    /// Calls the proxy's redirect decision without a network.
    private func redirect(from source: String, to target: String, cookies: [HTTPCookie]) -> String? {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil,
                                               redirectCookies: cookies)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = URLRequest(url: URL(string: source)!)
        original.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        let task = session.dataTask(with: original)
        var next = URLRequest(url: URL(string: target)!)
        next.allHTTPHeaderFields = original.allHTTPHeaderFields
        let response = HTTPURLResponse(url: URL(string: source)!, statusCode: 307, httpVersion: nil,
                                       headerFields: ["Location": target])!
        var decided: URLRequest??
        proxy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) {
            decided = .some($0)
        }
        return decided??.value(forHTTPHeaderField: "Cookie")
    }

    func testRedirectKeepsOnlyCookiesThatCookieRulesAllow() {
        let host = cookie("host", domain: "chat.example.com")
        let parent = cookie("parent", domain: ".example.com")
        let secure = cookie("secure", domain: "chat.example.com", secure: true)
        let scoped = cookie("scoped", domain: "chat.example.com", path: "/socket.io")
        let all = [host, parent, secure, scoped]

        // Same origin and path: rebuilt by the same rules, so the same cookies go.
        XCTAssertEqual(redirect(from: "https://chat.example.com/socket.io/", to: "https://chat.example.com/socket.io/?x",
                                cookies: all), HTTPCookie.requestHeaderFields(with: all)["Cookie"])
        // http -> https on the same host: everything for that host and path goes.
        let upgraded = redirect(from: "http://chat.example.com/socket.io/", to: "https://chat.example.com/socket.io/",
                                cookies: [host, parent, scoped]) ?? ""
        for name in ["host=", "parent=", "scoped="] { XCTAssertTrue(upgraded.contains(name), upgraded) }
        // A sibling host of the parent domain only gets the parent-domain cookie.
        XCTAssertEqual(redirect(from: "https://chat.example.com/socket.io/", to: "https://node3.example.com/socket.io/",
                                cookies: all), "parent=v")
        // Another port of the same host keeps host cookies (cookies are not port-scoped).
        let otherPort = redirect(from: "https://chat.example.com/socket.io/", to: "https://chat.example.com:8443/socket.io/",
                                 cookies: [host]) ?? ""
        XCTAssertEqual(otherPort, "host=v")
        // A foreign domain gets nothing; a Secure cookie never goes over plain http.
        XCTAssertNil(redirect(from: "https://chat.example.com/socket.io/", to: "https://evil.test/socket.io/", cookies: all))
        XCTAssertNil(redirect(from: "http://chat.example.com/socket.io/", to: "http://chat.example.com:8080/socket.io/",
                              cookies: [secure]))
        // A path-scoped cookie stays out of other paths.
        XCTAssertEqual(redirect(from: "https://chat.example.com/socket.io/", to: "https://node3.example.com/other/",
                                cookies: [scoped, parent]), "parent=v")
    }
}

// MARK: Scoped configured cookies (scan finding G, breaking in 18.0.0)

extension SocketSecurityHardeningTest {
    private func cookieHeader(engineURL: String, request: String, cookies: [HTTPCookie]) -> String? {
        let url = URL(string: engineURL)!
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: url, config: [.cookies(cookies)])
        var urlRequest = URLRequest(url: URL(string: request)!)
        engine.addHeaders(to: &urlRequest)
        return urlRequest.value(forHTTPHeaderField: "Cookie")
    }

    func testConfiguredCookiesOnlyReachHostsTheyAreScopedTo() {
        let own = cookie("own", domain: "chat.example.com")
        let parent = cookie("parent", domain: ".example.com")
        let foreign = cookie("foreign", domain: "evil.test")
        let secure = cookie("secure", domain: "chat.example.com", secure: true)
        let all = [own, parent, foreign, secure]

        XCTAssertEqual(cookieHeader(engineURL: "http://chat.example.com/",
                                    request: "http://chat.example.com/socket.io/?EIO=4&transport=polling",
                                    cookies: all), "own=v; parent=v")
        XCTAssertEqual(cookieHeader(engineURL: "https://chat.example.com/",
                                    request: "wss://chat.example.com/socket.io/?EIO=4&transport=websocket",
                                    cookies: all), "own=v; parent=v; secure=v")
        XCTAssertNil(cookieHeader(engineURL: "https://other.test/", request: "https://other.test/socket.io/",
                                  cookies: [own, foreign]))
    }

    func testExplicitCookieHeaderIsStillSentAsWritten() {
        let url = URL(string: "https://chat.example.com/")!
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: url, config: [
            .cookies([cookie("foreign", domain: "evil.test")]), .extraHeaders(["Cookie": "app=explicit"])
        ])
        var request = URLRequest(url: URL(string: "https://chat.example.com/socket.io/")!)
        engine.addHeaders(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "app=explicit")
    }
}

// MARK: Super review of PR #31

private final class ReviewTransport: EngineWebSocketTransport {
    var onEvent: ((EngineWebSocketEvent) -> Void)?
    var isWritable = true
    func connect() {}
    func sendBatch(_ messages: [EngineWebSocketMessage], completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func close(code: Int, reason: Data?) {}
    func abort() {}
}

extension SocketSecurityHardeningTest {
    private func connectedManager(_ label: String) -> (SocketManager, CaptureEngine, DispatchQueue) {
        let queue = DispatchQueue(label: label)
        let manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue), .autoConnect(false)])
        let engine = CaptureEngine()
        queue.sync {
            manager.engine = engine
            manager.setTestStatus(.connected)
        }
        return (manager, engine, queue)
    }

    private func connects(_ engine: CaptureEngine) -> [String] {
        engine.sentPackets.filter { $0.hasPrefix("0") }
    }

    // D: replacing the provider while its callback is pending must not strand the attempt.
    func testReplacingTheProviderWhileItsCallbackIsPendingResolvesAgain() {
        let (manager, engine, queue) = connectedManager("test.review.replace")
        let socket = manager.defaultSocket
        var pending: SocketAuthCallback?
        socket.setAuth { callback in pending = callback }
        queue.sync { socket.connect(timeoutAfter: 0, withHandler: nil) }
        queue.sync {}
        XCTAssertNotNil(pending)

        socket.setAuth { callback in callback(["token": "rotated"]) }
        queue.sync {}
        queue.sync {}
        pending?(["token": "replaced"])
        queue.sync {}
        queue.sync {}

        queue.sync {
            XCTAssertEqual(connects(engine), ["0/,{\"token\":\"rotated\"}"])
            XCTAssertEqual(socket.status, .connecting)
        }
    }

    func testClearingTheProviderWhileItsCallbackIsPendingConnectsWithoutIt() {
        let (manager, engine, queue) = connectedManager("test.review.clear")
        let socket = manager.defaultSocket
        var pending: SocketAuthCallback?
        socket.setAuth { callback in pending = callback }
        queue.sync { socket.connect(timeoutAfter: 0, withHandler: nil) }
        queue.sync {}

        socket.clearAuth()
        queue.sync {}
        queue.sync {}
        pending?(["token": "replaced"])
        queue.sync {}
        queue.sync {}

        queue.sync { XCTAssertEqual(connects(engine), ["0/,"]) }
    }

    func testSetAuthFromAStatusChangeListenerStillJoins() {
        let (manager, engine, queue) = connectedManager("test.review.listener")
        let socket = manager.defaultSocket
        queue.sync {
            socket.on(clientEvent: .statusChange) { _, _ in
                guard socket.status == .connecting else { return }
                socket.setAuth { callback in callback(["token": "listener"]) }
            }
            socket.connect(timeoutAfter: 0, withHandler: nil)
        }
        queue.sync {}
        queue.sync {}

        queue.sync { XCTAssertEqual(connects(engine), ["0/,{\"token\":\"listener\"}"]) }
    }

    // I: a namespace joined without connect() accepts the server's reply.
    func testJoinWithoutConnectAcceptsTheServerConnect() throws {
        let (manager, engine, queue) = connectedManager("test.review.join")
        let socket = manager.socket(forNamespace: "/admin")
        try queue.sync {
            manager.connectSocket(socket, withPayload: nil)
            XCTAssertEqual(connects(engine), ["0/admin,"])
            socket.handlePacket(try manager.parseString("0/admin,{\"sid\":\"s1\"}"))
            XCTAssertEqual(socket.status, .connected)
        }
    }

    // H: a timed-out or failed attempt is not revived by a late server CONNECT.
    func testTimedOutSocketIgnoresALateConnect() throws {
        let manager = SocketManager(socketURL: url, config: [.log(false), .autoConnect(false), .reconnects(false)])
        manager.engine = MockEngine()
        let socket = manager.defaultSocket
        var connected = 0
        socket.on(clientEvent: .connect) { _, _ in connected += 1 }
        let timedOut = expectation(description: "timed out")
        socket.connect(timeoutAfter: 0.02) { timedOut.fulfill() }
        wait(for: [timedOut], timeout: 1)
        XCTAssertEqual(socket.status, .disconnected)

        socket.handlePacket(try manager.parseString("2[\"late\",1]"))
        socket.handlePacket(try manager.parseString("0{\"sid\":\"late\"}"))

        XCTAssertEqual(socket.status, .disconnected)
        XCTAssertEqual(connected, 0)
        XCTAssertEqual(socket.testRetainedBuffers.replayPackets, 0)
    }

    func testFailedAuthSocketIgnoresALateConnect() throws {
        let (manager, _, queue) = connectedManager("test.review.failed")
        let socket = manager.defaultSocket
        let failed = expectation(description: "auth failed")
        socket.on(clientEvent: .error) { _, _ in failed.fulfill() }
        socket.setAuth { () async throws -> [String: Any]? in throw URLError(.userAuthenticationRequired) }
        queue.sync { socket.connect(timeoutAfter: 0, withHandler: nil) }
        wait(for: [failed], timeout: 2)
        queue.sync {}

        try queue.sync {
            XCTAssertEqual(socket.status, .notConnected)
            XCTAssertTrue(socket.active)
            socket.handlePacket(try manager.parseString("0{\"sid\":\"late\"}"))
            XCTAssertEqual(socket.status, .notConnected)
        }
    }

    // G: an `.error` handler that retries is not aborted by the failure it handles.
    func testErrorHandlerRetryIsNotAbortedByTheFailureItHandles() {
        let (manager, engine, queue) = connectedManager("test.review.retry")
        let socket = manager.defaultSocket
        var retried = false
        queue.sync {
            socket.on(clientEvent: .error) { _, _ in
                guard !retried else { return }
                retried = true
                socket.connect(withPayload: ["token": "ok"], timeoutAfter: 0, withHandler: nil)
            }
            socket.connect(withPayload: ["bad": Double.nan], timeoutAfter: 0, withHandler: nil)
        }
        queue.sync {}

        queue.sync {
            XCTAssertTrue(retried)
            XCTAssertEqual(connects(engine), ["0/,{\"token\":\"ok\"}"])
            XCTAssertEqual(socket.status, .connecting)
        }
    }

    // E/F: a transport drop retires the pending provider callback.
    func testTransportDropRetiresThePendingProviderCallback() {
        let (manager, engine, queue) = connectedManager("test.review.drop")
        let socket = manager.defaultSocket
        var pending: SocketAuthCallback?
        socket.setAuth { callback in pending = callback }
        queue.sync { socket.connect(timeoutAfter: 0, withHandler: nil) }
        queue.sync {}

        queue.sync { socket.connectAttemptLostTransport() }
        pending?(["token": "dead-transport"])
        queue.sync {}
        queue.sync {}

        queue.sync {
            XCTAssertTrue(connects(engine).isEmpty, "\(engine.sentPackets)")
            XCTAssertEqual(socket.status, .connecting, "the parked socket is rejoined on the next open")
        }
    }

    // P: server-set cookies do not outlive `.withCredentials`.
    func testDisablingCredentialsClearsServerSetCookies() throws {
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: url, config: [.withCredentials(true)])
        let jar = try XCTUnwrap(engine.credentialCookieStorage)
        jar.setCookie(try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "user-a",
                                                            .domain: "localhost", .path: "/"])))
        engine.setConfigs([.withCredentials(true)])
        XCTAssertEqual(jar.cookies?.count, 1, "kept while credentials stay enabled")

        engine.setConfigs([])
        engine.setConfigs([.withCredentials(true)])
        XCTAssertEqual(jar.cookies?.count ?? 0, 0)
    }

    // M: cookies of a redirected handshake belong to the host that answered.
    func testWebSocketCookiesAreStoredForTheHostThatAnswered() throws {
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: url, config: [.forceWebsockets(true), .withCredentials(true)])
        let transport = ReviewTransport()
        engine.webSocketTransportFactory = { _ in transport }
        engine.connect()
        engine.engineQueue.sync {}
        transport.onEvent?(.opened(protocol: nil, headers: ["Set-Cookie": "planted=1; Path=/"],
                                   url: URL(string: "ws://evil.test/socket.io/")!))
        engine.engineQueue.sync {}
        engine.engineQueue.sync {}
        defer { engine.disconnect(reason: "test"); engine.engineQueue.sync {} }

        let jar = try XCTUnwrap(engine.credentialCookieStorage)
        XCTAssertFalse(jar.cookies(for: URL(string: "http://localhost:1/")!)?.contains { $0.name == "planted" } ?? false)
        XCTAssertTrue(jar.cookies(for: URL(string: "http://evil.test/")!)?.contains { $0.name == "planted" } ?? false)
    }

    // N: a live polling session follows redirects with the current cookies.
    func testLivePollingRedirectsFollowTheCurrentCookies() {
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: url, config: [.cookies([cookie("old", domain: "localhost")])])
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil,
                                               redirectCookies: [cookie("old", domain: "localhost")])
        engine.pollingProxy = proxy

        engine.setConfigs([.cookies([cookie("new", domain: "localhost")])])
        XCTAssertEqual(proxy.redirectCookies.configured.map(\.name), ["new"])
        XCTAssertNil(proxy.redirectCookies.explicitHeader)

        engine.setConfigs([.extraHeaders(["cookie": "app=explicit"])])
        XCTAssertEqual(proxy.redirectCookies.configured.map(\.name), [])
        XCTAssertEqual(proxy.redirectCookies.explicitHeader, "app=explicit")
    }

    // X: a bare query item carries its secret in the name.
    func testValuelessQueryItemsAreRedacted() {
        let logged = SocketLogRedaction.url(URL(string: "https://chat.example.com/socket.io/?my-secret-token&EIO=4")!)
        XCTAssertFalse(logged.contains("my-secret-token"), logged)
        XCTAssertTrue(logged.contains("EIO=4"), logged)
    }

    // Z: assigning the current queue again keeps it marked as the handle queue.
    func testReassigningTheHandleQueueKeepsItsMarker() {
        let queue = DispatchQueue(label: "test.review.queue")
        let other = DispatchQueue(label: "test.review.other")
        let manager = SocketManager(socketURL: url, config: [.log(false), .handleQueue(queue), .autoConnect(false)])
        queue.sync {
            manager.handleQueue = queue
            XCTAssertTrue(manager.isOnHandleQueue)
        }
        manager.handleQueue = other
        queue.sync { XCTAssertFalse(manager.isOnHandleQueue) }
        other.sync { XCTAssertTrue(manager.isOnHandleQueue) }
    }

    // A, C, K: redirect cookie decisions.
    private func redirectHeader(from source: String, to target: String, configured: [HTTPCookie] = [],
                                jar: HTTPCookieStorage? = nil, explicit: String? = nil) -> String? {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil,
                                               redirectCookies: configured, redirectCookieStorage: jar,
                                               explicitCookieHeader: explicit)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = URLRequest(url: URL(string: source)!)
        original.setValue(explicit ?? HTTPCookie.requestHeaderFields(with: configured)["Cookie"],
                          forHTTPHeaderField: "Cookie")
        let task: URLSessionTask = source.hasPrefix("ws") ? session.webSocketTask(with: original)
                                                          : session.dataTask(with: original)
        var next = URLRequest(url: URL(string: target)!)
        next.allHTTPHeaderFields = original.allHTTPHeaderFields
        let response = HTTPURLResponse(url: URL(string: source)!, statusCode: 307, httpVersion: nil,
                                       headerFields: ["Location": target])!
        var decided: URLRequest??
        proxy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) {
            decided = .some($0)
        }
        return decided??.value(forHTTPHeaderField: "Cookie")
    }

    func testSameOriginRedirectIsRescopedByPath() {
        let scoped = cookie("scoped", domain: "chat.example.com", path: "/socket.io")
        let fresh = cookie("fresh", domain: "chat.example.com", path: "/new")
        XCTAssertNil(redirectHeader(from: "https://chat.example.com/socket.io/", to: "https://chat.example.com/other/",
                                    configured: [scoped]))
        XCTAssertEqual(redirectHeader(from: "https://chat.example.com/socket.io/", to: "https://chat.example.com/new/",
                                      configured: [scoped, fresh]), "fresh=v")
    }

    func testExplicitCookieHeaderFollowsOnlyTheConfiguredHost() {
        let configured = [cookie("configured", domain: ".example.com")]
        XCTAssertEqual(redirectHeader(from: "http://chat.example.com/socket.io/", to: "https://chat.example.com/socket.io/",
                                      configured: configured, explicit: "app=explicit"), "app=explicit")
        XCTAssertEqual(redirectHeader(from: "https://chat.example.com/socket.io/",
                                      to: "https://chat.example.com:8443/socket.io/",
                                      configured: configured, explicit: "app=explicit"), "app=explicit")
        // Another host gets neither the explicit header nor the cookies it replaced.
        XCTAssertNil(redirectHeader(from: "https://chat.example.com/socket.io/", to: "https://node3.example.com/socket.io/",
                                    configured: configured, explicit: "app=explicit"))
    }

    func testWebSocketRedirectLooksUpSecureJarCookies() throws {
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage!
        jar.setCookie(try XCTUnwrap(HTTPCookie(properties: [.name: "lb", .value: "node1", .domain: ".example.com",
                                                            .path: "/", .secure: "TRUE"])))
        let header = redirectHeader(from: "wss://chat.example.com/socket.io/", to: "wss://node3.example.com/socket.io/",
                                    jar: jar) ?? ""
        XCTAssertTrue(header.contains("lb=node1"), header)
    }

    // B, Q, V, U: RFC 6265 matching details.
    func testCookieMatchingUsesTheEncodedPathAndExactIPAddresses() {
        func names(_ cookies: [HTTPCookie], _ url: String) -> [String] {
            SocketCookieScope.cookies(cookies, allowedFor: URL(string: url)!).map(\.name)
        }
        XCTAssertEqual(names([cookie("a", domain: "h.test", path: "/a")], "https://h.test/a%2Fb/"), [])
        XCTAssertEqual(names([cookie("sp", domain: "h.test", path: "/my%20app")], "https://h.test/my%20app/socket.io/"), ["sp"])
        func optionalCookie(_ name: String, domain: String) -> HTTPCookie? {
            HTTPCookie(properties: [.name: name, .value: "v", .domain: domain, .path: "/"])
        }
        // Foundation may refuse some of these domains; whatever it accepts must match as RFC 6265 says.
        if let suffix = optionalCookie("ip", domain: ".0.0.1") {
            XCTAssertEqual(names([suffix], "http://127.0.0.1/socket.io/"), [])
        }
        XCTAssertEqual(names([cookie("ip", domain: "127.0.0.1")], "http://127.0.0.1:3000/socket.io/"), ["ip"])
        if let v6 = optionalCookie("v6", domain: "::1") {
            XCTAssertEqual(names([v6], "http://[::1]:3000/socket.io/"), ["v6"])
        }
        if let dot = optionalCookie("dot", domain: ".") {
            XCTAssertEqual(names([dot], "http://evil.test./"), [])
        }
        // However Foundation stores a dotless host, a cookie made for it still reaches it.
        let local = cookie("lh", domain: "localhost")
        XCTAssertEqual(names([local], "http://localhost:3000/socket.io/"), ["lh"], "stored domain: \(local.domain)")
        let fromResponse = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "resp=1; Path=/"],
                                              for: URL(string: "http://localhost:3000/")!)
        if !fromResponse.isEmpty {
            XCTAssertEqual(names(fromResponse, "http://localhost:3000/socket.io/"), ["resp"],
                           "stored domain: \(fromResponse.map(\.domain))")
        }
    }
}

// MARK: Redirects of a request with a body

private final class RewritingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let rewrite: (URLRequest) -> URLRequest
    var calls = 0
    init(rewrite: @escaping (URLRequest) -> URLRequest) { self.rewrite = rewrite }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        calls += 1
        completionHandler(rewrite(request))
    }
}

extension SocketSecurityHardeningTest {
    /// The proxy's decision for a redirect, built the way URLSession proposes
    /// it: 301-303 turn a POST into a GET without body, 307/308 keep both.
    private func bodyRedirect(_ method: String, status: Int, from source: String, to target: String,
                              delegate: URLSessionDelegate? = nil) -> URLRequest?? {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: delegate)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = URLRequest(url: URL(string: source)!)
        original.httpMethod = method
        if method == "POST" { original.httpBody = Data("40{\"token\":\"secret\"}".utf8) }
        let task = session.dataTask(with: original)
        var next = URLRequest(url: URL(string: target)!)
        if status == 307 || status == 308 {
            next.httpMethod = method
            next.httpBody = original.httpBody
        }
        let response = HTTPURLResponse(url: URL(string: source)!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Location": target])!
        var decided: URLRequest??
        proxy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) {
            decided = .some($0)
        }
        return decided
    }

    func testAPostFollowsOnly307Or308OnTheFirstHost() throws {
        let first = "http://chat.example.com/socket.io/?transport=polling"
        for status in [307, 308] {
            for target in ["http://chat.example.com/socket.io/?x", "https://CHAT.example.com:8443/socket.io/"] {
                let followed = try XCTUnwrap(bodyRedirect("POST", status: status, from: first, to: target), "\(status)")
                XCTAssertEqual(followed?.httpMethod, "POST", "\(status) \(target)")
                XCTAssertEqual(followed?.httpBody, Data("40{\"token\":\"secret\"}".utf8), "\(status) \(target)")
            }
            // The body, and with it the CONNECT auth payload, never reaches another host.
            for target in ["http://node3.example.com/socket.io/", "http://evil.test/socket.io/"] {
                XCTAssertEqual(bodyRedirect("POST", status: status, from: first, to: target), .some(nil),
                               "\(status) \(target)")
            }
        }
    }

    func testAPostIsNeverTurnedIntoAGet() {
        for status in [300, 301, 302, 303] {
            XCTAssertEqual(bodyRedirect("POST", status: status, from: "http://chat.example.com/socket.io/",
                                        to: "http://chat.example.com/socket.io/?x"), .some(nil), "\(status)")
        }
    }

    func testAGetFollowsEveryRedirectStatus() {
        for status in [300, 301, 302, 303, 307, 308] {
            let decided = bodyRedirect("GET", status: status, from: "http://chat.example.com/socket.io/",
                                       to: "http://node3.example.com/socket.io/")
            XCTAssertEqual(decided??.url?.host, "node3.example.com", "\(status)")
        }
    }

    func testASessionDelegateCannotWidenARedirectOfAPost() {
        let first = "http://chat.example.com/socket.io/"
        // Another host, or a GET instead of the POST, is refused after the delegate too.
        let otherHost = RewritingRedirectDelegate { request in
            var changed = request
            changed.url = URL(string: "http://evil.test/socket.io/")
            return changed
        }
        XCTAssertEqual(bodyRedirect("POST", status: 307, from: first, to: first + "?x", delegate: otherHost), .some(nil))
        XCTAssertEqual(otherHost.calls, 1)
        let toGet = RewritingRedirectDelegate { request in
            var changed = request
            changed.httpMethod = "GET"
            changed.httpBody = nil
            return changed
        }
        XCTAssertEqual(bodyRedirect("POST", status: 308, from: first, to: first + "?x", delegate: toGet), .some(nil))
        // A redirect refused up front is not offered to the delegate at all.
        let unused = RewritingRedirectDelegate { $0 }
        XCTAssertEqual(bodyRedirect("POST", status: 302, from: first, to: first + "?x", delegate: unused), .some(nil))
        XCTAssertEqual(unused.calls, 0)
    }

    /// The proxy's decision for a GET redirect whose current hop may differ
    /// from the first request, with credentials set on the request.
    private func credentialRedirect(first: String, current: String, to target: String,
                                    clientCertificate: URLCredential? = nil,
                                    delegate: URLSessionDelegate? = nil) -> URLRequest?? {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: delegate,
                                               clientCertificate: clientCertificate,
                                               credentialOrigin: URL(string: first))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: URL(string: first)!))
        var next = URLRequest(url: URL(string: target)!)
        next.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        next.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        let response = HTTPURLResponse(url: URL(string: current)!, statusCode: 307, httpVersion: nil,
                                       headerFields: ["Location": target])!
        var decided: URLRequest??
        proxy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) {
            decided = .some($0)
        }
        return decided
    }

    func testCredentialsEndWithTheFirstChangeOfOrigin() throws {
        let a = "https://chat.example.com/socket.io/"
        let same = try XCTUnwrap(credentialRedirect(first: a, current: a, to: a + "?x"))
        XCTAssertEqual(same?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(same?.value(forHTTPHeaderField: "Proxy-Authorization"), "Basic proxy-secret")
        for target in ["https://node3.example.com/socket.io/", "https://chat.example.com:8443/socket.io/"] {
            let other = try XCTUnwrap(credentialRedirect(first: a, current: a, to: target))
            XCTAssertNil(other?.value(forHTTPHeaderField: "Authorization"), target)
            XCTAssertNil(other?.value(forHTTPHeaderField: "Proxy-Authorization"), target)
        }
        // A -> B -> A: the hop back to the first origin does not restore them.
        let back = try XCTUnwrap(credentialRedirect(first: a, current: "https://node3.example.com/socket.io/", to: a))
        XCTAssertNil(back?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(back?.value(forHTTPHeaderField: "Proxy-Authorization"))
    }

    func testAClientCertificateBlocksRedirectsToAnotherOrigin() throws {
        // The proxy only checks that a certificate is configured.
        let certificate = URLCredential(user: "stand-in", password: "identity", persistence: .none)
        let a = "https://chat.example.com/socket.io/"
        let same = try XCTUnwrap(credentialRedirect(first: a, current: a, to: a + "?x", clientCertificate: certificate))
        XCTAssertEqual(same?.url?.absoluteString, a + "?x")
        for target in ["https://node3.example.com/socket.io/", "https://chat.example.com:8443/socket.io/",
                       "http://chat.example.com/socket.io/"] {
            XCTAssertEqual(credentialRedirect(first: a, current: a, to: target, clientCertificate: certificate),
                           .some(nil), target)
        }
        // Without a certificate the same redirect is followed.
        XCTAssertNotNil(credentialRedirect(first: a, current: a, to: "https://node3.example.com/socket.io/") ?? nil)
        // Refused up front without asking the delegate, and checked again after it.
        let unused = RewritingRedirectDelegate { $0 }
        XCTAssertEqual(credentialRedirect(first: a, current: a, to: "https://node3.example.com/socket.io/",
                                          clientCertificate: certificate, delegate: unused), .some(nil))
        XCTAssertEqual(unused.calls, 0)
        let elsewhere = RewritingRedirectDelegate { request in
            var changed = request
            changed.url = URL(string: "https://evil.test/socket.io/")
            return changed
        }
        XCTAssertEqual(credentialRedirect(first: a, current: a, to: a + "?x", clientCertificate: certificate,
                                          delegate: elsewhere), .some(nil))
        XCTAssertEqual(elsewhere.calls, 1)
    }

    func testAWebSocketHandshakeFollowsNoRedirect() {
        let queue = DispatchQueue(label: "redirect.websocket.unit")
        let first = URLRequest(url: URL(string: "wss://chat.example.com/socket.io/?transport=websocket")!)
        let connection = URLSessionWebSocketConnection(request: first, queue: queue, configuration: .ephemeral,
                                                       maximumMessageSize: 4096)
        let unused = RewritingRedirectDelegate { $0 }
        let proxy = WebSocketSessionDelegateProxy(owner: connection, tlsConfiguration: .systemDefault,
                                                  forwardingDelegate: unused)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: first)
        for target in ["wss://chat.example.com/socket.io/?x", "wss://node3.example.com/socket.io/"] {
            for status in [301, 302, 307, 308] {
                let response = HTTPURLResponse(url: first.url!, statusCode: status, httpVersion: nil,
                                               headerFields: ["Location": target])!
                var decided: URLRequest??
                proxy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: URL(string: target)!)) { decided = .some($0) }
                XCTAssertEqual(decided, .some(nil), "\(status) \(target)")
            }
        }
        XCTAssertEqual(unused.calls, 0)
    }
}
