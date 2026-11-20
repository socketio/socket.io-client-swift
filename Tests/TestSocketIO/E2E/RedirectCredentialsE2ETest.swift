import Foundation
import XCTest
@testable import SocketIO

/// Real URLSession redirects (Gemini scan F-05): an explicit `.cookies` header
/// must not follow a redirect to another origin. URLSession itself copies it.
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
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: .systemDefault, forwardingDelegate: nil)
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
            for path in ["port", "host"] {
                let other = try requestThroughRedirect(path, status: status, port: server.port)
                XCTAssertTrue(other["cookie"] is NSNull, "\(path), \(status): \(other)")
                XCTAssertEqual(other["apiKey"] as? String, "key-value", "other extra headers still follow")
            }
        }
    }
}
