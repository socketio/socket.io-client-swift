import Foundation
import XCTest
@testable import SocketIO

/// Real URLSession redirects (Gemini scan F-05): URLSession copies an explicit
/// `.cookies` header to any redirect target; only cookie-rule matches may follow.
final class RedirectCredentialsE2ETest: XCTestCase {
    private final class Observed: @unchecked Sendable {
        var body: [String: Any]?
        var error: Error?
        var status = 0
    }

    private func requestThroughRedirect(_ path: String, status: Int, port: Int) throws -> [String: Any] {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "session", .value: "cookie-secret", .domain: "127.0.0.1", .path: "/"
        ]))
        let manager = SocketManager(socketURL: base, config: [.autoConnect(false)])
        let engine = SocketEngine(client: manager, url: base, config: [
            .extraHeaders(["X-Api-Key": "key-value"]), .cookies([cookie])
        ])
        var request = URLRequest(url: URL(string: "\(base)/\(path)?status=\(status)")!)
        engine.addHeaders(to: &request)
        // Configured like the engine's polling session (SocketEngine.resetEngine).
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil,
                                               redirectCookies: engine.cookies ?? [])
        let session = URLSession(configuration: .ephemeral, delegate: proxy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let observed = Observed()
        let done = expectation(description: "\(path) \(status)")
        session.dataTask(with: request) { data, _, error in
            observed.error = error
            observed.body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertNil(observed.error)
        return try XCTUnwrap(observed.body)
    }

    func testCookieHeaderStaysWithinTheOrigin() throws {
        let server = try TestServerProcess.start(serverScript: "redirect-headers.mjs")
        defer { server.stop() }
        for status in [301, 302, 307, 308] {
            let same = try requestThroughRedirect("same", status: status, port: server.port)
            XCTAssertEqual(same["cookie"] as? String, "session=cookie-secret", "same origin, \(status)")
            // Cookies are not port-scoped (RFC 6265): another port of the same
            // host keeps a host cookie, as in a browser.
            let port = try requestThroughRedirect("port", status: status, port: server.port)
            XCTAssertEqual(port["cookie"] as? String, "session=cookie-secret", "other port, \(status)")
            // A different host the cookie was never set for must not get it.
            let host = try requestThroughRedirect("host", status: status, port: server.port)
            XCTAssertTrue(host["cookie"] is NSNull, "other host, \(status): \(host)")
            XCTAssertEqual(host["apiKey"] as? String, "key-value", "other extra headers still follow")
        }
    }

    /// A polling POST through a real URLSession redirect: the status code of
    /// the response the task completes with, and the echo if it was followed.
    private func postThroughRedirect(_ path: String, status: Int, port: Int) throws -> (Int, [String: Any]?) {
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil)
        let session = URLSession(configuration: .ephemeral, delegate: proxy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)?status=\(status)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("40{\"token\":\"secret\"}".utf8)
        let observed = Observed()
        let done = expectation(description: "POST \(path) \(status)")
        session.dataTask(with: request) { data, response, error in
            observed.error = error
            observed.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            observed.body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertNil(observed.error)
        return (observed.status, observed.body)
    }

    func testAPostIsRepeatedOnlyBy307Or308OnTheFirstHost() throws {
        let server = try TestServerProcess.start(serverScript: "redirect-headers.mjs")
        defer { server.stop() }
        for status in [307, 308] {
            for path in ["same", "port"] {
                let (code, echo) = try postThroughRedirect(path, status: status, port: server.port)
                XCTAssertEqual(code, 200, "\(path), \(status)")
                XCTAssertEqual(echo?["method"] as? String, "POST", "\(path), \(status)")
                XCTAssertEqual(echo?["body"] as? String, "40{\"token\":\"secret\"}", "\(path), \(status)")
            }
            // URLSession would resend the body to the other host; the task ends with the redirect instead.
            let (code, echo) = try postThroughRedirect("host", status: status, port: server.port)
            XCTAssertEqual(code, status)
            XCTAssertNil(echo)
        }
        // URLSession would turn these into a GET without body and the packets would be lost.
        for status in [301, 302, 303] {
            let (code, echo) = try postThroughRedirect("same", status: status, port: server.port)
            XCTAssertEqual(code, status)
            XCTAssertNil(echo)
        }
    }

    /// URLSessionWebSocketTask follows handshake redirects (verified on macOS
    /// 27) and copied the Cookie header to any host. The transport's delegate
    /// refuses them, so the handshake fails like in browsers and Node `ws`.
    private func webSocketThroughRedirect(_ path: String, port: Int) throws -> (body: [String: Any]?, error: Error?) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/\(path)")!)
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
        let server = try TestServerProcess.start(serverScript: "redirect-headers.mjs")
        defer { server.stop() }
        // The echo endpoint itself still answers, so a failure below is the refused redirect.
        let direct = try webSocketThroughRedirect("ws-echo", port: server.port)
        XCTAssertEqual(direct.body?["cookie"] as? String, "session=cookie-secret")
        for path in ["ws-same", "ws-port", "ws-host"] {
            let redirected = try webSocketThroughRedirect(path, port: server.port)
            XCTAssertNil(redirected.body, "\(path): \(String(describing: redirected.body))")
            XCTAssertNotNil(redirected.error, path)
        }
    }
}
