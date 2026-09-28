import Foundation
import XCTest
@testable import SocketIO

/// A session-scoped URLProtocol fixture: no DNS, network, shared cookie store,
/// or global URLProtocol registration. Each test owns its own unique host.
private final class PollingCloseFixture {
    struct Request {
        let method: String
        let body: String
        let sid: String?
        let authorization: String?
        let timeout: TimeInterval
    }
    let host = UUID().uuidString.lowercased() + ".polling.test"
    private let lock = NSLock()
    private var recorded = [Request]()
    private var heldPosts = [PollingCloseProtocol]()
    private var handshakes = 0
    private var postObserver: ((Request) -> Void)?
    private var stopObserver: ((String) -> Void)?
    private var pollObserver: (() -> Void)?
    private var holdPosts = true

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var posts: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.method == "POST" }
    }

    var heldPostCount: Int {
        lock.lock(); defer { lock.unlock() }
        return heldPosts.count
    }

    func observePolls(_ observer: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        pollObserver = observer
    }

    /// Installs observers before I/O, without racing the protocol's callback queue.
    func observePosts(_ observer: @escaping (Request) -> Void) {
        lock.lock(); defer { lock.unlock() }
        postObserver = observer
    }

    func observeStops(_ observer: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        stopObserver = observer
    }

    /// Answers application POSTs as they arrive. Only tests about an in-flight
    /// POST need to hold them; a chained flush would otherwise deadlock itself.
    func replyToPostsImmediately() {
        lock.lock(); defer { lock.unlock() }
        holdPosts = false
    }

    /// Replies to a held application POST; its URLSession completion drains the barrier.
    func releasePost(statusCode: Int = 200, body: String = "ok") {
        lock.lock()
        let pending = heldPosts.isEmpty ? nil : heldPosts.removeFirst()
        lock.unlock()
        pending?.reply(body, statusCode: statusCode)
    }

    /// Fails only the selected in-flight request; subsequent sessions stay usable.
    func failPost(_ error: Error) {
        lock.lock()
        let pending = heldPosts.isEmpty ? nil : heldPosts.removeFirst()
        lock.unlock()
        pending?.fail(error)
    }

    /// Captures a request and completes handshakes/close packets; other I/O stays held.
    func start(_ request: PollingCloseProtocol) {
        let url = request.request.url!
        let sid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "sid" })?.value
        let method = request.request.httpMethod ?? "GET"
        let body = request.body()
        let observed = Request(method: method, body: body, sid: sid,
                               authorization: request.request.value(forHTTPHeaderField: "Authorization"),
                               timeout: request.request.timeoutInterval)
        lock.lock()
        recorded.append(observed)
        if method == "GET" && sid == nil { handshakes += 1 }
        let handshakeID = "session-\(handshakes)"
        let held = method == "POST" && body != "1" && holdPosts
        if held { heldPosts.append(request) }
        let observer = postObserver
        let poll = pollObserver
        lock.unlock()
        if method == "GET" && sid == nil {
            request.reply("0{\"sid\":\"\(handshakeID)\",\"upgrades\":[],\"maxPayload\":32,\"pingInterval\":25000,\"pingTimeout\":20000}")
        } else if method == "POST" {
            observer?(observed)
            if !held { request.reply("ok") }
        } else if method == "GET" {
            poll?()
        }
    }

    /// Reports cancellation so timeout tests await an actual cancelled task.
    func stop(_ request: PollingCloseProtocol) {
        lock.lock()
        let observer = stopObserver
        heldPosts.removeAll { $0 === request }
        lock.unlock()
        observer?(request.request.httpMethod ?? "GET")
    }
}

private final class PollingCloseProtocol: URLProtocol {
    private static let registryLock = NSLock()
    // Every access is protected by registryLock, including URLProtocol callbacks.
    nonisolated(unsafe) private static var fixtures = [String: PollingCloseFixture]()
    private let stateLock = NSLock()
    private var ended = false

    static func register(_ fixture: PollingCloseFixture) {
        registryLock.lock(); defer { registryLock.unlock() }
        fixtures[fixture.host] = fixture
    }

    static func unregister(_ fixture: PollingCloseFixture) {
        registryLock.lock(); defer { registryLock.unlock() }
        fixtures.removeValue(forKey: fixture.host)
    }

    private var fixture: PollingCloseFixture? {
        Self.registryLock.lock(); defer { Self.registryLock.unlock() }
        return Self.fixtures[request.url?.host ?? ""]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".polling.test") == true
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
        let wasEnded = ended
        ended = true
        stateLock.unlock()
        if !wasEnded { fixture?.stop(self) }
    }

    /// URLSession may move an upload body into a stream before invoking URLProtocol.
    func body() -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }

    func fail(_ error: Error) {
        stateLock.lock()
        let wasEnded = ended
        ended = true
        stateLock.unlock()
        guard !wasEnded else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    /// Completes a held request at most once, ignoring release after cancellation.
    func reply(_ body: String, statusCode: Int = 200) {
        stateLock.lock()
        let wasEnded = ended
        ended = true
        stateLock.unlock()
        guard !wasEnded else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain; charset=UTF-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Notifications are written/read on the engine queue; XCTest expectations may
/// be fulfilled from that queue while the test waits on the main queue.
private final class PollingCloseClient: NSObject, SocketEngineClient {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var details = [SocketTransportError]()
    var closeDetails = [SocketTransportError]()
    var closes = [String]()
    var errors = [String]()
    func engineDidOpen(reason: String) { onOpen?() }
    func engineDidClose(reason: String) { closes.append(reason); onClose?() }
    func engineDidClose(reason: String, error: SocketTransportError) {
        closeDetails.append(error)
        engineDidClose(reason: reason)
    }
    func engineDidError(reason: String, error: SocketTransportError) {
        details.append(error)
        engineDidError(reason: reason)
    }
    func engineDidError(reason: String) { errors.append(reason) }
    func engineDidReceivePing() {}
    func engineDidReceivePong() {}
    func engineDidSendPong() {}
    func parseEngineMessage(_ msg: String) {}
    func parseEngineBinaryData(_ data: Data) {}
    func engineDidWebsocketUpgrade(headers: [String: String]) {}
}

final class SocketPollingCloseTest: XCTestCase {
    private var fixture: PollingCloseFixture!
    private var client: PollingCloseClient!
    private var engine: SocketEngine!

    /// Creates an actual URLSession whose requests are controlled by this test.
    override func setUp() {
        super.setUp()
        fixture = PollingCloseFixture()
        PollingCloseProtocol.register(fixture)
        client = PollingCloseClient()
        engine = SocketEngine(client: client, url: URL(string: "http://\(fixture.host)")!,
                              config: [.forcePolling(true), .extraHeaders(["Authorization": "fixture-only"])])
        engine.pollingSessionConfigurationFactory = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PollingCloseProtocol.self]
            configuration.httpCookieStorage = nil
            return configuration
        }
    }

    /// Stops I/O without opening a graceful close after the fixture has been removed.
    override func tearDown() {
        engine.engineQueue.sync {
            if !engine.closed { engine.didError(reason: "fixture teardown") }
        }
        engine = nil
        client = nil
        PollingCloseProtocol.unregister(fixture)
        fixture = nil
        super.tearDown()
    }

    /// Waits for the Engine.IO handshake, not merely a URLSession start callback.
    private func connect() {
        let opened = expectation(description: "engine opened")
        engine.engineQueue.sync { client.onOpen = { opened.fulfill() } }
        engine.connect()
        wait(for: [opened], timeout: 5)
        engine.engineQueue.sync { client.onOpen = nil }
    }

    func testNetworkFailureDuringPostSettlesWritesOnceAndAllowsFreshSession() throws {
        try checkFailedPost(networkError: true)
    }

    func testHTTPFailureDuringPostPreservesResponseAndAllowsFreshSession() throws {
        try checkFailedPost(networkError: false)
    }

    private func checkFailedPost(networkError: Bool) throws {
        let polling = expectation(description: "old long poll started")
        fixture.observePolls { polling.fulfill() }
        connect()
        wait(for: [polling], timeout: 5)
        fixture.observePolls { }
        let started = expectation(description: "first POST in flight")
        let closed = expectation(description: "transport failed once")
        let stopped = expectation(description: "old long poll cancelled")
        fixture.observePosts { post in
            XCTAssertEqual(post.body, "4first")
            started.fulfill()
        }
        fixture.observeStops { method in if method == "GET" { stopped.fulfill() } }
        var completions: [String] = []
        engine.engineQueue.sync { client.onClose = { closed.fulfill() } }
        engine.write("first", withType: .message, withData: []) { completions.append("first") }
        wait(for: [started], timeout: 5)
        engine.write("queued", withType: .message, withData: []) { completions.append("queued") }
        engine.engineQueue.sync {
            XCTAssertTrue(engine.waitingForPost)
            XCTAssertEqual(engine.postWait.map { $0.msg }, ["4queued"])
            XCTAssertEqual(completions, ["first"])
        }
        if networkError { fixture.failPost(URLError(.networkConnectionLost)) }
        else { fixture.releasePost(statusCode: 503, body: "temporarily unavailable") }
        wait(for: [closed, stopped], timeout: 5)
        try engine.engineQueue.sync {
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertEqual(client.closes, ["transport error"])
            XCTAssertEqual(client.details.count, 1)
            XCTAssertEqual(client.closeDetails.count, 1)
            let detail = try XCTUnwrap(client.details.first)
            XCTAssertTrue(client.closeDetails.first === detail)
            XCTAssertEqual(detail.transport, "polling")
            XCTAssertEqual(detail.operation, "write")
            if networkError {
                let underlying = try XCTUnwrap(detail.underlyingError as NSError?)
                XCTAssertEqual(underlying.domain, NSURLErrorDomain)
                XCTAssertEqual(underlying.code, URLError.networkConnectionLost.rawValue)
                XCTAssertNil(detail.httpStatusCode)
            } else {
                XCTAssertEqual(detail.httpStatusCode, 503)
                XCTAssertEqual(detail.responseText, "temporarily unavailable")
                XCTAssertNil(detail.underlyingError)
            }
            XCTAssertTrue(engine.closed)
            XCTAssertFalse(engine.waitingForPost)
            XCTAssertFalse(engine.waitingForPoll)
            XCTAssertTrue(engine.postWait.isEmpty)
            XCTAssertNil(engine.session)
            XCTAssertEqual(completions, ["first", "queued"])
            client.onClose = nil
        }
        XCTAssertEqual(fixture.posts.map { $0.body }, ["4first"])
        fixture.observeStops { _ in }
        connect()
        let freshPost = expectation(description: "fresh session sends")
        fixture.observePosts { post in
            XCTAssertEqual(post.sid, "session-2")
            XCTAssertEqual(post.body, "4fresh")
            freshPost.fulfill()
        }
        fixture.replyToPostsImmediately()
        engine.write("fresh", withType: .message, withData: []) { completions.append("fresh") }
        wait(for: [freshPost], timeout: 5)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.connected)
            XCTAssertEqual(completions, ["first", "queued", "fresh"])
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertEqual(client.closes, ["transport error"])
        }
        XCTAssertEqual(fixture.posts.map { $0.body }, ["4first", "4fresh"])
    }

    /// The abandoned queue is batched by maxPayload exactly like a live flush,
    /// and the close packet is always a request of its own so no slice can drop
    /// it. Previously the queue was discarded and only "1" was sent.
    func testDisconnectFlushesQueueInMaxPayloadBatchesBeforeClosing() {
        connect()
        fixture.replyToPostsImmediately()
        let first = String(repeating: "x", count: 32)
        let second = String(repeating: "y", count: 32)
        let closedOnWire = expectation(description: "close-only POST")
        fixture.observePosts { post in
            XCTAssertEqual(post.sid, "session-1")
            XCTAssertEqual(post.authorization, "fixture-only")
            if post.body == "1" { closedOnWire.fulfill() }
        }
        var completions = 0
        engine.engineQueue.sync {
            XCTAssertEqual(engine.maxPayload, 32)
            engine.postWait = [(first, { completions += 1 }), (second, { completions += 1 })]
        }
        engine.disconnect(reason: "io client disconnect")
        wait(for: [closedOnWire], timeout: 5)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.closed)
            XCTAssertNil(engine.session)
            XCTAssertTrue(engine.postWait.isEmpty)
            XCTAssertEqual(completions, 2)
            XCTAssertEqual(client.closes, ["io client disconnect"])
        }
        XCTAssertEqual(fixture.posts.map { $0.body }, [first, second, "1"])
    }

    /// An in-flight POST settles first, then the still-queued packets go out on
    /// the retiring session, then the close. engine.io-client/test/connection.js
    /// — "should send all buffered packets if closing is deferred". This used to
    /// assert that unsent packets are dropped, which silently discarded the
    /// namespace DISCONNECT that socket.io-client buffers in the same queue.
    func testCloseWaitsForInFlightPostAndCompletesPendingWritesOnce() {
        connect()
        let started = expectation(description: "application POST started")
        let flushed = expectation(description: "queued packet posted on the retiring session")
        let closedOnWire = expectation(description: "close follows the queued packets")
        let premature = expectation(description: "no overlapping close POST")
        premature.isInverted = true
        fixture.observePosts { [weak fixture = fixture] post in
            switch post.body {
            case "4first":
                started.fulfill()
            case "4unsent":
                XCTAssertEqual(post.sid, "session-1")
                flushed.fulfill()
            default:
                XCTAssertEqual(post.body, "1")
                if fixture?.heldPostCount != 0 { premature.fulfill() }
                closedOnWire.fulfill()
            }
        }
        var completions = 0
        engine.write("first", withType: .message, withData: []) { completions += 1 }
        wait(for: [started], timeout: 5)
        engine.engineQueue.sync { engine.postWait.append(("4unsent", { completions += 1 })) }
        engine.disconnect(reason: "io client disconnect")
        engine.disconnect(reason: "duplicate")
        engine.engineQueue.sync { XCTAssertEqual(client.closes.count, 1) }
        // A negative observation is followed by a positive close after releasing
        // the actual requests, so a non-running shutdown cannot make this pass.
        wait(for: [premature], timeout: 0.05)
        fixture.releasePost()
        wait(for: [flushed], timeout: 5)
        fixture.releasePost()
        wait(for: [closedOnWire], timeout: 5)
        engine.engineQueue.sync { XCTAssertEqual(completions, 2); XCTAssertTrue(client.errors.isEmpty) }
        XCTAssertEqual(fixture.posts.map { $0.body }, ["4first", "4unsent", "1"])
    }

    /// engine.io-client/test/connection.js — "should defer close when upgrading"
    /// and "should not send packets if closing is deferred". JS `close()` calls
    /// `waitForUpgrade()` while upgrading, because nothing can be written through
    /// a paused transport. This test previously asserted the opposite — that the
    /// close POST is sent straight through the paused transport.
    func testCloseIsDeferredWhileUpgradeIsPaused() {
        connect()
        let premature = expectation(description: "no POST while the upgrade is unfinished")
        premature.isInverted = true
        fixture.observePosts { _ in premature.fulfill() }
        engine.engineQueue.sync { engine.setFastUpgrade(true) }
        engine.disconnect(reason: "io client disconnect")
        // A send() after close() must not reach the wire either: JS `sendPacket`
        // returns early once `readyState` is "closing".
        engine.write("late", withType: .message, withData: [])
        wait(for: [premature], timeout: 0.3)
        engine.engineQueue.sync {
            XCTAssertFalse(engine.closed)
            XCTAssertTrue(engine.connected)
            XCTAssertTrue(engine.postWait.isEmpty)
            XCTAssertTrue(client.closes.isEmpty)
        }
        XCTAssertTrue(fixture.posts.isEmpty)
    }

    /// engine.io-client/test/connection.js — "should not send packets if socket
    /// closes": a `send()` issued after `close()` produces no packet at all.
    func testSendAfterCloseProducesNoPacket() {
        connect()
        let closedOnWire = expectation(description: "close-only POST")
        fixture.observePosts { post in
            XCTAssertEqual(post.body, "1")
            closedOnWire.fulfill()
        }
        var completed = false
        engine.disconnect(reason: "io client disconnect")
        engine.write("hi", withType: .message, withData: []) { completed = true }
        wait(for: [closedOnWire], timeout: 5)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.postWait.isEmpty)
            XCTAssertTrue(completed, "a refused write still completes locally")
        }
        XCTAssertEqual(fixture.posts.map { $0.body }, ["1"])
    }

    /// A stuck POST is cancelled at the teardown deadline without a late close POST.
    func testStalledPostIsCancelledWithoutSendingAfterTheDeadline() {
        connect()
        engine.engineQueue.sync { engine.pollingRetirementDeadline = 0.05 }
        let started = expectation(description: "stalled POST started")
        let cancelled = expectation(description: "stalled POST cancelled")
        fixture.observePosts { post in
            if post.body == "4stalled" { started.fulfill() }
            else { XCTFail("A close POST was sent after the teardown deadline") }
        }
        fixture.observeStops { method in if method == "POST" { cancelled.fulfill() } }
        engine.write("stalled", withType: .message, withData: [])
        wait(for: [started], timeout: 5)
        let oldGroup = engine.engineQueue.sync { engine.pollingPostGroup }
        engine.disconnect(reason: "io client disconnect")
        wait(for: [cancelled], timeout: 5)
        let drained = expectation(description: "cancelled POST completion drained")
        oldGroup.socketNotify(queue: .main) { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        engine.engineQueue.sync { XCTAssertTrue(engine.closed); XCTAssertEqual(client.closes.count, 1) }
        XCTAssertEqual(fixture.posts.map { $0.body }, ["4stalled"])
    }

    /// Retired POST/close callbacks must not mutate or close a replacement session.
    func testRetiredCloseUsesOnlyTheOldSessionAfterReconnect() {
        connect()
        engine.engineQueue.sync { engine.pollingRetirementDeadline = 30 }
        let started = expectation(description: "old POST started")
        let oldClosedOnWire = expectation(description: "old SID closed")
        fixture.observePosts { post in
            if post.body == "4old" { started.fulfill() }
            if post.body == "1" {
                XCTAssertEqual(post.sid, "session-1")
                oldClosedOnWire.fulfill()
            }
        }
        engine.write("old", withType: .message, withData: [])
        wait(for: [started], timeout: 5)
        engine.disconnect(reason: "io client disconnect")
        connect()
        engine.engineQueue.sync { XCTAssertEqual(engine.sid, "session-2") }
        fixture.releasePost()
        wait(for: [oldClosedOnWire], timeout: 5)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.connected)
            XCTAssertFalse(engine.closed)
            XCTAssertEqual(engine.sid, "session-2")
            XCTAssertEqual(client.closes.count, 1)
            XCTAssertTrue(client.errors.isEmpty)
        }
    }

    /// Regression for PR18 comment 5733052285: the old request remains alive
    /// while a completely independent replacement handshake finishes.
    func testReconnectCannotCancelDetachedRetiringPostBeforeBarrierRelease() {
        connect()
        engine.engineQueue.sync { engine.pollingRetirementDeadline = 30 }
        let started = expectation(description: "retiring POST held")
        let closedOnWire = expectation(description: "retiring close delivered")
        let prematurelyCancelled = expectation(description: "old POST not cancelled by reset")
        prematurelyCancelled.isInverted = true
        fixture.observeStops { if $0 == "POST" { prematurelyCancelled.fulfill() } }
        fixture.observePosts { post in
            if post.body == "4held" { started.fulfill() }
            else { XCTAssertEqual(post.sid, "session-1"); XCTAssertEqual(post.body, "1"); closedOnWire.fulfill() }
        }
        engine.write("held", withType: .message, withData: [])
        wait(for: [started], timeout: 3)
        let oldSession = engine.engineQueue.sync { engine.session }
        let oldBarrier = engine.engineQueue.sync { engine.pollingPostGroup }
        engine.disconnect(reason: "io client disconnect")
        engine.engineQueue.sync {
            XCTAssertNil(engine.session)
            XCTAssertFalse(engine.pollingPostGroup === oldBarrier)
        }
        connect()
        engine.engineQueue.sync { XCTAssertFalse(engine.session === oldSession); XCTAssertEqual(engine.sid, "session-2") }
        wait(for: [prematurelyCancelled], timeout: 0.1)
        XCTAssertEqual(fixture.heldPostCount, 1)
        XCTAssertEqual(fixture.posts.count, 1)
        fixture.observeStops { _ in }
        fixture.releasePost()
        wait(for: [closedOnWire], timeout: 3)
        engine.engineQueue.sync { XCTAssertTrue(engine.connected); XCTAssertTrue(client.errors.isEmpty) }
    }

    /// A local write completion can enqueue another message synchronously. It
    /// must neither start a concurrent POST nor reverse their order.
    func testReentrantWriteCompletionCannotStartOverlappingPost() {
        connect()
        let first = expectation(description: "first POST started")
        let second = expectation(description: "second POST started after first")
        fixture.observePosts { post in
            if post.body == "4first" { first.fulfill() }
            else if post.body == "4second" { second.fulfill() }
        }
        engine.write("first", withType: .message, withData: []) { [weak engine = engine] in
            engine?.sendPollMessage("second", withType: .message, withData: [], completion: nil)
        }
        wait(for: [first], timeout: 3)
        engine.engineQueue.sync { XCTAssertTrue(engine.waitingForPost); XCTAssertEqual(engine.postWait.count, 1) }
        XCTAssertEqual(fixture.posts.map { $0.body }, ["4first"])
        fixture.releasePost()
        wait(for: [second], timeout: 3)
        XCTAssertEqual(fixture.posts.map { $0.body }, ["4first", "4second"])
        fixture.releasePost()
    }

    /// `stopPolling()` retires the session instead of leaving an invalidated one
    /// in the active slot: a later `doPoll()` would hand it to `dataTask`, which
    /// raises an ObjC exception on Darwin.
    func testStopPollingInvalidatesAndDetachesTheSession() {
        connect()
        let barrier = engine.engineQueue.sync { engine.pollingPostGroup }
        engine.engineQueue.sync {
            XCTAssertNotNil(engine.session)
            XCTAssertFalse(engine.invalidated)
            engine.stopPolling()
            XCTAssertTrue(engine.invalidated)
            XCTAssertNil(engine.session)
            XCTAssertFalse(engine.waitingForPoll)
            XCTAssertFalse(engine.waitingForPost)
            XCTAssertFalse(engine.pollingPostGroup === barrier)
            // The poll now refuses to start instead of touching a dead session.
            engine.doPoll()
            XCTAssertNil(engine.session)
        }
        XCTAssertTrue(fixture.posts.isEmpty)
    }


    /// Batch callbacks may clear/repopulate the queue without removing new packets.
    func testPostBatchDetachesBeforeReentrantCompletion() {
        engine.engineQueue.sync {
            var completions = 0
            engine.postWait = [("4first", {
                completions += 1
                self.engine.postWait.removeAll()
                self.engine.postWait.append(("4replacement", nil))
            }), ("4second", { completions += 1 })]
            let request = engine.createRequestForPostWithPostWait()
            XCTAssertEqual(request.httpBody, Data("4first\u{1e}4second".utf8))
            XCTAssertEqual(engine.postWait.map { $0.msg }, ["4replacement"])
            XCTAssertEqual(completions, 2)
        }
    }
}


extension SocketPollingCloseTest {
    func testCloseRequestUsesEngineIO4WireEncoding() {
        engine.engineQueue.sync {
            let request = engine.createRequestForPost(with: ["1"])
            XCTAssertEqual(request.httpBody, Data("1".utf8))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "1")
        }
    }
}


extension SocketPollingCloseTest {
    func testRequestTimeoutReachesHandshakePollPostAndRetiringClose() {
        engine.setConfigs([.requestTimeout(125)])
        let polling = expectation(description: "poll with configured timeout")
        fixture.observePolls { polling.fulfill() }
        connect()
        wait(for: [polling], timeout: 5)
        let posted = expectation(description: "POST with configured timeout")
        fixture.observePosts { _ in posted.fulfill() }
        engine.send("payload", withData: [])
        wait(for: [posted], timeout: 5)
        fixture.observePosts { _ in }
        let requests = fixture.requests
        XCTAssertTrue(requests.contains { $0.method == "GET" && $0.sid == nil })
        XCTAssertTrue(requests.contains { $0.method == "GET" && $0.sid != nil })
        XCTAssertTrue(requests.contains { $0.method == "POST" })
        XCTAssertTrue(requests.allSatisfy { $0.timeout == 125 })
        engine.engineQueue.sync {
            XCTAssertEqual(engine.session?.configuration.timeoutIntervalForRequest, 125)
            XCTAssertEqual(engine.session?.configuration.timeoutIntervalForResource, 125)
            XCTAssertEqual(engine.createRequestForPost(with: ["1"]).timeoutInterval, 125)
            XCTAssertEqual(engine.createRequestForPost(with: ["1"]).httpMethod, "POST")
        }
    }

    func testOmittedRequestTimeoutPreservesNativeDefaults() {
        connect()
        engine.engineQueue.sync {
            XCTAssertNil(engine.requestTimeout)
            XCTAssertEqual(engine.createRequestForPost(with: ["1"]).timeoutInterval, 60)
            XCTAssertEqual(engine.session?.configuration.timeoutIntervalForRequest, 60)
            XCTAssertEqual(engine.session?.configuration.timeoutIntervalForResource, 7 * 24 * 60 * 60)
        }
    }
}
