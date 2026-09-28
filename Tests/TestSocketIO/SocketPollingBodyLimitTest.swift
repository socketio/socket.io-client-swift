//
//  SocketPollingBodyLimitTest.swift
//  Socket.IO-Client-Swift
//
//  Round 3 of the JavaScript-parity port: the incoming-HTTP-body half of review
//  gate R1. The polling transport used to receive a complete response through a
//  `URLSession` completion handler, so the whole body was retained before the
//  parser could apply `maximumTextPacketBytes` to anything.
//
//  With `.bufferLimits(maximumPollingResponseBytes:)` the body is bounded while
//  it is received: an announced `Content-Length` above the cap is refused before
//  a byte of body arrives, and a body delivered in chunks without a length is
//  cancelled as soon as the accumulated bytes cross it. Overflow closes the
//  connection with `transport error`.
//
//  Session-scoped `URLProtocol` fixture, like `SocketPollingCloseTest`: no DNS,
//  no network, no global registration, a unique host per test.
//

import Foundation
import XCTest
@testable import SocketIO

private final class BodyLimitFixture {
    enum PollBody {
        /// One `didLoad` with an announced `Content-Length` header.
        case announced(String)
        /// Several `didLoad` calls and no length header.
        case chunked([String])
    }

    let host = UUID().uuidString.lowercased() + ".bodylimit.test"
    private let lock = NSLock()
    private var handshakes = 0
    private var polls = 0
    private var body: PollBody = .announced("")

    func servePolls(_ body: PollBody) {
        lock.lock(); defer { lock.unlock() }
        self.body = body
    }

    var pollCount: Int {
        lock.lock(); defer { lock.unlock() }
        return polls
    }

    func start(_ request: BodyLimitProtocol) {
        let url = request.request.url!
        let sid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "sid" })?.value

        guard sid != nil else {
            lock.lock()
            handshakes += 1
            let id = "session-\(handshakes)"
            lock.unlock()
            request.reply(announced:
                "0{\"sid\":\"\(id)\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000}")

            return
        }

        guard request.request.httpMethod != "POST" else {
            request.reply(announced: "ok")

            return
        }

        lock.lock()
        polls += 1
        let body = self.body
        lock.unlock()

        switch body {
        case let .announced(payload):
            request.reply(announced: payload)
        case let .chunked(chunks):
            request.reply(chunked: chunks)
        }
    }
}

private final class BodyLimitProtocol: URLProtocol {
    private static let registryLock = NSLock()
    // Guarded by `registryLock`; Swift 6 cannot see the lock discipline.
    nonisolated(unsafe) private static var fixtures = [String: BodyLimitFixture]()
    private let stateLock = NSLock()
    private var ended = false

    static func register(_ fixture: BodyLimitFixture) {
        registryLock.lock(); defer { registryLock.unlock() }
        fixtures[fixture.host] = fixture
    }

    static func unregister(_ fixture: BodyLimitFixture) {
        registryLock.lock(); defer { registryLock.unlock() }
        fixtures.removeValue(forKey: fixture.host)
    }

    private var fixture: BodyLimitFixture? {
        Self.registryLock.lock(); defer { Self.registryLock.unlock() }
        return Self.fixtures[request.url?.host ?? ""]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".bodylimit.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        fixture.start(self)
    }
    override func stopLoading() {
        stateLock.lock()
        ended = true
        stateLock.unlock()
    }

    private func response(contentLength: Int?) -> HTTPURLResponse {
        var headers = ["Content-Type": "text/plain; charset=UTF-8"]
        if let contentLength = contentLength { headers["Content-Length"] = String(contentLength) }

        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                               headerFields: headers)!
    }

    /// A body whose size the server announces up front.
    func reply(announced body: String) {
        stateLock.lock()
        let wasEnded = ended
        ended = true
        stateLock.unlock()
        guard !wasEnded else { return }

        let data = Data(body.utf8)
        client?.urlProtocol(self, didReceive: response(contentLength: data.count),
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// A body delivered in pieces with no announced length, i.e. what a chunked
    /// transfer looks like to the URL loading system.
    func reply(chunked chunks: [String]) {
        stateLock.lock()
        let wasEnded = ended
        ended = true
        stateLock.unlock()
        guard !wasEnded else { return }

        client?.urlProtocol(self, didReceive: response(contentLength: nil), cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            stateLock.lock()
            let cancelled = ended
            stateLock.unlock()
            guard !cancelled || chunk == chunks.first else { break }

            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Engine callbacks arrive on the engine queue; the test waits on the main one.
private final class BodyLimitClient: NSObject, SocketEngineClient {
    private let lock = NSLock()
    private var _closes = [String]()
    private var _errors = [String]()
    private var _messages = [String]()
    var onOpen: (() -> Void)?
    var onClose: ((String) -> Void)?

    var closes: [String] { lock.lock(); defer { lock.unlock() }; return _closes }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return _errors }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return _messages }

    func engineDidOpen(reason: String) { onOpen?() }
    func engineDidClose(reason: String) {
        lock.lock(); _closes.append(reason); lock.unlock()
        onClose?(reason)
    }
    func engineDidError(reason: String) { lock.lock(); _errors.append(reason); lock.unlock() }
    func engineDidReceivePing() {}
    func engineDidReceivePong() {}
    func engineDidSendPong() {}
    func parseEngineMessage(_ msg: String) { lock.lock(); _messages.append(msg); lock.unlock() }
    func parseEngineBinaryData(_ data: Data) {}
    func engineDidWebsocketUpgrade(headers: [String: String]) {}
}

final class SocketPollingBodyLimitTest: XCTestCase {
    private var fixture: BodyLimitFixture!
    private var client: BodyLimitClient!
    private var engine: SocketEngine!

    override func setUp() {
        super.setUp()
        fixture = BodyLimitFixture()
        BodyLimitProtocol.register(fixture)
        client = BodyLimitClient()
    }

    override func tearDown() {
        if let engine = engine {
            engine.engineQueue.sync {
                if !engine.closed { engine.didError(reason: "fixture teardown") }
            }
        }
        engine = nil
        client = nil
        BodyLimitProtocol.unregister(fixture)
        fixture = nil
        super.tearDown()
    }

    private func makeEngine(_ limits: SocketBufferLimits) {
        engine = SocketEngine(client: client, url: URL(string: "http://\(fixture.host)")!,
                              config: [.forcePolling(true), .log(false), .bufferLimits(limits)])
        engine.pollingSessionConfigurationFactory = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BodyLimitProtocol.self]
            configuration.httpCookieStorage = nil
            return configuration
        }
    }

    /// Opens the transport and waits for the Engine.IO handshake.
    private func open() {
        let opened = expectation(description: "handshake")
        opened.assertForOverFulfill = false
        client.onOpen = { opened.fulfill() }
        engine.connect()
        wait(for: [opened], timeout: 10)
    }

    private func waitForClose() -> String? {
        var reason: String?
        let closed = expectation(description: "engine closed")
        closed.assertForOverFulfill = false
        client.onClose = { value in
            reason = value
            closed.fulfill()
        }
        wait(for: [closed], timeout: 10)

        return reason
    }

    // MARK: Acceptance — oversized HTTP body

    /// An announced `Content-Length` above the cap is refused before the body
    /// is transferred, so the client never retains it.
    func testAnnouncedOversizedPollingBodyIsRefusedAndClosesTheTransport() {
        makeEngine(SocketBufferLimits(maximumPollingResponseBytes: 256))
        fixture.servePolls(.announced("4" + String(repeating: "a", count: 4096)))

        open()
        let reason = waitForClose()

        XCTAssertEqual(reason, "transport error")
        XCTAssertTrue(client.errors.contains(where: { $0.contains("pollingResponse limit exceeded") }),
                      "the close reports the limit, not a generic URL error: \(client.errors)")
        XCTAssertFalse(client.messages.contains(where: { $0.count > 256 }),
                       "no oversized body reached the parser")
    }

    /// A chunked body announces no length, so the cap is applied to the bytes
    /// as they accumulate and the task is cancelled mid-transfer.
    func testChunkedOversizedPollingBodyIsCancelledWhileItIsReceived() {
        makeEngine(SocketBufferLimits(maximumPollingResponseBytes: 256))
        fixture.servePolls(.chunked(Array(repeating: String(repeating: "b", count: 200), count: 8)))

        open()
        let reason = waitForClose()

        XCTAssertEqual(reason, "transport error")
        XCTAssertTrue(client.errors.contains(where: { $0.contains("pollingResponse limit exceeded") }),
                      "\(client.errors)")
        XCTAssertFalse(client.messages.contains(where: { $0.count > 256 }))
    }

    /// Positive control for the bounded route: a response inside the cap is
    /// delivered exactly as the unbounded path delivers it.
    func testBoundedPollingDeliversAResponseWithinTheLimit() {
        makeEngine(SocketBufferLimits(maximumPollingResponseBytes: 4096))
        fixture.servePolls(.announced("4hello"))

        open()

        let delivered = expectation(description: "message delivered")
        delivered.assertForOverFulfill = false
        // Poll the engine-queue-owned client state from the main run loop:
        // XCTest's wait services it, and no @Sendable closure has to touch `self`.
        let deadline = Date().addingTimeInterval(10)
        while !client.messages.contains("hello") && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if client.messages.contains("hello") { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)

        XCTAssertTrue(client.closes.isEmpty, "a response inside the cap does not close anything")
    }

    /// Without a configured cap the transport keeps the measured
    /// completion-handler request form, and an oversized body is accepted —
    /// which is the JavaScript behaviour this client defaults to.
    func testUnlimitedPollingBodyKeepsTheJavaScriptBehaviour() {
        makeEngine(.unlimited)
        let payload = String(repeating: "c", count: 4096)
        fixture.servePolls(.announced("4" + payload))

        open()

        let delivered = expectation(description: "oversized message delivered")
        delivered.assertForOverFulfill = false
        // Poll the engine-queue-owned client state from the main run loop:
        // XCTest's wait services it, and no @Sendable closure has to touch `self`.
        let deadline = Date().addingTimeInterval(10)
        while !client.messages.contains(payload) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if client.messages.contains(payload) { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
    }
}
