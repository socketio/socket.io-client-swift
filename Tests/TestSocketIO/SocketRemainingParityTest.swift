import Foundation
import XCTest
@testable import SocketIO

private class RemainingUnitClient: NSObject, SocketEngineClient {
    var errors = [String]()
    var closes = [String]()
    var closeError: SocketTransportError?
    func engineDidError(reason: String) { errors.append(reason) }
    func engineDidClose(reason: String) { closes.append(reason) }
    func engineDidClose(reason: String, error: SocketTransportError) { closes.append(reason); closeError = error }
    func engineDidOpen(reason: String) {}
    func engineDidReceivePing() {}
    func engineDidReceivePong() {}
    func engineDidSendPong() {}
    func parseEngineMessage(_ msg: String) {}
    func parseEngineBinaryData(_ data: Data) {}
    func engineDidWebsocketUpgrade(headers: [String: String]) {}
}
/// Records both hooks to catch duplicate delivery and loss of structured details.
private final class RemainingStructuredClient: RemainingUnitClient {
    var errorDetails: [SocketTransportError] = []
    var events: [String] = []
    func engineDidError(reason: String, error: SocketTransportError) {
        errors.append(reason)
        errorDetails.append(error)
        events.append("error")
    }
    override func engineDidClose(reason: String, error: SocketTransportError) {
        super.engineDidClose(reason: reason, error: error)
        events.append("close")
    }
}

private final class RemainingLegacyErrorEngine: SocketEngine {
    var observedErrors: [String] = []
    override func didError(reason: String) {
        observedErrors.append(reason)
        super.didError(reason: reason)
    }
}

private final class RemainingUnitTransport: EngineWebSocketTransport {
    var onEvent: ((EngineWebSocketEvent) -> Void)?
    var isWritable = true
    var messages: [EngineWebSocketMessage] = []
    func connect() {}
    func sendBatch(_ messages: [EngineWebSocketMessage], completion: @escaping (Result<Void, Error>) -> Void) {
        self.messages += messages; completion(.success(()))
    }
    func close(code: Int, reason: Data?) {}
    func abort() {}
}

final class SocketRemainingParityTest: XCTestCase {
    private var client = RemainingUnitClient()
    private func engine(_ options: [SocketIOClientOption] = []) -> SocketEngine {
        var config: SocketIOClientConfiguration = [.log(false)]
        options.forEach { config.insert($0) }
        return SocketEngine(client: client, url: URL(string: "http://localhost:1234")!, config: config)
    }
    private func settle(_ engine: SocketEngine) { engine.engineQueue.sync {}; engine.engineQueue.sync {} }

    func testTransportOptionsDictionaryConversion() {
        let values: [String: Any] = ["withCredentials": true, "forceBase64": true, "addTrailingSlash": false]
        let config = values.toSocketConfiguration()
        for option in config {
            XCTAssertEqual(option.getSocketIOOptionValue() as? Bool, values[option.description] as? Bool)
        }
        XCTAssertEqual(config.count, 3)
        let instance = engine(Array(config))
        XCTAssertTrue(instance.withCredentials)
        XCTAssertTrue(instance.forceBase64)
        XCTAssertFalse(instance.addTrailingSlash)
    }
    func testWrongTypeTransportOptionsAreRejected() {
        for key in ["withCredentials", "forceBase64", "addTrailingSlash"] {
            let config = [key: "not-a-bool"].toSocketConfiguration()
            XCTAssertEqual(config.count, 1)
            guard case .invalidConfiguration = config[config.startIndex] else {
                return XCTFail("\(key) must not silently use a default")
            }
        }
    }
    func testTrailingSlashIndependentOfConfigurationOrder() {
        for options: [SocketIOClientOption] in [
            [.path("/custom/"), .addTrailingSlash(false)],
            [.addTrailingSlash(false), .path("/custom/")],
            [.path("/custom"), .addTrailingSlash(false)]
        ] {
            let instance = engine(options)
            XCTAssertEqual(instance.urlPolling.path, "/custom")
            XCTAssertEqual(instance.urlWebSocket.path, "/custom")
        }
        XCTAssertEqual(URLComponents(url: engine([.path("/custom")]).urlPolling, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/custom/")
    }
    func testProtocolVersionsHaveNativeWireConstants() {
        // Version selection is removed in the integration branch. Every
        // transport configuration must retain the Engine.IO 4 wire constant.
        for options: [SocketIOClientOption] in [[], [.forcePolling(true)],
                [.forceWebsockets(true)], [.forceBase64(true)]] {
            XCTAssertEqual(engine(options).engineIOParam, "&EIO=4")
        }
    }
    func testContradictoryTransportOptionsFailBeforeNetwork() {
        let instance = engine([.forcePolling(true), .forceWebsockets(true)])
        var calls = 0
        instance.webSocketTransportFactory = { _ in calls += 1; return RemainingUnitTransport() }
        instance.connect(); settle(instance)
        instance.engineQueue.sync {
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertTrue(instance.closed)
        }
    }
    func testForcedBase64ControlsWebSocketBatch() {
        for base64 in [false, true] {
            let instance = engine([.forceWebsockets(true), .forceBase64(base64)])
            let transport = RemainingUnitTransport()
            instance.webSocketTransportFactory = { _ in transport }
            instance.connect(); settle(instance)
            transport.onEvent?(.opened(protocol: nil)); settle(instance)
            instance.sendWebSocketMessage("header", withType: .message, withData: [Data([0, 1, 2]), Data()], completion: nil)
            settle(instance)
            instance.engineQueue.sync {
                let expected: [EngineWebSocketMessage] = base64
                    ? [.text("4header"), .text("bAAEC"), .text("b")]
                    : [.text("4header"), .binary(Data([0, 1, 2])), .binary(Data())]
                XCTAssertEqual(transport.messages, expected)
                XCTAssertEqual(instance.urlWebSocket.query?.contains("b64=1"), base64)
                XCTAssertEqual(instance.engineIOParam, "&EIO=4")
            }
            instance.disconnect(reason: "test"); settle(instance)
        }
    }

    private func cookie(_ name: String = "server") -> HTTPCookie {
        HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: name, .value: "yes"])!
    }
    private func captureWebSocketRequest(_ instance: SocketEngine) -> URLRequest? {
        var request: URLRequest?
        instance.webSocketTransportFactory = { request = $0; return RemainingUnitTransport() }
        instance.connect(); settle(instance)
        let snapshot = instance.engineQueue.sync { request }
        instance.disconnect(reason: "test"); settle(instance)
        return snapshot
    }
    func testDisabledCredentialsNeverReadStoredCookiesForWebSocket() {
        let instance = engine([.forceWebsockets(true), .withCredentials(false)])
        instance.credentialCookieStorage?.setCookie(cookie())
        XCTAssertNil(captureWebSocketRequest(instance)?.value(forHTTPHeaderField: "Cookie"))
    }
    func testEnabledCredentialsUsePrivateStoreAndSurviveReconnect() {
        let instance = engine([.forceWebsockets(true), .withCredentials(true)])
        instance.credentialCookieStorage?.setCookie(cookie())
        XCTAssertEqual(captureWebSocketRequest(instance)?.value(forHTTPHeaderField: "Cookie"), "server=yes")
        XCTAssertEqual(captureWebSocketRequest(instance)?.value(forHTTPHeaderField: "Cookie"), "server=yes")
        let independent = engine([.forceWebsockets(true), .withCredentials(true)])
        XCTAssertFalse(instance.credentialCookieStorage === independent.credentialCookieStorage)
        XCTAssertFalse(instance.credentialCookieStorage === HTTPCookieStorage.shared)
        XCTAssertNil(captureWebSocketRequest(independent)?.value(forHTTPHeaderField: "Cookie"))
    }
    func testExplicitCookieHeaderRemainsExplicitWhenCredentialsDisabled() {
        let instance = engine([.forceWebsockets(true), .withCredentials(false), .cookies([cookie()]),
                               .extraHeaders(["Cookie": "application=explicit"])])
        XCTAssertEqual(captureWebSocketRequest(instance)?.value(forHTTPHeaderField: "Cookie"), "application=explicit")
    }
    func testFilterUpgradesReturnsOnlyAvailableTransports() {
        let instance = engine([.transports([.polling])])
        XCTAssertEqual(instance.filterUpgrades(["polling", "websocket"]), [.polling])
    }
    func testBothOriginalTransportListsRemainUnchanged() {
        for original: [SocketTransport] in [[.websocket, .polling], [.polling]] {
            var caller = original
            let instance = engine([.transports(caller)])
            XCTAssertEqual(caller, original)
            XCTAssertEqual(instance.transports, original)
            caller.removeAll()
            XCTAssertEqual(instance.transports, original, "The engine owns a value snapshot")
        }
    }
    func testOriginalPollingTimestampURI() throws { try assertTimestampURI(websocket: false, parameter: "t") }
    func testOriginalWebSocketTimestampURI() throws { try assertTimestampURI(websocket: true, parameter: "woot") }
    private func assertTimestampURI(websocket: Bool, parameter: String) throws {
        let instance = SocketEngine(client: client, url: URL(string: "http://localhost")!,
                                    config: [.path("/engine.io"), .addTrailingSlash(false),
                                             .timestampRequests(true), .timestampParam(parameter)])
        let url = websocket ? instance.urlWebSocketWithSid : instance.urlPollingWithSid
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, websocket ? "ws" : "http")
        XCTAssertEqual(components.host, "localhost")
        XCTAssertNil(components.port)
        XCTAssertEqual(components.path, "/engine.io")
        let timestamps = (components.queryItems ?? []).filter { $0.name == parameter }
        XCTAssertEqual(timestamps.count, 1)
        let value = try XCTUnwrap(timestamps.first?.value)
        XCTAssertNotNil(value.range(of: "^[0-9A-Za-z_-]+$", options: .regularExpression))
        XCTAssertFalse(value.isEmpty)
    }
    func testSimpleNativeCookieParsing() throws {
        let value = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "foo=bar"],
                                                  for: URL(string: "https://example.com/")!).first)
        XCTAssertEqual(value.name, "foo"); XCTAssertEqual(value.value, "bar")
    }
    func testComplexNativeCookieParsingRetainsSecurityScope() throws {
        let input = "foo=bar; Max-Age=1000; Domain=.example.com; Path=/; Expires=Tue, 01 Jul 2025 10:01:11 GMT; HttpOnly; Secure; SameSite=strict"
        let value = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": input],
                                                  for: URL(string: "https://example.com/")!).first)
        XCTAssertEqual(value.name, "foo"); XCTAssertEqual(value.value, "bar")
        XCTAssertEqual(value.domain, ".example.com"); XCTAssertEqual(value.path, "/")
        XCTAssertTrue(value.isSecure); XCTAssertTrue(value.isHTTPOnly)
        // Native policy retains domain/path/security attributes unlike JS's
        // simple name/value/expires CookieJar parser. No identical object shape claimed.
    }
    func testCookieValueContainingEqualsAndAmpersands() throws {
        let input = "foo=bar=bar&foo=foo&John=Doe&Doe=John; Domain=.example.com; Path=/; HttpOnly; Secure"
        let value = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": input],
                                                  for: URL(string: "https://example.com/")!).first)
        XCTAssertEqual(value.name, "foo")
        XCTAssertEqual(value.value, "bar=bar&foo=foo&John=Doe&Doe=John")
    }
    func testNativeCookieStoreRejectsWrongDomainAndPath() {
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage!
        let cookie = HTTPCookie(properties: [.domain: "example.com", .path: "/private", .name: "secret", .value: "1"])!
        jar.setCookie(cookie)
        XCTAssertEqual(jar.cookies(for: URL(string: "https://example.com/private/a")!)?.count, 1)
        XCTAssertTrue((jar.cookies(for: URL(string: "https://elsewhere.example/private/a")!) ?? []).isEmpty)
        XCTAssertTrue((jar.cookies(for: URL(string: "https://example.com/public")!) ?? []).isEmpty)
    }
    func testCloseDetailIncludesPeerCodeEvenWithReceiveError() {
        let instance = engine([.forceWebsockets(true)])
        let transport = RemainingUnitTransport()
        instance.webSocketTransportFactory = { _ in transport }
        instance.connect(); settle(instance)
        transport.onEvent?(.opened(protocol: nil)); settle(instance)
        transport.onEvent?(.closed(code: 1009, reason: Data("too big".utf8),
                                   error: NSError(domain: NSURLErrorDomain, code: -1005)))
        settle(instance)
        instance.engineQueue.sync {
            XCTAssertEqual(client.closes, ["transport close"])
            XCTAssertTrue(client.errors.isEmpty)
            XCTAssertEqual(client.closeError?.closeCode, 1009)
            XCTAssertEqual(client.closeError?.closeReason, "too big")
        }
    }
    func testStructuredFailurePreservesLegacyOverrideAndDeliversDetailsOnce() {
        let delegate = RemainingStructuredClient()
        let instance = RemainingLegacyErrorEngine(client: delegate,
            url: URL(string: "http://localhost")!, config: [.log(false)])
        let detail = SocketTransportError(transport: "polling", operation: "read")
        instance.didError(reason: "read failed", error: detail)
        settle(instance)
        instance.engineQueue.sync {
            XCTAssertEqual(instance.observedErrors, ["read failed"])
            XCTAssertEqual(delegate.errors, ["read failed"])
            XCTAssertEqual(delegate.errorDetails.count, 1)
            XCTAssertTrue(delegate.errorDetails.first === detail)
            XCTAssertTrue(delegate.closeError === detail)
            XCTAssertEqual(delegate.events, ["error", "close"])
            XCTAssertEqual(delegate.closes, ["transport error"])
            XCTAssertTrue(instance.closed)
        }
    }

    func testStructuredFailureFallsBackToLegacyDelegateOnce() {
        let instance = RemainingLegacyErrorEngine(client: client,
            url: URL(string: "http://localhost")!, config: [.log(false)])
        let detail = SocketTransportError(transport: "polling", operation: "write")
        instance.engineQueue.sync {
            instance.didError(reason: "write failed", error: detail)
            XCTAssertEqual(instance.observedErrors, ["write failed"])
            XCTAssertEqual(client.errors, ["write failed"])
            XCTAssertEqual(client.closes, ["transport error"])
            XCTAssertTrue(client.closeError === detail)
        }
    }

    func testTransportDetailBoundsResponseAndDoesNotLogIt() {
        let body = Data(repeating: 65, count: 5000)
        let response = HTTPURLResponse(url: URL(string: "https://example.com/?secret=hidden")!,
                                       statusCode: 400, httpVersion: nil, headerFields: nil)!
        let detail = SocketTransportError(transport: "polling", operation: "read", response: response, body: body)
        XCTAssertEqual(detail.httpStatusCode, 400)
        XCTAssertEqual(detail.responseText?.utf8.count, 4096)
        XCTAssertTrue(detail.responseTruncated)
        XCTAssertFalse(detail.description.contains("AAAA"))
        XCTAssertFalse(detail.description.contains("secret"))
    }
    func testInvalidUTF8ResponseRemainsBoundedAfterLossyDecoding() {
        let detail = SocketTransportError(transport: "polling", operation: "read", body: Data(repeating: 255, count: 4096))
        XCTAssertLessThanOrEqual(detail.responseText?.utf8.count ?? Int.max, 4096)
        XCTAssertTrue(detail.responseTruncated)
    }
    func testManagerPassesSameErrorToDisconnectAndDoesNotLeakIt() {
        let queue = DispatchQueue(label: "remaining.detail")
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                    config: [.handleQueue(queue), .log(false), .reconnects(false)])
        let socket = manager.defaultSocket
        let detail = SocketTransportError(transport: "polling", operation: "read")
        let done = expectation(description: "error then detailed disconnect")
        var events: [String] = []
        queue.sync {
            manager.setTestStatus(.connected); socket.setTestStatus(.connected); socket.setTestActive(true)
            socket.on(clientEvent: .error) { data, _ in
                events.append("error"); XCTAssertTrue(data.last as? SocketTransportError === detail)
            }
            socket.once(clientEvent: .disconnect) { data, _ in
                events.append("disconnect"); XCTAssertEqual(data.first as? String, "transport error")
                XCTAssertTrue(data.last as? SocketTransportError === detail); done.fulfill()
            }
        }
        manager.engineDidError(reason: "read failed", error: detail)
        manager.engineDidClose(reason: "transport error", error: detail)
        wait(for: [done], timeout: 2)
        queue.sync {
            XCTAssertEqual(events, ["error", "disconnect"])
            socket.setTestStatus(.connected)
            socket.once(clientEvent: .disconnect) { data, _ in XCTAssertEqual(data.count, 1) }
            socket.didDisconnect(reason: "application close")
        }
    }
}

extension SocketRemainingParityTest {
    func testDictionaryTransportSelectionPreservesOrderAndFlags() {
        let values: [String: Any] = ["transports": ["websocket", "polling"],
                                     "tryAllTransports": true, "rememberUpgrade": true]
        let instance = engine(Array(values.toSocketConfiguration()))
        XCTAssertEqual(instance.transports, [.websocket, .polling])
        XCTAssertTrue(instance.tryAllTransports)
        XCTAssertTrue(instance.rememberUpgrade)
        XCTAssertEqual(values["transports"] as? [String], ["websocket", "polling"])
    }

    func testInvalidDictionaryTransportSelectionFailsBeforeOpeningAnyTransport() {
        let invalid: [[String: Any]] = [
            ["transports": "polling"], ["transports": ["webtransport"]],
            ["transports": [] as [String]], ["transports": ["polling", "polling"]],
            ["tryAllTransports": "true"], ["rememberUpgrade": "false"]
        ]
        for values in invalid {
            let previousErrors = client.errors.count
            let instance = engine(Array(values.toSocketConfiguration()))
            instance.webSocketTransportFactory = { _ in
                XCTFail("Invalid transport configuration must not reach a transport")
                return RemainingUnitTransport()
            }
            instance.connect()
            settle(instance)
            instance.engineQueue.sync {
                XCTAssertTrue(instance.closed)
                XCTAssertFalse(instance.connected)
                XCTAssertEqual(client.errors.count, previousErrors + 1)
                XCTAssertTrue(client.errors.last?.contains("Invalid socket configuration") == true)
            }
        }
    }
}
