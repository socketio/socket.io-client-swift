import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Starts a fixture with bounded startup, output retention and shutdown.
final class TestServerProcess {
    enum Error: Swift.Error { case nodeMissing, serverDidNotStart(String) }

    let port: Int
    let secret: String
    private let process: Process
    private let output: FixtureProcessOutput
    private static let installationLock = NSLock()

    private init(port: Int, secret: String, process: Process, output: FixtureProcessOutput) {
        self.port = port
        self.secret = secret
        self.process = process
        self.output = output
    }

    static func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func ensureNodeModules() throws {
        installationLock.lock()
        defer { installationLock.unlock() }
        let fixtures = fixturesDir()
        let lock = try Data(contentsOf: fixtures.appendingPathComponent("package-lock.json"))
        let marker = fixtures.appendingPathComponent("node_modules/.swift-fixture-lock")
        if (try? Data(contentsOf: marker)) == lock { return }
        let process = Process()
        process.currentDirectoryURL = fixtures
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 120) == .success else {
            terminateBoundedly(process)
            throw Error.nodeMissing
        }
        guard process.terminationStatus == 0 else { throw Error.nodeMissing }
        try lock.write(to: marker, options: .atomic)
    }

    static func start(
        serverScript: String = "server.js",
        recoveryWindowMs: Int? = nil,
        maxHttpBufferSize: Int? = nil,
        extraEnvironment: [String: String] = [:],
        startupTimeout: TimeInterval = 15
    ) throws -> TestServerProcess {
        try ensureNodeModules()
        let process = Process()
        process.currentDirectoryURL = fixturesDir()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", serverScript]
        var environment = ProcessInfo.processInfo.environment
        if let value = recoveryWindowMs { environment["RECOVERY_WINDOW_MS"] = String(value) }
        if let value = maxHttpBufferSize { environment["MAX_HTTP_BUFFER_SIZE"] = String(value) }
        environment.merge(extraEnvironment) { _, value in value }
        process.environment = environment
        let output = FixtureProcessOutput()
        output.attach(to: process)
        do {
            try process.run()
        } catch {
            output.stopReading()
            throw error
        }
        if let ready = output.waitForReady(timeout: startupTimeout) {
            return TestServerProcess(port: ready.port, secret: ready.secret, process: process, output: output)
        }
        terminateBoundedly(process)
        let diagnostic = output.diagnostic
        output.stopReading()
        throw Error.serverDidNotStart(diagnostic)
    }

    func stop() {
        Self.terminateBoundedly(process)
        output.stopReading()
    }

    deinit { stop() }

    /// Neither a silent child nor one ignoring SIGTERM can strand XCTest.
    private static func terminateBoundedly(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        waitForExit(process, seconds: 1)
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            waitForExit(process, seconds: 1)
        }
    }

    private static func waitForExit(_ process: Process, seconds: Double) {
        let deadline = DispatchTime.now() + seconds
        while process.isRunning && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Send an authenticated admin request. Returns (status, body).
    func admin(_ path: String, method: String = "POST", body: Data? = nil) throws -> (Int, Data) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(secret, forHTTPHeaderField: "X-Admin-Secret")
        req.httpBody = body
        req.timeoutInterval = 5

        let response = FixtureAdminResponse()
        let task = URLSession.shared.dataTask(with: req) { data, http, error in
            response.complete(data: data, response: http, error: error)
        }
        task.resume()
        defer { task.cancel() }
        return try response.wait(timeout: 5)
    }
}


/// Readability handlers drain both pipes throughout the child's lifetime.
/// The startup thread waits on a condition, never on FileHandle.availableData.
/// All mutable state is guarded by `condition`; the readability and termination
/// handlers run on Foundation's threads, which is why the class is Sendable.
private final class FixtureProcessOutput: @unchecked Sendable {
    private let condition = NSCondition()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var out = Data()
    private var err = Data()
    private var exited = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var ready: (port: Int, secret: String)?
    private let limit = 64 * 1024

    func attach(to process: Process) {
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.append(data, isError: false)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.append(data, isError: true)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.condition.lock()
            self.exited = true
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    private func append(_ data: Data, isError: Bool) {
        condition.lock()
        defer { condition.unlock() }
        if data.isEmpty {
            if isError { stderrEOF = true } else { stdoutEOF = true }
            condition.broadcast()
            return
        }
        if isError {
            err.append(data)
            if err.count > limit { err = Data(err.suffix(limit)) }
        } else {
            out.append(data)
            if out.count > limit { out = Data(out.suffix(limit)) }
            let text = String(decoding: out, as: UTF8.self)
            if ready == nil,
               let range = text.range(of: #"(?m)^READY port=([0-9]+) secret=([0-9a-f]+)\r?\n"#,
                                      options: .regularExpression) {
                let fields = text[range].split(separator: " ")
                if fields.count == 3, let port = Int(fields[1].dropFirst(5)), (1...65535).contains(port) {
                    ready = (port, String(fields[2].dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        condition.broadcast()
    }

    func waitForReady(timeout: TimeInterval) -> (port: Int, secret: String)? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while ready == nil && !(exited && stdoutEOF && stderrEOF) {
            if !condition.wait(until: deadline) { break }
        }
        return ready
    }

    var diagnostic: String {
        condition.lock()
        defer { condition.unlock() }
        return "stdout: " + String(decoding: out, as: UTF8.self) + "\nstderr: " + String(decoding: err, as: UTF8.self)
    }

    func stopReading() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }
}

/// URLSession may finish after the waiting thread times out. All result access
/// is locked, so a late completion cannot race a returned stack variable.
private final class FixtureAdminResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<(Int, Data), Swift.Error>?

    func complete(data: Data?, response: URLResponse?, error: Swift.Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        if let error = error {
            result = .failure(error)
        } else if let response = response as? HTTPURLResponse {
            result = .success((response.statusCode, data ?? Data()))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> (Int, Data) {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw URLError(.timedOut)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let result = result else { throw URLError(.badServerResponse) }
        return try result.get()
    }
}
