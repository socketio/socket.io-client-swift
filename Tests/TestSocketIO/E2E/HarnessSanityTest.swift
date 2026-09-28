import XCTest
@testable import SocketIO

final class HarnessSanityTest: XCTestCase {
    func testServerStartsAndAuthedPingWorks() throws {
        let server = try TestServerProcess.start()
        defer { server.stop() }

        let (status, body) = try server.admin("/admin/ping")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(data: body, encoding: .utf8), "pong")
    }

    func testUnauthedAdminRejected() throws {
        let server = try TestServerProcess.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/admin/ping")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var status = -1
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse { status = http.statusCode }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        XCTAssertEqual(status, 401)
    }
}
