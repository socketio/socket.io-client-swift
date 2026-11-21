import XCTest

final class TestServerProcessTest: XCTestCase {
    private var directory: URL!
    private var server: TestServerProcess?

    override func setUpWithError() throws {
        try TestServerProcess.ensureNodeModules()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func script(_ content: String) throws -> String {
        let url = directory.appendingPathComponent("fixture.cjs")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testSilentChildStartupIsBounded() throws {
        let path = try script("setInterval(() => {}, 1000);")
        let start = Date()
        XCTAssertThrowsError(try TestServerProcess.start(serverScript: path, startupTimeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testEarlyExitReportsStderrInsteadOfWaitingForDeadline() throws {
        let path = try script("console.error('fixture-startup-failed'); process.exitCode = 17;")
        let start = Date()
        XCTAssertThrowsError(try TestServerProcess.start(serverScript: path, startupTimeout: 10)) { error in
            guard case TestServerProcess.Error.serverDidNotStart(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("fixture-startup-failed"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testBothOutputPipesAreDrainedAndSplitReadyLineIsAccepted() throws {
        let path = try script("""
        process.stdout.write('x'.repeat(200000) + '\\n');
        process.stderr.write('y'.repeat(200000));
        process.stdout.write('READY port=1234 sec');
        setTimeout(() => {
          process.stdout.write('ret=abcdef\\n');
          setInterval(() => { process.stdout.write('z'.repeat(10000)); process.stderr.write('q'.repeat(10000)); }, 10);
        }, 20);
        """)
        server = try TestServerProcess.start(serverScript: path, startupTimeout: 5)
        XCTAssertEqual(server?.port, 1234)
        XCTAssertEqual(server?.secret, "abcdef")
    }

    func testInvalidReadyPortDoesNotCountAsStarted() throws {
        let path = try script("console.log('READY port=0 secret=abcdef'); setInterval(() => {}, 1000);")
        XCTAssertThrowsError(try TestServerProcess.start(serverScript: path, startupTimeout: 0.2))
    }

    func testChildIgnoringSIGTERMStillStopsBoundedly() throws {
        let path = try script("process.on('SIGTERM', () => {}); console.log('READY port=1234 secret=abcdef'); setInterval(() => {}, 1000);")
        server = try TestServerProcess.start(serverScript: path, startupTimeout: 5)
        let start = Date()
        server?.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testAdminRequestReturnsStatusBodyAndAuthentication() throws {
        let path = try script("""
        const http = require('node:http');
        const server = http.createServer((req, res) => {
          res.writeHead(202); res.end(req.headers['x-admin-secret']);
        });
        server.listen(0, '127.0.0.1', () => console.log(`READY port=${server.address().port} secret=abcdef`));
        """)
        server = try TestServerProcess.start(serverScript: path)
        let (status, data) = try XCTUnwrap(server).admin("/echo", method: "GET")
        XCTAssertEqual(status, 202)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "abcdef")
    }

    func testAdminTransportFailureIsReported() throws {
        let path = try script("""
        const server = require('node:http').createServer((req, res) => req.destroy());
        server.listen(0, '127.0.0.1', () => console.log(`READY port=${server.address().port} secret=abcdef`));
        """)
        server = try TestServerProcess.start(serverScript: path)
        XCTAssertThrowsError(try XCTUnwrap(server).admin("/close"))
    }

}
