import Foundation
import XCTest
@testable import SocketIO

/// Real URLSession redirects (Gemini scan F-05 and the redirect rules shared
/// with the Kotlin client): what a polling request carries after each hop.
final class RedirectCredentialsE2ETest: XCTestCase {
    private final class Observed: @unchecked Sendable {
        var body: [String: Any]?
        var error: Error?
        var status = 0
    }

    private var server: TestServerProcess!
    private var manager: SocketManager?

    override func setUpWithError() throws {
        server = try TestServerProcess.start(serverScript: "redirect-headers.mjs")
    }

    override func tearDown() {
        server?.stop()
        manager = nil
    }

    private var origin: String { "http://127.0.0.1:\(server.port)" }

    /// An engine for the fixture's origin server. Its requests are sent
    /// through a session configured like its polling session.
    private func makeEngine(_ config: SocketIOClientConfiguration, host: String = "127.0.0.1") -> SocketEngine {
        let base = URL(string: "http://\(host):\(server.port)")!
        let manager = SocketManager(socketURL: base, config: [.autoConnect(false)])
        self.manager = manager
        return SocketEngine(client: manager, url: base, config: config)
    }

    /// A request built the way the engine builds its polling requests.
    private func request(_ engine: SocketEngine, _ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        engine.addHeaders(to: &request)
        return request
    }

    /// Sends `request` through a session configured like the engine's polling
    /// session (`SocketEngine.resetEngine`), and stores the final response's
    /// cookies like `doRequest` does. Returns the final status and the echo.
    @discardableResult
    private func send(_ request: URLRequest, through engine: SocketEngine) throws -> (status: Int, body: [String: Any]?) {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil,
                                               requestCookies: engine.requestCookies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: proxy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let jar = engine.withCredentials ? engine.credentialCookies : nil
        let observed = Observed()
        let done = expectation(description: request.url?.absoluteString ?? "request")
        session.dataTask(with: request) { data, response, error in
            observed.error = error
            if let response = response as? HTTPURLResponse {
                observed.status = response.statusCode
                jar?.store(response)
            }
            observed.body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertNil(observed.error)
        return (observed.status, observed.body)
    }

    private func echo(_ engine: SocketEngine, _ url: String,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let (status, body) = try send(request(engine, url), through: engine)
        XCTAssertEqual(status, 200, url, file: file, line: line)
        return try XCTUnwrap(body, url, file: file, line: line)
    }

    private func cookie(_ name: String, value: String = "v", domain: String = "127.0.0.1", path: String = "/",
                        secure: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    /// `?set=` values for a Set-Cookie header on the fixture's redirect response.
    private func setting(_ cookies: String...) -> String {
        cookies.map { "set=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) }
            .joined(separator: "&")
    }

    // MARK: Configured and explicit cookies

    func testCookieHeaderStaysWithinTheOrigin() throws {
        let engine = makeEngine([.extraHeaders(["X-Api-Key": "key-value"]),
                                 .cookies([cookie("session", value: "cookie-secret")])])
        for status in [301, 302, 303, 307, 308] {
            let same = try echo(engine, "\(origin)/same?status=\(status)")
            XCTAssertEqual(same["cookie"] as? String, "session=cookie-secret", "same origin, \(status)")
            // Cookies are not port-scoped (RFC 6265): another port of the same
            // host keeps a host cookie, as in a browser.
            let port = try echo(engine, "\(origin)/port?status=\(status)")
            XCTAssertEqual(port["cookie"] as? String, "session=cookie-secret", "other port, \(status)")
            // A different host the cookie was never set for must not get it.
            let host = try echo(engine, "\(origin)/host?status=\(status)")
            XCTAssertTrue(host["cookie"] is NSNull, "other host, \(status): \(host)")
            XCTAssertEqual(host["apiKey"] as? String, "key-value", "other extra headers still follow")
        }
    }

    func testA300IsNotFollowed() throws {
        let engine = makeEngine([])
        let (status, body) = try send(request(engine, "\(origin)/same?status=300"), through: engine)
        XCTAssertEqual(status, 300)
        XCTAssertNil(body)
    }

    func testExplicitCookieReplacesManagedCookiesOnlyOnTheConfiguredHost() throws {
        let engine = makeEngine([.withCredentials(true), .cookies([cookie("configured"), cookie("local", domain: "localhost")]),
                                 .extraHeaders(["Cookie": "app=explicit"])])
        engine.credentialCookies?.store(responseHeaders: ["Set-Cookie": "server=1; Path=/"],
                                        from: URL(string: origin)!)
        // The explicit header is the whole Cookie header on the configured
        // host, on any port, and never reaches another host; that host gets
        // the managed cookies RFC 6265 allows for it.
        XCTAssertEqual(try echo(engine, "\(origin)/echo")["cookie"] as? String, "app=explicit")
        XCTAssertEqual(try echo(engine, "\(origin)/same")["cookie"] as? String, "app=explicit")
        XCTAssertEqual(try echo(engine, "\(origin)/port")["cookie"] as? String, "app=explicit")
        XCTAssertEqual(try echo(engine, "\(origin)/host")["cookie"] as? String, "local=v")
    }

    func testConfiguredAndServerCookiesAreOrderedByPathThenCreation() throws {
        let engine = makeEngine([.withCredentials(true),
                                 .cookies([cookie("short"), cookie("long", path: "/echo"), cookie("second")])])
        let jar = try XCTUnwrap(engine.credentialCookies)
        jar.store(responseHeaders: ["Set-Cookie": "server=1; Path=/"], from: URL(string: origin)!)
        jar.store(responseHeaders: ["Set-Cookie": "deep=1; Path=/echo"], from: URL(string: origin)!)
        // One header: longer paths first, then configured cookies in their
        // order before the server's (RFC 6265 §5.4).
        let expected = "long=v; deep=1; short=v; second=v; server=1"
        XCTAssertEqual(try echo(engine, "\(origin)/echo")["cookie"] as? String, expected)
        XCTAssertEqual(try echo(engine, "\(origin)/port")["cookie"] as? String, expected)
    }

    // MARK: Server cookies (.withCredentials)

    func testConfiguredAndServerCookiesBothFollowARedirect() throws {
        let engine = makeEngine([.withCredentials(true), .cookies([cookie("configured")])])
        engine.credentialCookies?.store(responseHeaders: ["Set-Cookie": "server=1; Path=/"],
                                        from: URL(string: origin)!)
        XCTAssertEqual(try echo(engine, "\(origin)/echo")["cookie"] as? String, "configured=v; server=1")
        XCTAssertEqual(try echo(engine, "\(origin)/port")["cookie"] as? String, "configured=v; server=1")
    }

    func testACookieSetOnARedirectHopReachesItsTarget() throws {
        let engine = makeEngine([.withCredentials(true)])
        let set = setting("hop=1; Path=/")
        // Stored for the host that set it before the next hop is built.
        XCTAssertEqual(try echo(engine, "\(origin)/port?\(set)")["cookie"] as? String, "hop=1")
        // It belongs to 127.0.0.1, not to the host the redirect points to.
        XCTAssertTrue(try echo(engine, "\(origin)/host?\(set)")["cookie"] is NSNull)
        // And it stays in the engine's jar for later requests.
        XCTAssertEqual(try echo(engine, "\(origin)/echo")["cookie"] as? String, "hop=1")
    }

    func testSecureCookiesFollowPlainHttpToLocalhost() throws {
        let engine = makeEngine([.withCredentials(true), .cookies([cookie("configured", domain: "localhost", secure: true)])],
                                host: "localhost")
        // http://localhost is a secure context, as in browsers: a Secure cookie
        // the server sets there is stored, and Secure cookies are sent.
        let echoed = try echo(engine, "http://localhost:\(server.port)/host?\(setting("server=1; Secure; Path=/"))")
        XCTAssertEqual(echoed["cookie"] as? String, "configured=v; server=1")
        // A redirect from 127.0.0.1 to http://localhost carries the Secure
        // cookie configured for localhost as well.
        let other = makeEngine([.cookies([cookie("configured", domain: "localhost", secure: true)])])
        XCTAssertEqual(try echo(other, "\(origin)/host")["cookie"] as? String, "configured=v")
    }

    func testPrefixedCookiesThatBreakTheirRulesAreNotStored() throws {
        let engine = makeEngine([.withCredentials(true)], host: "localhost")
        let set = setting("__Host-noSecure=1; Path=/", "__Secure-noSecure=1; Path=/", "__host-lower=1; Path=/",
                          "__Host-path=1; Secure; Path=/echo", "__Host-good=1; Secure; Path=/",
                          "__Secure-good=1; Secure; Path=/")
        let echoed = try echo(engine, "http://localhost:\(server.port)/host?\(set)")
        let cookies = Set(((echoed["cookie"] as? String) ?? "").components(separatedBy: "; "))
        XCTAssertEqual(cookies, ["__Host-good=1", "__Secure-good=1"])
    }

    // MARK: Authorization and Host

    func testAuthorizationFollowsOnlyWhileTheChainStaysOnTheFirstOrigin() throws {
        let engine = makeEngine([.extraHeaders(["Authorization": "Bearer secret", "Proxy-Authorization": "Basic proxy"])])
        // URLSession drops Authorization even on a redirect to the same
        // origin; it is put back while the chain has not left the first origin.
        for status in [301, 302, 303, 307, 308] {
            let same = try echo(engine, "\(origin)/same?status=\(status)")
            XCTAssertEqual(same["authorization"] as? String, "Bearer secret", "\(status)")
            XCTAssertEqual(same["proxyAuthorization"] as? String, "Basic proxy", "\(status)")
        }
        for path in ["port", "host", "bounce"] {
            let other = try echo(engine, "\(origin)/\(path)")
            XCTAssertTrue(other["authorization"] is NSNull, "\(path): \(other)")
            XCTAssertTrue(other["proxyAuthorization"] is NSNull, "\(path): \(other)")
        }
    }

    func testACustomHostHeaderIsRemovedWhenTheHostOrPortChanges() throws {
        let engine = makeEngine([.extraHeaders(["Host": "custom.example"])])
        let first = try echo(engine, "\(origin)/echo")
        let same = try echo(engine, "\(origin)/same")
        XCTAssertEqual(same["host"] as? String, first["host"] as? String, "same host and port: as on the first request")
        let port = try XCTUnwrap(try echo(engine, "\(origin)/port")["host"] as? String)
        XCTAssertTrue(port.hasPrefix("127.0.0.1:") && port != "127.0.0.1:\(server.port)", port)
        let host = try XCTUnwrap(try echo(engine, "\(origin)/host")["host"] as? String)
        XCTAssertTrue(host.hasPrefix("localhost:"), host)
    }

    // MARK: Requests with a body

    /// A polling POST through a real URLSession redirect.
    private func post(_ path: String, status: Int) throws -> (Int, [String: Any]?) {
        let engine = makeEngine([])
        var request = request(engine, "\(origin)/\(path)?status=\(status)")
        request.httpMethod = "POST"
        request.httpBody = Data("40{\"token\":\"secret\"}".utf8)
        return try send(request, through: engine)
    }

    func testAPostIsRepeatedOnlyBy307Or308OnTheFirstHost() throws {
        for status in [307, 308] {
            for path in ["same", "port"] {
                let (code, echo) = try post(path, status: status)
                XCTAssertEqual(code, 200, "\(path), \(status)")
                XCTAssertEqual(echo?["method"] as? String, "POST", "\(path), \(status)")
                XCTAssertEqual(echo?["body"] as? String, "40{\"token\":\"secret\"}", "\(path), \(status)")
            }
            // URLSession would resend the body to the other host; the task ends with the redirect instead.
            let (code, echo) = try post("host", status: status)
            XCTAssertEqual(code, status)
            XCTAssertNil(echo)
        }
        // URLSession would turn these into a GET without body and the packets would be lost.
        for status in [301, 302, 303] {
            let (code, echo) = try post("same", status: status)
            XCTAssertEqual(code, status)
            XCTAssertNil(echo)
        }
    }

    // MARK: WebSocket handshake

    /// URLSessionWebSocketTask follows handshake redirects (verified on macOS
    /// 27) and copied the Cookie header to any host. The transport's delegate
    /// refuses them, so the handshake fails like in browsers and Node `ws`.
    private func webSocketThroughRedirect(_ path: String) throws -> (body: [String: Any]?, error: Error?) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(server.port)/\(path)")!)
        request.setValue("session=cookie-secret", forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        let queue = DispatchQueue(label: "redirect.websocket.e2e")
        let connection = URLSessionWebSocketConnection(request: request, queue: queue, configuration: .ephemeral,
                                                       maximumMessageSize: 4096)
        defer { queue.sync { connection.cancel() } }
        let observed = Observed()
        let received = expectation(description: "handshake over \(path)")
        queue.sync {
            connection.start()
            connection.receive { result in
                switch result {
                case .success(.text(let text)):
                    observed.body = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                case .success(.binary): break
                case .failure(let error): observed.error = error
                }
                received.fulfill()
            }
        }
        wait(for: [received], timeout: 10)
        return (observed.body, observed.error)
    }

    func testWebSocketHandshakeFollowsNoRedirect() throws {
        // The echo endpoint itself still answers, so a failure below is the refused redirect.
        let direct = try webSocketThroughRedirect("ws-echo")
        XCTAssertEqual(direct.body?["cookie"] as? String, "session=cookie-secret")
        for path in ["ws-same", "ws-port", "ws-host"] {
            let redirected = try webSocketThroughRedirect(path)
            XCTAssertNil(redirected.body, "\(path): \(String(describing: redirected.body))")
            XCTAssertNotNil(redirected.error, path)
        }
    }
}

// MARK: A refused handshake redirect at the engine

private final class RedirectEngineClient: NSObject, SocketEngineClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _opens = 0
    private var _errors = [String]()
    private var _closes = [String]()
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var opens: Int { lock.lock(); defer { lock.unlock() }; return _opens }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return _errors }
    var closes: [String] { lock.lock(); defer { lock.unlock() }; return _closes }
    func engineDidOpen(reason: String) { lock.lock(); _opens += 1; lock.unlock(); onOpen() }
    func engineDidError(reason: String) { lock.lock(); _errors.append(reason); lock.unlock() }
    func engineDidClose(reason: String) { lock.lock(); _closes.append(reason); lock.unlock(); onClose() }
    func engineDidReceivePing() {}
    func engineDidReceivePong() {}
    func engineDidSendPong() {}
    func parseEngineMessage(_ msg: String) {}
    func parseEngineBinaryData(_ data: Data) {}
    func engineDidWebsocketUpgrade(headers: [String: String]) {}
}

extension RedirectCredentialsE2ETest {
    private func redirectedHandshakeEngine(_ transports: [SocketTransport]) -> (SocketEngine, RedirectEngineClient) {
        let client = RedirectEngineClient()
        let engine = SocketEngine(client: client, url: URL(string: origin)!,
                                  config: [.path("/eio/"), .transports(transports), .tryAllTransports(true)])
        return (engine, client)
    }

    /// The fixture answers the WebSocket handshake with a 307 that is not
    /// followed. That failure must be an error, so a WebSocket-first
    /// connection goes on to polling.
    func testARefusedHandshakeRedirectFallsBackToPolling() throws {
        let (engine, client) = redirectedHandshakeEngine([.websocket, .polling])
        let opened = expectation(description: "opened over polling")
        client.onOpen = { opened.fulfill() }
        engine.connect()
        wait(for: [opened], timeout: 10)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.polling)
            XCTAssertEqual(client.opens, 1)
            XCTAssertTrue(client.errors.isEmpty, "\(client.errors)")
            XCTAssertTrue(client.closes.isEmpty, "\(client.closes)")
        }
        engine.disconnect(reason: "test")
        engine.engineQueue.sync {}
    }

    /// Without another transport the refused redirect ends the attempt as a
    /// transport error, which the manager reconnects after.
    func testARefusedHandshakeRedirectIsATransportError() throws {
        let (engine, client) = redirectedHandshakeEngine([.websocket])
        let closed = expectation(description: "closed")
        client.onClose = { closed.fulfill() }
        engine.connect()
        wait(for: [closed], timeout: 10)
        engine.engineQueue.sync {
            XCTAssertEqual(client.opens, 0)
            XCTAssertEqual(client.errors.count, 1, "\(client.errors)")
            XCTAssertEqual(client.closes, ["transport error"])
        }
    }
}
