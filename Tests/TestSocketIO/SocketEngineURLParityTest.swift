import XCTest
@testable import SocketIO

/// Native absolute-URL equivalents of engine.io-client URI construction.
/// Relative/browser location inference is deliberately not claimed here.
final class SocketEngineURLParityTest: XCTestCase {
    // SocketEngine keeps its client weakly; retain the owner while rebuilding URLs.
    private var manager: SocketManager?

    override func tearDown() {
        manager = nil
        super.tearDown()
    }
    private func engine(_ url: String, _ options: SocketIOClientOption...) -> SocketEngine {
        let url = URL(string: url)!
        var config: SocketIOClientConfiguration = [.log(false), .autoConnect(false)]
        for option in options { config.insert(option) }
        let manager = SocketManager(socketURL: url, config: config)
        self.manager = manager
        return SocketEngine(client: manager, url: url, config: config)
    }

    private func assertURI(_ input: String, secure: Bool, port: Int? = nil,
                           host: String = "localhost", file: StaticString = #filePath, line: UInt = #line) {
        let engine = self.engine(input)
        let polling = URLComponents(url: engine.urlPolling, resolvingAgainstBaseURL: false)!
        let websocket = URLComponents(url: engine.urlWebSocket, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(polling.scheme, secure ? "https" : "http", file: file, line: line)
        XCTAssertEqual(websocket.scheme, secure ? "wss" : "ws", file: file, line: line)
        XCTAssertEqual(polling.host, host, file: file, line: line)
        XCTAssertEqual(websocket.host, host, file: file, line: line)
        XCTAssertEqual(polling.port, port, file: file, line: line)
        XCTAssertEqual(websocket.port, port, file: file, line: line)
        XCTAssertEqual(polling.path, "/engine.io/", file: file, line: line)
        XCTAssertEqual(websocket.path, "/engine.io/", file: file, line: line)
        XCTAssertEqual(polling.query, "transport=polling&b64=1&EIO=4", file: file, line: line)
        XCTAssertEqual(websocket.query, "transport=websocket&EIO=4", file: file, line: line)
    }

    func testHTTPWithoutPort() { assertURI("http://localhost", secure: false) }
    func testHTTPWithPort() { assertURI("http://localhost:8080", secure: false, port: 8080) }
    func testHTTPSWithoutPort() { assertURI("https://localhost", secure: true) }
    func testHTTPSWithPort() { assertURI("https://localhost:8443", secure: true, port: 8443) }
    func testWSWithoutPort() { assertURI("ws://localhost", secure: false) }
    func testWSSWithoutPort() { assertURI("wss://localhost", secure: true) }
    func testWSSWithPort() { assertURI("wss://localhost:8443", secure: true, port: 8443) }
    func testIPv6WithoutPort() { assertURI("http://[::1]", secure: false, host: "[::1]") }
    func testIPv6WithPort() { assertURI("http://[::1]:8080", secure: false, port: 8080, host: "[::1]") }
    func testWebSocketIPv6WithoutPort() { assertURI("ws://[::1]", secure: false, host: "[::1]") }
    func testWebSocketIPv6WithPort() { assertURI("wss://[::1]:8443", secure: true, port: 8443, host: "[::1]") }

    func testConfiguredPathAppliesToBothTransports() {
        let engine = self.engine("http://localhost/ignored", .path("/custom/engine/"))
        XCTAssertEqual(engine.urlPolling.path, "/custom/engine")
        XCTAssertEqual(engine.urlWebSocket.path, "/custom/engine")
        XCTAssertTrue(engine.urlPolling.absoluteString.contains("/custom/engine/?"))
        XCTAssertTrue(engine.urlWebSocket.absoluteString.contains("/custom/engine/?"))
    }

    func testProtocolIsNotSuppressedByEIOInsideAValueOrAnotherName() {
        let engine = self.engine("http://localhost/?token=EIO&notEIO=1")
        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&token=EIO&notEIO=1&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&token=EIO&notEIO=1&EIO=4")
    }

    func testCallerCannotOverrideEngineOwnedQueryKeys() {
        let engine = self.engine("http://localhost/?%45IO=3&transport=bad&sid=old&b64=0&token=x")
        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&token=x&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&token=x&EIO=4")
    }

    /// Engine.IO 4 is the only supported protocol version: neither the URL nor
    /// `connectParams` can change `EIO`.
    func testExplicitParametersReplaceURLAndProtocolVersionStaysAuthoritative() {
        let engine = self.engine("https://localhost/?old=secret",
                                 .connectParams(["EIO": "wrong", "transport": "bad", "token": "a&b"]))
        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&token=a%26b&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&token=a%26b&EIO=4")
    }

    func testResettingExplicitQueryToNilRestoresURLQuery() {
        let engine = self.engine("http://localhost/?token=original", .connectParams([:]))
        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&EIO=4")
        engine.connectParams = nil
        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&token=original&EIO=4")
    }
}


extension SocketEngineURLParityTest {
    func testConnectParamsEscapeCrashCharactersInKeysAndValues() {
        for (raw, encoded) in [("<", "%3C"), (">", "%3E"), ("\\", "%5C"), ("`", "%60")] {
            let engine = self.engine("https://localhost", .connectParams([raw: raw]))
            for url in [engine.urlPolling, engine.urlWebSocket] {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                XCTAssertTrue(components.percentEncodedQuery!.contains("&\(encoded)=\(encoded)&"))
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == raw })?.value, raw)
            }
        }
    }

    func testConnectParamsMatchEncodeURIComponent() {
        let input = "AZaz09-_.!~*'() /?:@&=+$,#[]%\"{}^|<>\\`é😀\n"
        let encoded = "AZaz09-_.!~*'()%20%2F%3F%3A%40%26%3D%2B%24%2C%23%5B%5D%25%22%7B%7D%5E%7C%3C%3E%5C%60%C3%A9%F0%9F%98%80%0A"
        let engine = self.engine("https://localhost", .connectParams(["value": input]))
        for url in [engine.urlPolling, engine.urlWebSocket] {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            XCTAssertTrue(components.percentEncodedQuery!.contains("&value=\(encoded)&"))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "value" })?.value, input)
        }
    }

    func testURLPathSelectsNamespaceWithoutChangingTransportPathOrExplicitSockets() {
        for (path, namespace) in [("", "/"), ("/", "/"), ("/admin", "/admin"),
                                  ("/admin/", "/admin/"), ("/a%2Fb", "/a%2Fb")] {
            let engine = self.engine("https://localhost" + path + "?token=x#ignored", .path("/custom/"))
            let manager = self.manager!
            XCTAssertEqual(manager.defaultSocket.nsp, namespace)
            XCTAssertTrue(manager.defaultSocket === manager.socket(forNamespace: namespace))
            XCTAssertEqual(manager.socket(forNamespace: "/other").nsp, "/other")
            XCTAssertEqual(manager.socket(forNamespace: "/").nsp, "/")
            for url in [engine.urlPolling, engine.urlWebSocket] {
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, "/custom/")
                XCTAssertTrue(url.absoluteString.contains("token=x"))
            }
        }
    }
}
