import Foundation
import XCTest
@testable import SocketIO

/// Real URLSession redirects (Gemini scan F-05): URLSession copies an explicit
/// `.cookies` header to any redirect target; only cookie-rule matches may follow.
final class RedirectCredentialsE2ETest: XCTestCase {
    private final class Observed: @unchecked Sendable {
        var body: [String: Any]?
        var error: Error?
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
}
