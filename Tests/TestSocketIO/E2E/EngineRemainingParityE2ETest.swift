import Foundation
import XCTest
@testable import SocketIO

/// Raw Engine.IO callbacks are marshalled to main before touching XCTest state.
private final class RemainingEngineClient: NSObject, SocketEngineClient {
    var opened: () -> Void = {}
    var openedOnEngineQueue: () -> Void = {}
    var message: (EngineWebSocketMessage) -> Void = { _ in }
    var failed: (String, SocketTransportError?) -> Void = { _, _ in }
    var closed: (String, SocketTransportError?) -> Void = { _, _ in }
    func engineDidOpen(reason: String) {
        openedOnEngineQueue()
        DispatchQueue.main.socketAsync { self.opened() }
    }
    func parseEngineMessage(_ msg: String) { DispatchQueue.main.socketAsync { self.message(.text(msg)) } }
    func parseEngineBinaryData(_ data: Data) { DispatchQueue.main.socketAsync { self.message(.binary(data)) } }
    func engineDidError(reason: String) { DispatchQueue.main.socketAsync { self.failed(reason, nil) } }
    func engineDidError(reason: String, error: SocketTransportError) {
        DispatchQueue.main.socketAsync { self.failed(reason, error) }
    }
    func engineDidClose(reason: String) { DispatchQueue.main.socketAsync { self.closed(reason, nil) } }
    func engineDidClose(reason: String, error: SocketTransportError) {
        DispatchQueue.main.socketAsync { self.closed(reason, error) }
    }
    func engineDidReceivePing() {}
    func engineDidReceivePong() {}
    func engineDidSendPong() {}
    func engineDidWebsocketUpgrade(headers: [String: String]) {}
}

final class EngineRemainingParityE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var client: RemainingEngineClient!
    private var engine: SocketEngine!

    override func tearDown() {
        if let engine = engine {
            engine.disconnect(reason: "test teardown")
            engine.engineQueue.sync {}
        }
        server?.stop()
        engine = nil; client = nil; server = nil
        super.tearDown()
    }

    private func make(_ options: [SocketIOClientOption], maximum: Int? = nil,
                      environment: [String: String] = [:]) throws {
        server = try TestServerProcess.start(serverScript: "engine-parity-server.mjs",
                                            maxHttpBufferSize: maximum, extraEnvironment: environment)
        client = RemainingEngineClient()
        client.failed = { reason, _ in XCTFail("Unexpected transport failure: \(reason)") }
        var config: SocketIOClientConfiguration = [.log(false), .path("/engine.io/")]
        options.forEach { config.insert($0) }
        engine = SocketEngine(client: client, url: URL(string: "http://127.0.0.1:\(server.port)")!, config: config)
    }

    private func snapshot() throws -> [String: Any] {
        let (status, body) = try server.admin("/admin/snapshot", method: "GET")
        XCTAssertEqual(status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// One raw send must produce exactly one echo, preserving type, bytes and order.
    private func roundTrip(_ packets: [EngineWebSocketMessage], afterUpgrade: Bool = false) {
        let expected = packets
        let received = expectation(description: "all raw Engine.IO packets echoed")
        received.expectedFulfillmentCount = expected.count
        received.assertForOverFulfill = true
        var actual: [EngineWebSocketMessage] = []
        let send: () -> Void = { [self] in
            for packet in packets {
                switch packet {
                case .text(let value): engine.send(value, withData: [])
                case .binary(let data): engine.send(data)
                }
            }
        }
        client.message = { [self] packet in
            if afterUpgrade && packet == .text("__parity_upgraded__") {
                engine.engineQueue.sync { XCTAssertFalse(engine.polling); XCTAssertTrue(engine.wsConnected) }
                send()
            } else {
                actual.append(packet); received.fulfill()
            }
        }
        if !afterUpgrade { client.opened = send }
        engine.connect()
        wait(for: [received], timeout: 10)
        XCTAssertEqual(actual, expected)
    }

    private func assertServerGreeting(_ options: [SocketIOClientOption]) throws {
        try make(options, environment: ["SEND_GREETING": "1"])
        let greeting = expectation(description: "open precedes unsolicited server greeting")
        var opened = false
        client.opened = { opened = true }
        client.message = { packet in
            XCTAssertTrue(opened)
            XCTAssertEqual(packet, .text("hi"))
            greeting.fulfill()
        }
        engine.connect()
        wait(for: [greeting], timeout: 10)
        engine.engineQueue.sync { XCTAssertTrue(engine.connected); XCTAssertFalse(engine.sid.isEmpty) }
    }
    func testConnectLocalhostPolling() throws { try assertServerGreeting([.forcePolling(true)]) }
    func testConnectLocalhostWebSocket() throws { try assertServerGreeting([.forceWebsockets(true)]) }
    func testMultibyteUTF8Polling() throws {
        try make([.forcePolling(true)])
        roundTrip([.text("cash money €€€")])
    }
    func testUnicodeScalarBoundaries() throws {
        try make([.forcePolling(true)])
        // Exact scalar sequence of upstream connection.js, not only a common emoji.
        roundTrip([.text("\u{10000}-\u{EFFFF}\u{F0000}-\u{10FFFF}\u{E000}-\u{F8FF}")])
    }
    func testBinaryDataPolling() throws {
        try make([.forcePolling(true)])
        roundTrip([.binary(Data([0, 1, 2, 3, 4])), .binary(Data())])
    }
    func testBinaryDataWebSocket() throws {
        try make([.forceWebsockets(true)])
        roundTrip([.binary(Data([0, 1, 2, 3, 4])), .binary(Data())])
        let frames = try XCTUnwrap(snapshot()["frames"] as? [[String: Any]])
        XCTAssertTrue(frames.contains { ($0["binary"] as? Bool) == true })
    }
    func testBinaryAfterActualTransportUpgrade() throws {
        try make([], environment: ["EMIT_UPGRADE_MARKER": "1"])
        roundTrip([.binary(Data([0, 1, 2, 3, 4]))], afterUpgrade: true)
        let frames = try XCTUnwrap(snapshot()["frames"] as? [[String: Any]])
        XCTAssertTrue(frames.contains { ($0["binary"] as? Bool) == true })
    }
    func testBinaryThenMultibyteTextPolling() throws {
        try make([.forcePolling(true)])
        roundTrip([.binary(Data([0, 1, 2, 3, 4])), .text("cash money €€€")])
    }
    func testBinaryThenMultibyteTextAfterActualUpgrade() throws {
        try make([], environment: ["EMIT_UPGRADE_MARKER": "1"])
        roundTrip([.binary(Data([0, 1, 2, 3, 4])), .text("cash money €€€")], afterUpgrade: true)
    }
    func testBinarySentOnOpenWithDefaultTransports() throws {
        try make([])
        roundTrip([.binary(Data([0, 1, 2, 3, 4]))])
    }
    func testForcedBase64SentOnOpenWithDefaultTransports() throws {
        try make([.forceBase64(true)])
        roundTrip([.binary(Data([0, 1, 2, 3, 4]))])
    }
    func testForcedBase64Polling() throws {
        try make([.forcePolling(true), .forceBase64(true)])
        roundTrip([.binary(Data([0, 1, 2, 3, 4]))])
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        XCTAssertTrue(requests.contains { ($0["body"] as? String)?.contains("bAAECAwQ=") == true })
    }
    func testForcedBase64WebSocket() throws {
        try make([.forceWebsockets(true), .forceBase64(true)])
        roundTrip([.binary(Data([0, 1, 2, 3, 4])), .binary(Data())])
        let snapshot = try self.snapshot()
        let frames = try XCTUnwrap(snapshot["frames"] as? [[String: Any]])
        XCTAssertFalse(frames.contains { ($0["binary"] as? Bool) == true })
        XCTAssertTrue(frames.contains { ($0["payload"] as? String) == "bAAECAwQ=" })
        XCTAssertTrue(frames.contains { ($0["payload"] as? String) == "b" })
        let requests = try XCTUnwrap(snapshot["requests"] as? [[String: Any]])
        XCTAssertTrue(requests.contains { ($0["url"] as? String)?.contains("b64=1") == true })
    }
    func testForcedBase64AfterActualTransportUpgrade() throws {
        try make([.forceBase64(true)], environment: ["EMIT_UPGRADE_MARKER": "1"])
        roundTrip([.binary(Data([0, 1, 2, 3, 4])), .binary(Data())], afterUpgrade: true)
        let frames = try XCTUnwrap(snapshot()["frames"] as? [[String: Any]])
        XCTAssertFalse(frames.contains { ($0["binary"] as? Bool) == true })
        XCTAssertTrue(frames.contains { ($0["payload"] as? String) == "bAAECAwQ=" })
        XCTAssertTrue(frames.contains { ($0["payload"] as? String) == "b" })
    }
    private func assertCookiesAcrossUpgrade(_ enabled: Bool) throws {
        try make([.withCredentials(enabled)], environment: ["EMIT_UPGRADE_MARKER": "1"])
        roundTrip([.text("upgraded")], afterUpgrade: true)
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        let upgrade = try XCTUnwrap(requests.first { ($0["method"] as? String) == "UPGRADE" })
        let headers = try XCTUnwrap(upgrade["headers"] as? [String: Any])
        if enabled {
            let cookie = try XCTUnwrap(headers["cookie"] as? String)
            XCTAssertEqual(Set(cookie.components(separatedBy: "; ")), ["1=1", "2=2"])
        } else { XCTAssertNil(headers["cookie"]) }
    }
    func testCookiesSurvivePollingToWebSocketUpgrade() throws { try assertCookiesAcrossUpgrade(true) }
    func testDisabledCookiesStayDisabledDuringUpgrade() throws { try assertCookiesAcrossUpgrade(false) }

    func testBinaryMaxPayloadBatching() throws {
        try make([.forcePolling(true)], maximum: 100)
        roundTrip([.binary(Data(repeating: 0, count: 72)), .binary(Data(repeating: 0, count: 20)),
                   .text(String(repeating: "a", count: 20)), .binary(Data(repeating: 0, count: 20)),
                   .binary(Data(repeating: 0, count: 72))])
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        let posts = requests.filter { ($0["method"] as? String) == "POST" }
        XCTAssertGreaterThan(posts.count, 1)
        for request in posts { XCTAssertLessThanOrEqual(try XCTUnwrap(request["bytes"] as? Int), 100) }
    }

    func testOriginalSixMessagesRespectMaxPayloadIncludingUTF8() throws {
        try make([.forcePolling(true)], maximum: 100)
        let values = [("a", 99), ("b", 30), ("c", 30), ("d", 35), ("€", 33), ("f", 99)]
            .map { String(repeating: $0.0, count: $0.1) }
        roundTrip(values.map { .text($0) })
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        let posts = requests.filter { ($0["method"] as? String) == "POST" }
        XCTAssertGreaterThan(posts.count, 1)
        for post in posts { XCTAssertLessThanOrEqual(try XCTUnwrap(post["bytes"] as? Int), 100) }
    }

    func testSendImmediatelyAfterRealCloseDoesNotCreateAMessage() throws {
        try make([])
        let opened = expectation(description: "real engine opens")
        client.opened = { opened.fulfill() }
        client.message = { _ in XCTFail("No application message should arrive after close") }
        engine.connect()
        wait(for: [opened], timeout: 5)
        let closed = expectation(description: "engine closes")
        let refused = expectation(description: "refused write completes locally")
        client.closed = { _, _ in closed.fulfill() }
        engine.disconnect(reason: "io client disconnect")
        engine.send("hi", withData: []) { refused.fulfill() }
        wait(for: [closed, refused], timeout: 5)
        let settled = expectation(description: "no delayed packet")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        engine.engineQueue.sync { XCTAssertTrue(engine.postWait.isEmpty) }
        let observed = try snapshot()
        let requests = try XCTUnwrap(observed["requests"] as? [[String: Any]])
        XCTAssertFalse(requests.contains { ($0["body"] as? String)?.contains("4hi") == true })
        let frames = try XCTUnwrap(observed["frames"] as? [[String: Any]])
        XCTAssertFalse(frames.contains { ($0["payload"] as? String) == "4hi" })
    }

    private func assertRememberUpgradeAfterRealUpgrade(_ remember: Bool) throws {
        try make([], environment: ["EMIT_UPGRADE_MARKER": "1"])
        roundTrip([.text("first connection upgraded")], afterUpgrade: true)
        let firstRequests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        XCTAssertTrue((firstRequests.first?["url"] as? String)?.contains("transport=polling") == true)
        let closed = expectation(description: "upgraded connection closes")
        client.closed = { _, _ in closed.fulfill() }
        engine.disconnect(reason: "io client disconnect")
        wait(for: [closed], timeout: 5)
        let offset = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]]).count

        let secondClient = RemainingEngineClient()
        let second = SocketEngine(client: secondClient, url: URL(string: "http://127.0.0.1:\(server.port)")!,
                                  config: [.path("/engine.io/"), .rememberUpgrade(remember)])
        defer { second.disconnect(reason: "test teardown"); second.engineQueue.sync {} }
        let opened = expectation(description: "second connection opens")
        secondClient.opened = { opened.fulfill() }
        secondClient.failed = { reason, _ in XCTFail(reason) }
        second.connect()
        wait(for: [opened], timeout: 5)
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        let first = try XCTUnwrap(requests.dropFirst(offset).first)
        XCTAssertEqual(first["method"] as? String, remember ? "UPGRADE" : "GET")
        XCTAssertTrue((first["url"] as? String)?.contains(remember ? "transport=websocket" : "transport=polling") == true)
    }

    func testExplicitRememberUpgradeFalseStartsPollingAfterARealUpgrade() throws {
        try assertRememberUpgradeAfterRealUpgrade(false)
    }
    func testRememberUpgradeStartsWebSocketAfterARealUpgrade() throws {
        try assertRememberUpgradeAfterRealUpgrade(true)
    }

    private func assertFallbackFromRejectedTransport(_ first: SocketTransport) throws {
        let second: SocketTransport = first == .polling ? .websocket : .polling
        try make([.transports([first, second]), .tryAllTransports(true)],
                 environment: ["DENY_TRANSPORT": first.rawValue])
        client.closed = { reason, _ in XCTFail("Unexpected intermediate close: \(reason)") }
        let openingEngine = try XCTUnwrap(engine)
        client.openedOnEngineQueue = {
            XCTAssertTrue(openingEngine.connected)
            XCTAssertEqual(openingEngine.polling, second == .polling)
        }
        roundTrip([.text("fallback succeeded")])
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        XCTAssertTrue((requests.first?["url"] as? String)?.contains("transport=" + first.rawValue) == true)
        XCTAssertTrue(requests.contains { ($0["url"] as? String)?.contains("transport=" + second.rawValue) == true })
        client.closed = { _, _ in }
    }
    func testRealRejectedWebSocketFallsBackToPolling() throws { try assertFallbackFromRejectedTransport(.websocket) }
    func testRealRejectedPollingFallsBackToWebSocket() throws { try assertFallbackFromRejectedTransport(.polling) }
    func testRealRejectedPollingDoesNotFallbackByDefault() throws {
        try make([.transports([.polling, .websocket])], environment: ["DENY_TRANSPORT": "polling"])
        let failed = expectation(description: "polling rejection")
        let closed = expectation(description: "failed opening closes")
        client.opened = { XCTFail("No transport should open") }
        client.failed = { reason, detail in
            XCTAssertEqual(reason, "polling read (HTTP 403)")
            XCTAssertEqual(detail?.httpStatusCode, 403)
            XCTAssertEqual(detail?.transport, "polling")
            failed.fulfill()
        }
        client.closed = { reason, _ in XCTAssertEqual(reason, "transport error"); closed.fulfill() }
        engine.connect()
        wait(for: [failed, closed], timeout: 5)
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        XCTAssertFalse(requests.contains { ($0["method"] as? String) == "UPGRADE" })
        engine.engineQueue.sync { XCTAssertTrue(engine.closed) }
    }

    private func assertCookiePolicy(_ enabled: Bool) throws {
        try make([.forcePolling(true), .withCredentials(enabled)])
        roundTrip([.text("cookie check")])
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        let post = try XCTUnwrap(requests.first { ($0["method"] as? String) == "POST" })
        let headers = try XCTUnwrap(post["headers"] as? [String: Any])
        if enabled {
            let cookie = try XCTUnwrap(headers["cookie"] as? String)
            XCTAssertEqual(Set(cookie.components(separatedBy: "; ")), ["1=1", "2=2"])
        } else {
            XCTAssertNil(headers["cookie"])
        }
    }
    func testServerCookiesSentWhenEnabled() throws { try assertCookiePolicy(true) }
    func testServerCookiesNotSentWhenDisabled() throws { try assertCookiePolicy(false) }
    // Public upstream fixture values, not credentials.
    private let originalHeaders = [
        "X-Custom-Header-For-My-Project": "my-secret-access-token",
        "Cookie": "user_session=NI2JlCKF90aE0sJZD9ZzujtdsUqNYSBYxzlTsvdSUe35ZzdtVRGqYFr0kdGxbfc5gUOkR9RGp20GVKza; path=/; expires=Tue, 07-Apr-2015 18:18:08 GMT; secure; HttpOnly"
    ]
    func testExtraHeadersReachPollingGETAndPOST() throws {
        try assertOriginalExtraHeaders(websocket: false)
    }
    func testOriginalExtraHeadersReachWebSocket() throws {
        try assertOriginalExtraHeaders(websocket: true)
    }
    private func assertOriginalExtraHeaders(websocket: Bool) throws {
        try make([.transports(websocket ? [.websocket] : [.polling]), .extraHeaders(originalHeaders)])
        XCTAssertEqual(engine.extraHeaders, originalHeaders)
        roundTrip([.text("header check")])
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        for method in websocket ? ["UPGRADE"] : ["GET", "POST"] {
            let request = try XCTUnwrap(requests.first { ($0["method"] as? String) == method })
            let received = try XCTUnwrap(request["headers"] as? [String: Any])
            for (name, value) in originalHeaders { XCTAssertEqual(received[name.lowercased()] as? String, value) }
        }
    }
    func testNoTrailingSlashOnWire() throws {
        try make([.forcePolling(true), .addTrailingSlash(false)], environment: ["NO_TRAILING_SLASH": "1"])
        roundTrip([.text("no slash")])
        let requests = try XCTUnwrap(snapshot()["requests"] as? [[String: Any]])
        XCTAssertTrue(requests.allSatisfy { ($0["url"] as? String)?.hasPrefix("/engine.io?") == true })
    }

    private func expectFailure(status: Int?, code: Int?, operation: String,
                               start: () -> Void) {
        let closed = expectation(description: "one detailed close")
        closed.assertForOverFulfill = true
        var failures: [SocketTransportError] = []
        client.failed = { reason, detail in
            guard let detail else { return XCTFail("Missing typed transport error: " + reason) }
            XCTAssertEqual(detail.httpStatusCode, status)
            XCTAssertEqual(detail.operation, operation)
            XCTAssertEqual(detail.transport, status == nil ? "websocket" : "polling")
            if let status {
                XCTAssertEqual(detail.errorDescription, "polling \(operation) (HTTP \(status))")
                if status == 413 { XCTAssertEqual(detail.responseText, "") }
                if status == 400 {
                    XCTAssertEqual(detail.responseText, "{\"code\":1,\"message\":\"Session ID unknown\"}")
                }
            } else {
                XCTAssertNotNil(detail.underlyingError)
            }
            failures.append(detail)
        }
        client.closed = { reason, detail in
            XCTAssertEqual(reason, code == nil ? "transport error" : "transport close")
            XCTAssertNotNil(detail)
            XCTAssertEqual(detail?.httpStatusCode, status)
            XCTAssertEqual(detail?.closeCode, code)
            XCTAssertEqual(detail?.operation, operation)
            if code == nil {
                XCTAssertEqual(failures.count, 1)
                XCTAssertTrue(failures.first === detail, "Error and close must carry the same detail")
            } else {
                XCTAssertTrue(failures.isEmpty)
                XCTAssertEqual(detail?.closeReason, "")
                XCTAssertEqual(detail?.errorDescription, "websocket close (WebSocket \(code!))")
            }
            if status == 413 { XCTAssertEqual(detail?.responseText, "") }
            if status == 400 {
                XCTAssertEqual(detail?.responseText, "{\"code\":1,\"message\":\"Session ID unknown\"}")
            }
            closed.fulfill()
        }
        start()
        wait(for: [closed], timeout: 10)
    }
    func testOversizePollingReports413AndCloseDetail() throws {
        try make([.forcePolling(true)], maximum: 100)
        client.opened = { [self] in
            engine.send(String(repeating: "a", count: 101), withData: [])
            engine.send("b", withData: [])
        }
        expectFailure(status: 413, code: nil, operation: "write") { engine.connect() }
    }
    func testOversizeWebSocketReports1009AndCloseDetail() throws {
        try make([.forceWebsockets(true)], maximum: 100)
        client.opened = { [self] in engine.send(String(repeating: "a", count: 101), withData: []) }
        expectFailure(status: nil, code: 1009, operation: "close") { engine.connect() }
    }
    func testUnknownSIDPollingReports400BodyAndCloseDetail() throws {
        try make([.forcePolling(true)])
        // Inject a stale transport request, not a user query (sid is engine-owned).
        let url = URL(string: "http://127.0.0.1:\(server.port)/engine.io/?EIO=4&transport=polling&sid=missing")!
        expectFailure(status: 400, code: nil, operation: "read") {
            engine.engineQueue.sync {
                engine.setConnected(true)
                engine.setTestSession(URLSession(configuration: .ephemeral))
                engine.doLongPoll(for: URLRequest(url: url))
            }
        }
    }
    func testUnknownSIDWebSocketReportsErrorAndCloseDetail() throws {
        try make([.forceWebsockets(true)])
        let url = URL(string: "ws://127.0.0.1:\(server.port)/engine.io/?EIO=4&transport=websocket&sid=missing")!
        engine.webSocketTransportFactory = { [weak engine] _ in
            URLSessionWebSocketTransport(request: URLRequest(url: url), queue: engine!.engineQueue,
                                         configuration: .ephemeral)
        }
        expectFailure(status: nil, code: nil, operation: "close") { engine.connect() }
    }
}
