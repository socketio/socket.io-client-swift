import Foundation
import XCTest
@testable import SocketIO

private final class NativeEngineClient: NSObject, SocketEngineClient {
    var errors = [String]()
    var closes = [String]()
    var opens = 0
    var upgradeEvents = [String]()
    var upgradeFailures = [SocketTransportError]()
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var headers = [[String: String]]()
    var messages = [String]()
    var binary = [Data]()
    func engineDidError(reason: String) { errors.append(reason) }
    func engineDidClose(reason: String) { closes.append(reason); upgradeEvents.append("close"); onClose?() }
    func engineDidOpen(reason: String) { opens += 1; onOpen?() }
    func engineDidReceivePing() {}
    func engineDidReceivePong() {}
    func engineDidSendPong() {}
    func parseEngineMessage(_ msg: String) { messages.append(msg) }
    func parseEngineBinaryData(_ data: Data) { binary.append(data) }
    func engineDidCompleteUpgrade() { upgradeEvents.append("upgrade") }
    func engineDidFailUpgrade(error: SocketTransportError) {
        upgradeEvents.append("upgradeError"); upgradeFailures.append(error)
    }
    func engineDidWebsocketUpgrade(headers: [String: String]) { self.headers.append(headers) }
}

private final class NativeEngineTransport: EngineWebSocketTransport {
    var onEvent: ((EngineWebSocketEvent) -> Void)?
    var isWritable = true
    var batches = [[EngineWebSocketMessage]]()
    var completions = [(Result<Void, Error>) -> Void]()
    var autoComplete = true
    var aborts = 0
    var connects = 0
    func connect() { connects += 1 }
    func sendBatch(_ messages: [EngineWebSocketMessage], completion: @escaping (Result<Void, Error>) -> Void) {
        batches.append(messages)
        if autoComplete { completion(.success(())) }
        else { completions.append(completion) }
    }
    func close(code: Int, reason: Data?) {}
    func abort() { aborts += 1 }
}

private final class NativePollingTestEngine: SocketEngine {
    var polls = 0
    var pollingWrites = [String]()
    override func doPoll() { polls += 1 }
    override func sendPollMessage(_ message: String, withType type: SocketEnginePacketType,
                                  withData datas: [Data], completion: (() -> ())?) {
        pollingWrites.append(String(type.rawValue) + message)
        completion?()
    }
}

final class SocketNativeEngineTest: XCTestCase {
    private let url = URL(string: "http://localhost:1")!
    private let handshake = "0{\"sid\":\"native\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000}"
    private let upgradeHandshake = "0{\"sid\":\"polling\",\"upgrades\":[\"websocket\"],\"pingInterval\":25000,\"pingTimeout\":20000}"

    private func drain(_ engine: SocketEngine) { engine.engineQueue.sync {}; engine.engineQueue.sync {} }
    private func make(_ options: SocketIOClientConfiguration = [.forceWebsockets(true)])
        -> (SocketEngine, NativeEngineClient, NativeEngineTransport) {
        let client = NativeEngineClient()
        let engine = SocketEngine(client: client, url: url, config: options)
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in transport }
        engine.connect(); drain(engine)
        return (engine, client, transport)
    }
    private func open(_ engine: SocketEngine, _ transport: NativeEngineTransport) {
        transport.onEvent?(.opened(protocol: nil)); drain(engine)
        transport.onEvent?(.message(.text(handshake))); drain(engine)
    }

    func testCurrentPollingSessionInvalidationReportsErrorAndClosesOnce() throws {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [.forcePolling(true)])
        engine.connect(); drain(engine)
        try engine.engineQueue.sync {
            let session = try XCTUnwrap(engine.session)
            let proxy = try XCTUnwrap(session.delegate as? SocketSessionDelegateProxy)
            proxy.urlSession(session, didBecomeInvalidWithError: URLError(.networkConnectionLost))
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertEqual(client.closes, ["transport error"])
            proxy.urlSession(session, didBecomeInvalidWithError: URLError(.networkConnectionLost))
            XCTAssertEqual(client.errors.count, 1)
        }
        drain(engine)
    }

    func testStoppingPollingFromCallerQueueRetiresSession() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [.forcePolling(true)])
        engine.connect(); drain(engine)
        engine.engineQueue.sync { XCTAssertNotNil(engine.session) }
        engine.stopPolling(); drain(engine)
        engine.engineQueue.sync {
            XCTAssertNil(engine.session)
            XCTAssertTrue(engine.invalidated)
            XCTAssertFalse(engine.waitingForPoll)
            XCTAssertFalse(engine.waitingForPost)
        }
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testMalformedOpenPacketsFailOnceWithoutOpening() {
        for packet in ["0not-json", "0{}", "0{\"sid\":\"\"}", "0{\"sid\":42}"] {
            let (engine, client, transport) = make()
            transport.onEvent?(.opened(protocol: nil)); drain(engine)
            transport.onEvent?(.message(.text(packet))); drain(engine)
            engine.engineQueue.sync {
                XCTAssertTrue(engine.closed, packet)
                XCTAssertEqual(client.opens, 0, packet)
                XCTAssertEqual(client.errors.count, 1, packet)
            }
        }
    }

    func testMissingUpgradeListOpensAndBinaryAfterCloseIsIgnored() {
        let (engine, client, transport) = make()
        transport.onEvent?(.opened(protocol: nil)); drain(engine)
        transport.onEvent?(.message(.text("0{\"sid\":\"x\",\"pingInterval\":25000,\"pingTimeout\":20000}")))
        drain(engine)
        engine.engineQueue.sync { XCTAssertEqual(client.opens, 1) }
        engine.disconnect(reason: "test"); drain(engine)
        engine.engineQueue.sync {
            engine.parseEngineData(Data([1, 2]))
            XCTAssertTrue(client.binary.isEmpty)
        }
    }

    func testConnectingConnectedEngineClosesOldConnectionAndStartsFreshTransport() {
        let (engine, client, transport) = make()
        open(engine, transport)
        engine.connect(); drain(engine)
        engine.engineQueue.sync {
            XCTAssertEqual(client.closes, ["transport close"])
            XCTAssertEqual(transport.connects, 2)
            XCTAssertFalse(engine.connected)
            XCTAssertEqual(engine.sid, "")
        }
        open(engine, transport)
        engine.engineQueue.sync { XCTAssertEqual(client.opens, 2) }
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testWebSocketWriteWithoutTransportStillCompletesExactlyOnce() {
        let client = NativeEngineClient()
        let engine = SocketEngine(client: client, url: url, config: [])
        let completed = expectation(description: "unsent completion")
        engine.sendWebSocketMessage("message", withType: .message, withData: []) { completed.fulfill() }
        wait(for: [completed], timeout: 1)
        drain(engine)
        engine.engineQueue.sync { XCTAssertTrue(client.messages.isEmpty) }
    }

    func testApplicationTrafficCannotRefreshTheServerHeartbeatDeadline() {
        let (engine, client, transport) = make()
        var now = DispatchTime.now()
        engine.engineQueue.sync { engine.heartbeatNow = { now } }
        open(engine, transport) // deadline: 25 + 20 seconds
        engine.engineQueue.sync {
            now = now + .seconds(46)
            engine.parseEngineMessage("4[\"still sending data\"]")
            engine.parseEngineData(Data([1]))
            XCTAssertTrue(engine.hasPingExpired)
        }
        drain(engine)
        engine.engineQueue.sync { XCTAssertEqual(client.closes, ["ping timeout"]) }
    }

    func testOnlyPingResetsTheDeadlineAndExpiredChecksCloseOnce() {
        let (engine, client, transport) = make()
        var now = DispatchTime.now()
        engine.engineQueue.sync {
            engine.heartbeatNow = { now }
            XCTAssertFalse(engine.hasPingExpired)
        }
        open(engine, transport)
        engine.engineQueue.sync {
            XCTAssertFalse(engine.hasPingExpired)
            now = now + .seconds(30)
            engine.parseEngineMessage("2")
            now = now + .seconds(30)
            XCTAssertFalse(engine.hasPingExpired) // inside the reset 45-second budget
            now = now + .seconds(16)
            XCTAssertTrue(engine.hasPingExpired)
            XCTAssertTrue(engine.hasPingExpired)
            XCTAssertTrue(engine.hasPingExpired)
            XCTAssertTrue(client.closes.isEmpty, "Timeout closure is deferred")
        }
        drain(engine)
        engine.engineQueue.sync { XCTAssertEqual(client.closes, ["ping timeout"]) }
    }

    /// Only timers this client cannot turn into a Dispatch deadline are a
    /// transport error. `1.5` and `0` used to be listed here and have moved to
    /// the two tests below: JS opens on both, so pinning them as errors was wrong.
    func testMalformedHeartbeatIntervalsCannotTrapOrOpenEngine() {
        for timers in ["\"pingInterval\":9223372036854775807,\"pingTimeout\":1",
                       "\"pingInterval\":-1,\"pingTimeout\":1",
                       "\"pingInterval\":1,\"pingTimeout\":-1",
                       "\"pingInterval\":true,\"pingTimeout\":1",
                       "\"pingInterval\":\"25000\",\"pingTimeout\":1",
                       "\"pingInterval\":2147483647,\"pingTimeout\":2147483647"] {
            let (engine, client, transport) = make()
            transport.onEvent?(.opened(protocol: nil)); drain(engine)
            transport.onEvent?(.message(.text("0{\"sid\":\"x\",\"upgrades\":[]," + timers + "}"))); drain(engine)
            engine.engineQueue.sync { XCTAssertTrue(engine.closed, timers); XCTAssertFalse(engine.connected, timers); XCTAssertEqual(client.opens, 0, timers) }
        }
    }

    /// engine.io-client `onHandshake` stores `pingInterval`/`pingTimeout` as-is:
    /// `pingInterval: 0, pingTimeout: 20000` opens with a 20 s deadline, and
    /// fractional milliseconds are ordinary values.
    func testJavaScriptAcceptedHeartbeatTimersOpenTheEngine() {
        for timers in ["\"pingInterval\":0,\"pingTimeout\":20000",
                       "\"pingInterval\":1.5,\"pingTimeout\":1000",
                       "\"pingInterval\":25000.9,\"pingTimeout\":20000.4"] {
            let (engine, client, transport) = make()
            defer { engine.disconnect(reason: "test"); drain(engine) }
            transport.onEvent?(.opened(protocol: nil)); drain(engine)
            transport.onEvent?(.message(.text("0{\"sid\":\"x\",\"upgrades\":[]," + timers + "}"))); drain(engine)
            engine.engineQueue.sync {
                XCTAssertFalse(engine.closed, timers)
                XCTAssertTrue(engine.connected, timers)
                XCTAssertEqual(client.opens, 1, timers)
                XCTAssertEqual(client.closes, [], timers)
            }
        }
    }

    /// A handshake whose timers are zero or absent sums to a zero-length (JS:
    /// `NaN`) deadline. JS opens the socket and then closes it from the
    /// heartbeat with "ping timeout"; it is never a transport error.
    func testZeroAndMissingHeartbeatTimersOpenThenPingTimeout() {
        for handshake in ["0{\"sid\":\"x\",\"upgrades\":[],\"pingInterval\":0,\"pingTimeout\":0}",
                          "0{\"sid\":\"x\",\"upgrades\":[]}"] {
            let (engine, client, transport) = make()
            transport.onEvent?(.opened(protocol: nil)); drain(engine)
            transport.onEvent?(.message(.text(handshake))); drain(engine)
            engine.engineQueue.sync { XCTAssertEqual(client.opens, 1, handshake) }
            // The zero-length heartbeat deadline is already in the past, so one
            // later engine-queue block observes the close it scheduled.
            let expired = expectation(description: "heartbeat deadline expired")
            engine.engineQueue.socketAsyncAfter(deadline: .now() + .milliseconds(100)) { expired.fulfill() }
            wait(for: [expired], timeout: 5)
            engine.engineQueue.sync {
                XCTAssertTrue(engine.closed, handshake)
                XCTAssertEqual(client.closes, ["ping timeout"], handshake)
                XCTAssertEqual(client.errors, [], handshake)
            }
        }
    }


    func testWebSocketOpenAloneDoesNotOpenEngineIO() {
        let (engine, client, transport) = make()
        defer { engine.disconnect(reason: "test"); drain(engine) }
        transport.onEvent?(.opened(protocol: nil, headers: ["x-native": "yes"]))
        drain(engine)
        XCTAssertFalse(engine.connected)
        XCTAssertFalse(engine.writable)
        XCTAssertEqual(client.opens, 0)
        XCTAssertEqual(client.headers, [["x-native": "yes"]])
        transport.onEvent?(.message(.text(handshake))); drain(engine)
        XCTAssertTrue(engine.connected)
        XCTAssertEqual(client.opens, 1)
    }

    func testWholeBinaryPacketHasOneDelayedCompletion() {
        let (engine, _, transport) = make(); open(engine, transport)
        defer { engine.disconnect(reason: "test"); drain(engine) }
        transport.autoComplete = false
        var finished = 0
        engine.write("packet", withType: .message, withData: [Data([1]), Data([2])]) { finished += 1 }
        drain(engine)
        XCTAssertEqual(transport.batches.last, [.text("4packet"), .binary(Data([1])), .binary(Data([2]))])
        XCTAssertEqual(finished, 0)
        engine.engineQueue.sync { transport.completions.removeFirst()(.success(())) }
        XCTAssertEqual(finished, 1)
    }


    func testEngineIOHeartbeatRemainsText() {
        let (engine, _, transport) = make(); open(engine, transport)
        defer { engine.disconnect(reason: "test"); drain(engine) }
        transport.onEvent?(.message(.text("2"))); drain(engine)
        XCTAssertEqual(transport.batches.last, [.text("3")])
    }

    /// engine.io-client `_onError` → `error`, then `_onClose("transport error")`.
    /// The engine reports the failure once and closes; the manager decides
    /// whether a socket sees `.error` (connected) or `.connectError` (not).
    /// This used to assert that the error was swallowed.
    func testEstablishedReceiveFailureReportsTheErrorAndThenDisconnects() {
        let (engine, client, transport) = make(); open(engine, transport)
        transport.onEvent?(.closed(code: nil, reason: nil, error: EngineWebSocketError.closed))
        drain(engine)
        XCTAssertTrue(engine.closed)
        XCTAssertEqual(client.closes, ["transport error"])
        XCTAssertEqual(client.errors.count, 1)
    }

    func testOpeningFailureStillSurfacesConnectionError() {
        let (engine, client, transport) = make()
        transport.onEvent?(.closed(code: nil, reason: nil, error: EngineWebSocketError.notOpen))
        drain(engine)
        XCTAssertTrue(engine.closed)
        XCTAssertEqual(client.closes.count, 1)
        XCTAssertEqual(client.errors.count, 1)
        XCTAssertEqual(client.opens, 0)
    }


    func testDuplicateTerminalEventsCloseEngineOnlyOnce() {
        let (engine, client, transport) = make(); open(engine, transport)
        let callback = transport.onEvent!
        callback(.closed(code: 1001, reason: nil, error: nil))
        callback(.closed(code: nil, reason: nil, error: EngineWebSocketError.closed))
        drain(engine)
        XCTAssertEqual(client.closes.count, 1)
        XCTAssertTrue(engine.closed)
        XCTAssertNil(engine.webSocketTransport)
    }

    func testEngineIOCloseReleasesTransportAndSession() {
        let (engine, client, transport) = make(); open(engine, transport)
        transport.onEvent?(.message(.text("1"))); drain(engine)
        XCTAssertTrue(engine.closed)
        XCTAssertNil(engine.session)
        XCTAssertNil(engine.webSocketTransport)
        XCTAssertEqual(client.closes.count, 1)
    }

    func testOldCallbacksCannotOpenOrCloseReplacementConnection() {
        let (engine, client, first) = make()
        let stale = first.onEvent!
        engine.disconnect(reason: "timeout"); drain(engine)
        let second = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in second }
        engine.connect(); drain(engine); open(engine, second)
        stale(.opened(protocol: nil))
        stale(.message(.text("0{\"sid\":\"stale\"}")))
        stale(.closed(code: nil, reason: nil, error: EngineWebSocketError.closed))
        drain(engine)
        XCTAssertTrue(engine.connected)
        XCTAssertEqual(engine.sid, "native")
        XCTAssertEqual(client.opens, 1)
        XCTAssertEqual(client.closes, ["timeout"])
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testWritableUsesNativeBackpressureAndIsSafeFromManagerQueue() {
        let (engine, _, transport) = make(); open(engine, transport)
        defer { engine.disconnect(reason: "test"); drain(engine) }
        XCTAssertTrue(engine.writable)
        engine.engineQueue.sync { transport.isWritable = false }
        XCTAssertFalse(engine.writable)
        engine.engineQueue.sync { XCTAssertFalse(engine.writable) }
    }

    func testSendFailureIsFatalOnAnActiveWebSocket() {
        let (engine, client, transport) = make(); open(engine, transport)
        transport.autoComplete = false
        var completed = 0
        engine.write("payload", withType: .message, withData: []) { completed += 1 }; drain(engine)
        engine.engineQueue.sync { transport.completions.removeFirst()(.failure(EngineWebSocketError.queueLimitExceeded)) }
        XCTAssertTrue(engine.closed)
        XCTAssertEqual(client.errors.count, 1)
        XCTAssertEqual(client.closes.count, 1)
        XCTAssertEqual(completed, 1)
    }

    func testFailedUpgradeKeepsHealthyPollingAndFlushesBufferedWrites() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.write("held", withType: .message, withData: []); drain(engine)
        XCTAssertTrue(engine.probing)
        XCTAssertFalse(engine.writable)
        candidate.onEvent?(.closed(code: nil, reason: nil, error: EngineWebSocketError.closed)); drain(engine)
        XCTAssertTrue(engine.connected)
        XCTAssertTrue(engine.polling)
        XCTAssertFalse(engine.probing)
        XCTAssertFalse(engine.fastUpgrade)
        XCTAssertTrue(client.closes.isEmpty)
        XCTAssertTrue(client.errors.isEmpty)
        XCTAssertTrue(engine.pollingWrites.contains("4held"))
        engine.disconnect(reason: "test"); drain(engine)
    }

    /// engine.io-client/test/connection.js — "should defer close when upgrading",
    /// "should send all buffered packets if closing is deferred" and "should not
    /// send packets if closing is deferred". JS `close()` calls `waitForUpgrade()`
    /// while upgrading; the buffer then leaves over the transport that won,
    /// followed by the close packet, and nothing new may be written meanwhile.
    func testCloseDeferredDuringUpgradeFlushesOverWebSocketAfterUpgrade() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.engineQueue.sync { engine.waitingForPoll = true }
        candidate.onEvent?(.message(.text("3probe"))); drain(engine)
        XCTAssertTrue(engine.fastUpgrade)
        engine.write("buffered", withType: .message, withData: []); drain(engine)
        var binaryCompletion = 0
        engine.send(Data([0, 1, 2, 3, 4])) { binaryCompletion += 1 }; drain(engine)
        engine.disconnect(reason: "io client disconnect"); drain(engine)
        XCTAssertFalse(engine.closed)
        XCTAssertTrue(engine.connected)
        XCTAssertTrue(client.closes.isEmpty)
        let held = engine.probeWait.count
        var refused = 0
        engine.write("hi", withType: .message, withData: []) { refused += 1 }
        engine.send(Data([9])) { refused += 1 }; drain(engine)
        XCTAssertEqual(refused, 2)
        XCTAssertEqual(engine.probeWait.count, held)
        engine.engineQueue.sync { engine.waitingForPoll = false; engine.doFastUpgrade() }
        drain(engine)
        XCTAssertFalse(engine.polling)
        XCTAssertEqual(candidate.batches.flatMap { $0 },
                       [.text("2probe"), .text("5"), .text("4buffered"), .binary(Data([0, 1, 2, 3, 4])), .text("1")])
        XCTAssertEqual(client.closes, ["io client disconnect"])
        XCTAssertEqual(client.upgradeEvents, ["upgrade", "close"])
        XCTAssertTrue(engine.probeWait.isEmpty)
        XCTAssertTrue(engine.postWait.isEmpty)
        XCTAssertEqual(binaryCompletion, 1)
        XCTAssertTrue(client.errors.isEmpty)
    }

    /// engine.io-client/test/connection.js — "should close on upgradeError if
    /// closing is deferred": `waitForUpgrade()` also resumes on `upgradeError`,
    /// and the held packets then go out over polling before the close.
    func testCloseDeferredDuringUpgradeResumesOverPollingOnUpgradeError() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.write("held", withType: .message, withData: []); drain(engine)
        engine.disconnect(reason: "io client disconnect"); drain(engine)
        XCTAssertFalse(engine.closed)
        candidate.onEvent?(.closed(code: nil, reason: nil, error: EngineWebSocketError.closed)); drain(engine)
        XCTAssertTrue(engine.closed)
        XCTAssertTrue(engine.pollingWrites.contains("4held"))
        XCTAssertEqual(client.closes, ["io client disconnect"])
        XCTAssertEqual(client.upgradeEvents, ["upgradeError", "close"])
        XCTAssertTrue(client.errors.isEmpty)
    }

    func testActivePollingFailureReportsUpgradeErrorBeforeDeferredClose() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.engineQueue.sync { engine.waitingForPoll = true }
        candidate.onEvent?(.message(.text("3probe"))); drain(engine)
        XCTAssertTrue(engine.fastUpgrade)
        engine.disconnect(reason: "io client disconnect"); drain(engine)
        XCTAssertTrue(client.closes.isEmpty)
        engine.didError(reason: "upgrade error"); drain(engine)
        XCTAssertEqual(client.upgradeEvents, ["upgradeError", "close"])
        XCTAssertEqual(client.errors, ["upgrade error"])
        XCTAssertEqual(client.closes, ["transport error"])
        XCTAssertTrue(engine.closed)
        XCTAssertTrue(engine.probeWait.isEmpty)
        XCTAssertEqual(candidate.aborts, 1)
        // A late candidate failure must not emit another upgradeError or close.
        candidate.onEvent?(.closed(code: nil, reason: nil, error: EngineWebSocketError.closed)); drain(engine)
        XCTAssertEqual(client.upgradeEvents, ["upgradeError", "close"])
    }

    /// engine.io-client `_onError`: the native failure is reported (`error`)
    /// before the close; the client used to swallow it under an established
    /// connection and only report "transport error".
    func testTransportFailureUnderAnEstablishedConnectionReportsItsDetailBeforeClosing() {
        let (engine, client, transport) = make()
        open(engine, transport)
        engine.engineQueue.sync { XCTAssertTrue(engine.connected) }

        let failure = NSError(domain: "NSPOSIXErrorDomain", code: 57,
                              userInfo: [NSLocalizedDescriptionKey: "Socket is not connected",
                                         NSUnderlyingErrorKey: NSError(domain: "kNWErrorDomainPOSIX", code: 57, userInfo: nil)])
        transport.onEvent?(.closed(code: 1006, reason: Data("gone".utf8), error: failure)); drain(engine)

        XCTAssertEqual(client.closes, ["transport error"])
        XCTAssertEqual(client.errors.count, 1)
        let detail = client.errors.first ?? ""
        XCTAssertTrue(detail.contains("NSPOSIXErrorDomain/57"), detail)
        XCTAssertTrue(detail.contains("Socket is not connected"), detail)
        XCTAssertTrue(detail.contains("underlying kNWErrorDomainPOSIX/57"), detail)
        XCTAssertTrue(detail.contains("close code 1006"), detail)
        XCTAssertTrue(detail.contains("reason gone"), detail)
    }

    /// A clean close under an established connection stays a plain
    /// "transport close" without an error event, like JS `_onClose`.
    func testCleanTransportCloseUnderAnEstablishedConnectionReportsNoError() {
        let (engine, client, transport) = make()
        open(engine, transport)
        transport.onEvent?(.closed(code: 1000, reason: nil, error: nil)); drain(engine)
        XCTAssertEqual(client.closes, ["transport close"])
        XCTAssertEqual(client.errors, [])
    }

    /// After `stopPolling()` retired the polling session, a failed upgrade
    /// candidate cannot fall back to polling: there is no transport to poll
    /// with, so the engine closes instead of staying "connected" without one.
    func testUpgradeFailureAfterStopPollingClosesInsteadOfResumingPolling() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.engineQueue.sync { engine.stopPolling() }
        let pollsBefore = engine.polls
        candidate.onEvent?(.closed(code: nil, reason: nil, error: EngineWebSocketError.closed)); drain(engine)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.closed)
            XCTAssertFalse(engine.connected)
        }
        XCTAssertEqual(engine.polls, pollsBefore, "no poll may start on the retired session")
        XCTAssertEqual(client.closes, ["transport error"])
    }

    /// engine.io-client never sends a NOOP during the upgrade: the server sends
    /// one over the pending polling GET. The client used to enqueue its own
    /// `6` "over polling"; blocked by `fastUpgrade`, it was flushed over the
    /// WebSocket right after `5`, which `@socket.io/bun-engine` answers with a
    /// parse-error close. The polling test double had recorded it as a polling
    /// write and hidden it from the WebSocket assertions.
    func testUpgradeSendsNoClientNoop() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.engineQueue.sync { engine.waitingForPoll = true } // a long poll is outstanding
        candidate.onEvent?(.message(.text("3probe"))); drain(engine)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.fastUpgrade)
            XCTAssertTrue(engine.polling, "the upgrade waits for the outstanding GET")
            XCTAssertFalse(engine.pollingWrites.contains("6"), "no client NOOP: \(engine.pollingWrites)")
            XCTAssertFalse(engine.postWait.contains { $0.msg == "6" }, "no NOOP queued for the WebSocket")
            engine.waitingForPoll = false
            engine.doFastUpgrade()
        }
        drain(engine)
        XCTAssertFalse(engine.polling)
        XCTAssertEqual(candidate.batches.flatMap { $0 }, [.text("2probe"), .text("5")],
                       "exactly the probe and the upgrade packet reach the WebSocket")
        XCTAssertTrue(client.closes.isEmpty)
        engine.disconnect(reason: "test"); drain(engine)
    }

    /// JS `pause()` resolves immediately when neither a poll nor a write is
    /// outstanding; there is no polling completion left to finish the upgrade,
    /// so `upgradeTransport()` has to do it itself.
    func testUpgradeCompletesImmediatelyWhenNoPollingRequestIsOutstanding() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.engineQueue.sync {
            engine.waitingForPoll = false
            engine.waitingForPost = false
        }
        candidate.onEvent?(.message(.text("3probe"))); drain(engine)
        XCTAssertFalse(engine.polling, "nothing outstanding: the upgrade completes at once")
        XCTAssertEqual(candidate.batches.flatMap { $0 }, [.text("2probe"), .text("5")])
        XCTAssertTrue(client.closes.isEmpty)
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testUpgradeWaitsForGetAndPostAndQueuesUpgradeFirst() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        engine.engineQueue.sync { engine.parseEngineMessage(upgradeHandshake) }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        engine.write("new", withType: .message, withData: []); drain(engine)
        engine.engineQueue.sync {
            engine.postWait = [("4old", nil)]
            engine.waitingForPoll = true
            engine.waitingForPost = true
        }
        candidate.onEvent?(.message(.text("3probe"))); drain(engine)
        engine.engineQueue.sync {
            engine.doFastUpgrade()
            XCTAssertTrue(engine.polling)
            engine.waitingForPoll = false
            engine.doFastUpgrade()
            XCTAssertTrue(engine.polling)
            engine.waitingForPost = false
            engine.doFastUpgrade()
        }
        drain(engine)
        XCTAssertFalse(engine.polling)
        XCTAssertEqual(candidate.batches.flatMap { $0 }, [.text("2probe"), .text("5"), .text("4old"), .text("4new")])
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testUnsupportedOptionsFailBeforeOpeningTransport() {
        let invalid: [SocketIOClientConfiguration] = [
            [.forceWebsockets(true), .webSocketOptions(.init(maximumMessageSize: 0))],
            [.forceWebsockets(true), .forcePolling(true)],
            [.forceWebsockets(true), .security(.certificatePinning([]))],
            [.forceWebsockets(true), .clientCertificate(URLCredential(user: "x", password: "y", persistence: .none))],
            [.forceWebsockets(true), .secure(true),
             .clientCertificate(URLCredential(user: "x", password: "y", persistence: .none))]
        ]
        for config in invalid {
            let (engine, client, transport) = make(config)
            XCTAssertTrue(engine.closed)
            XCTAssertEqual(transport.connects, 0)
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertEqual(client.closes.count, 1)
        }
    }

    func testInvalidDictionarySecurityNeverDisappears() {
        for key in ["security", "secure", "sessionDelegate", "webSocketOptions", "clientCertificate"] {
            let config = ["forceWebsockets": true, key: "invalid legacy object"] as [String: Any]
            let (engine, client, transport) = make(config.toSocketConfiguration())
            XCTAssertTrue(engine.closed, key)
            XCTAssertEqual(transport.connects, 0, key)
            XCTAssertEqual(client.errors.count, 1, key)
        }
    }

    /// Removed options must never silently enable a connection with different semantics.
    func testRemovedDictionaryOptionsFailBeforeOpeningTransport() {
        for key in ["version", "compress", "selfSigned", "enableSOCKSProxy", "useCustomEngine", "customEngine"] {
            for value: Any in [true, false, "obsolete"] {
                let config = ["forceWebsockets": true, key: value] as [String: Any]
                let (engine, client, transport) = make(config.toSocketConfiguration())
                XCTAssertTrue(engine.closed, key)
                XCTAssertEqual(transport.connects, 0, key)
                XCTAssertEqual(client.errors.count, 1, key)
                XCTAssertEqual(client.closes.count, 1, key)
            }
        }
    }

    func testRequestPreservesHeadersCookiePrecedencePathAndParameters() {
        let client = NativeEngineClient()
        let cookie = HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "configured", .value: "yes"])!
        let engine = SocketEngine(client: client, url: url, config: [
            .forceWebsockets(true), .cookies([cookie]), .path("/custom"), .connectParams(["hello": "a b"]),
            .extraHeaders(["Cookie": "explicit=yes", "Authorization": "Bearer test"])
        ])
        let transport = NativeEngineTransport()
        var captured: URLRequest?
        engine.webSocketTransportFactory = { captured = $0; return transport }
        engine.connect(); drain(engine)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cookie"), "explicit=yes")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.path, "/custom/")
        let params = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(params.contains(URLQueryItem(name: "hello", value: "a b")))
        XCTAssertTrue(params.contains(URLQueryItem(name: "EIO", value: "4")))
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testManagerConnectTimeoutIgnoresLateNativeHandshake() {
        let config: SocketIOClientConfiguration = [.forceWebsockets(true), .reconnects(false), .connectTimeout(0.05)]
        let manager = SocketManager(socketURL: url, config: config)
        let engine = SocketEngine(client: manager, url: url, config: config)
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in transport }
        manager.engine = engine
        let socket = manager.defaultSocket
        let timedOut = expectation(description: "manager timeout")
        socket.on(clientEvent: .connectError) { values, _ in
            if values.first as? String == "timeout" { timedOut.fulfill() }
        }
        socket.connect(); drain(engine)
        let stale = transport.onEvent
        wait(for: [timedOut], timeout: 3)
        drain(engine)
        stale?(.opened(protocol: nil))
        stale?(.message(.text(handshake)))
        drain(engine)
        XCTAssertTrue(engine.closed)
        XCTAssertFalse(engine.connected)
        XCTAssertNotEqual(socket.status, .connected)
        manager.disconnect()
    }
}


extension SocketNativeEngineTest {
    func testSuccessfulUpgradeRetiresOnlyThePollingSession() {
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [])
        let candidate = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in candidate }
        let retired = expectation(description: "polling session invalidated after handoff")
        let delegate = PollingRetirementDelegate { retired.fulfill() }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        engine.engineQueue.sync {
            engine.setTestSession(session)
            engine.parseEngineMessage(upgradeHandshake)
        }
        let barrier = engine.engineQueue.sync { engine.pollingPostGroup }
        candidate.onEvent?(.opened(protocol: nil)); drain(engine)
        candidate.onEvent?(.message(.text("3probe"))); drain(engine)
        wait(for: [retired], timeout: 5)
        engine.engineQueue.sync {
            XCTAssertNil(engine.session)
            XCTAssertFalse(engine.pollingPostGroup === barrier)
            XCTAssertFalse(engine.invalidated)
            XCTAssertFalse(engine.polling)
            XCTAssertTrue(engine.connected)
            XCTAssertFalse(engine.closed)
        }
        XCTAssertEqual(candidate.batches.flatMap { $0 }, [.text("2probe"), .text("5")])
        XCTAssertTrue(client.closes.isEmpty)
        engine.disconnect(reason: "test"); drain(engine)
    }
}

private final class PollingRetirementDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let onInvalidation: () -> Void
    init(_ callback: @escaping () -> Void) { onInvalidation = callback }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        XCTAssertNil(error)
        onInvalidation()
    }
}

/// Stateless session-local HTTP fixture: host selects accepted/rejected polling.
private final class TransportSelectionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let rejected = url.host == "reject.polling.test"
        if !rejected && url.query?.contains("sid=") == true { return } // held poll
        let response = HTTPURLResponse(url: url, statusCode: rejected ? 403 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = rejected ? "denied" : "0{\"sid\":\"poll\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension SocketNativeEngineTest {
    private func selectionEngine(host: String, transports: [SocketTransport]) -> (SocketEngine, NativeEngineClient, NativeEngineTransport) {
        let client = NativeEngineClient()
        let engine = SocketEngine(client: client, url: URL(string: "http://" + host)!,
                                  config: [.transports(transports), .tryAllTransports(true)])
        engine.pollingSessionConfigurationFactory = {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [TransportSelectionProtocol.self]
            return config
        }
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in transport }
        return (engine, client, transport)
    }

    func testRejectedPollingFallsBackToWebSocketWithoutIntermediateError() {
        let (engine, client, transport) = selectionEngine(host: "reject.polling.test", transports: [.polling, .websocket])
        let fallback = expectation(description: "fallback websocket created")
        engine.webSocketTransportFactory = { _ in fallback.fulfill(); return transport }
        engine.connect()
        wait(for: [fallback], timeout: 3)
        drain(engine)
        open(engine, transport)
        engine.engineQueue.sync {
            XCTAssertEqual(client.opens, 1)
            XCTAssertTrue(client.errors.isEmpty)
            XCTAssertTrue(client.closes.isEmpty)
            XCTAssertFalse(engine.polling)
        }
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testRejectedWebSocketFallsBackToPollingWithoutIntermediateError() {
        let (engine, client, transport) = selectionEngine(host: "accept.polling.test", transports: [.websocket, .polling])
        let opened = expectation(description: "polling opened")
        client.onOpen = { opened.fulfill() }
        engine.connect(); drain(engine)
        transport.onEvent?(.closed(code: nil, reason: nil, error: URLError(.cannotConnectToHost)))
        wait(for: [opened], timeout: 3)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.polling)
            XCTAssertEqual(client.opens, 1)
            XCTAssertTrue(client.errors.isEmpty)
            XCTAssertTrue(client.closes.isEmpty)
        }
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testExhaustedTransportsReportOneFinalFailure() {
        let (engine, client, transport) = selectionEngine(host: "reject.polling.test", transports: [.websocket, .polling])
        let closed = expectation(description: "all transports failed")
        client.onClose = { closed.fulfill() }
        engine.connect(); drain(engine)
        transport.onEvent?(.closed(code: nil, reason: nil, error: URLError(.cannotConnectToHost)))
        wait(for: [closed], timeout: 3)
        engine.engineQueue.sync {
            XCTAssertEqual(client.opens, 0)
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertEqual(client.closes, ["transport error"])
        }
    }

    func testRememberUpgradeStartsNextEngineWithSuccessfulWebSocket() {
        let (first, _, firstTransport) = make()
        open(first, firstTransport)
        first.disconnect(reason: "test"); drain(first)
        let (second, _, secondTransport) = make([.rememberUpgrade(true)])
        second.engineQueue.sync {
            XCTAssertEqual(secondTransport.connects, 1)
            XCTAssertFalse(second.polling)
        }
        second.disconnect(reason: "test"); drain(second)
    }
}

extension SocketNativeEngineTest {
    func testFallbackDisabledStopsAtFirstFailure() {
        let (engine, client, transport) = selectionEngine(host: "reject.polling.test", transports: [.polling, .websocket])
        engine.setConfigs([.tryAllTransports(false)])
        let closed = expectation(description: "first failure is final")
        client.onClose = { closed.fulfill() }
        engine.connect()
        wait(for: [closed], timeout: 3)
        engine.engineQueue.sync {
            XCTAssertEqual(transport.connects, 0)
            XCTAssertEqual(client.errors.count, 1)
            XCTAssertEqual(client.closes.count, 1)
        }
    }

    func testPollingOnlyFiltersWebSocketUpgradeAndPreservesCallerTransportList() {
        let options: [SocketTransport] = [.polling]
        let client = NativeEngineClient()
        let engine = NativePollingTestEngine(client: client, url: url, config: [.transports(options)])
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in transport }
        engine.engineQueue.sync {
            engine.parseEngineMessage(upgradeHandshake)
            XCTAssertTrue(engine.connected)
            XCTAssertTrue(engine.polling)
            XCTAssertEqual(transport.connects, 0)
            XCTAssertEqual(options, [.polling])
            XCTAssertEqual(engine.transports, options)
        }
        engine.disconnect(reason: "test"); drain(engine)
    }

    func testEmptyTransportListFailsWithoutNetwork() {
        let (engine, client, transport) = make([.transports([])])
        engine.engineQueue.sync {
            XCTAssertEqual(client.errors, ["Invalid socket configuration: No transports available"])
            XCTAssertEqual(transport.connects, 0)
            XCTAssertTrue(engine.closed)
        }
    }

    func testRememberUpgradeDisabledStillStartsWithPolling() {
        let (first, _, firstTransport) = make()
        open(first, firstTransport)
        first.disconnect(reason: "test"); drain(first)
        let (second, client, transport) = selectionEngine(host: "accept.polling.test", transports: [.polling, .websocket])
        let opened = expectation(description: "default remains polling")
        client.onOpen = { opened.fulfill() }
        second.connect()
        wait(for: [opened], timeout: 3)
        second.engineQueue.sync {
            XCTAssertTrue(second.polling)
            XCTAssertEqual(transport.connects, 0)
        }
        second.disconnect(reason: "test"); drain(second)
    }
}


extension SocketNativeEngineTest {
    func testRemovingRequestTimeoutRestoresDefaultsOnReusedEngine() throws {
        let manager = SocketManager(socketURL: url,
            config: [.autoConnect(false), .forceWebsockets(true), .requestTimeout(125)])
        let engine = SocketEngine(client: manager, url: url, config: manager.config)
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in transport }
        manager.engine = engine
        defer { engine.disconnect(reason: "test"); drain(engine) }

        engine.connect(); drain(engine)
        let originalSession = try engine.engineQueue.sync { try XCTUnwrap(engine.session) }
        XCTAssertEqual(originalSession.configuration.timeoutIntervalForRequest, 125)
        XCTAssertEqual(originalSession.configuration.timeoutIntervalForResource, 125)

        manager.config = [.autoConnect(false), .forceWebsockets(true)]
        engine.connect(); drain(engine)

        XCTAssertTrue(manager.engine === engine)
        try engine.engineQueue.sync {
            XCTAssertNil(engine.requestTimeout)
            let session = try XCTUnwrap(engine.session)
            XCTAssertFalse(session === originalSession)
            let defaults = URLSessionConfiguration.default
            XCTAssertEqual(session.configuration.timeoutIntervalForRequest, defaults.timeoutIntervalForRequest)
            XCTAssertEqual(session.configuration.timeoutIntervalForResource, defaults.timeoutIntervalForResource)
            for request in [engine.createPollingRequest(for: engine.urlPollingHandshake),
                            engine.createPollingRequest(for: engine.urlPollingWithSid),
                            engine.createRequestForPost(with: ["4hello"])] {
                XCTAssertEqual(request.timeoutInterval, URLRequest(url: url).timeoutInterval)
            }
        }
    }

    func testRemovingInvalidClientCertificateAllowsReusedEngineToConnect() {
        let url = URL(string: "https://localhost:8443")!
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false), .forceWebsockets(true),
            .clientCertificate(URLCredential(user: "invalid", password: "identity", persistence: .none))])
        let client = NativeEngineClient()
        let engine = SocketEngine(client: client, url: url, config: manager.config)
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in transport }
        manager.engine = engine
        defer { engine.disconnect(reason: "test"); drain(engine) }

        engine.connect(); drain(engine)
        XCTAssertTrue(engine.closed)
        XCTAssertEqual(transport.connects, 0)
        XCTAssertEqual(client.errors.count, 1)

        manager.config = [.autoConnect(false), .forceWebsockets(true)]
        engine.connect(); drain(engine)

        XCTAssertTrue(manager.engine === engine)
        XCTAssertFalse(engine.closed)
        XCTAssertEqual(transport.connects, 1)
        XCTAssertEqual(client.errors.count, 1)
    }

    #if canImport(Security)
    func testRemovingClientCertificateStopsOfferingIdentityOnReusedEngine() throws {
        let url = URL(string: "https://localhost:8443")!
        let credential = try NativeTLSFixtures.clientCredential()
        let manager = SocketManager(socketURL: url, config: [.autoConnect(false), .forceWebsockets(true)])
        let engine = SocketEngine(client: manager, url: url, config: manager.config)
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { _ in transport }
        manager.engine = engine
        defer { engine.disconnect(reason: "test"); drain(engine) }

        var previousSession: URLSession?
        for configured in [true, false, true, false] {
            var config: SocketIOClientConfiguration = [.autoConnect(false), .forceWebsockets(true)]
            if configured { config.insert(.clientCertificate(credential)) }
            manager.config = config
            engine.connect(); drain(engine)

            XCTAssertTrue(manager.engine === engine)
            try engine.engineQueue.sync {
                let session = try XCTUnwrap(engine.session)
                XCTAssertFalse(session === previousSession)
                previousSession = session
                let proxy = try XCTUnwrap(session.delegate as? SocketSessionDelegateProxy)
                let space = URLProtectionSpace(host: "localhost", port: 8443, protocol: "https", realm: nil,
                                               authenticationMethod: NSURLAuthenticationMethodClientCertificate)
                let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                    previousFailureCount: 0, failureResponse: nil, error: nil, sender: NativeChallengeSender())
                var calls = 0
                let completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, result in
                    XCTAssertEqual(disposition, configured ? .useCredential : .performDefaultHandling)
                    if configured { XCTAssertTrue(result === credential) }
                    else { XCTAssertNil(result) }
                    calls += 1
                }
                proxy.urlSession(session, didReceive: challenge, completionHandler: completion)
                proxy.urlSession(session, task: session.dataTask(with: url), didReceive: challenge,
                                 completionHandler: completion)
                XCTAssertEqual(calls, 2)
            }
        }
    }
    #endif

    func testInvalidRequestTimeoutFailsBeforeOpeningTransport() {
        for value in [0.0, -1, .infinity, -.infinity, .nan] {
            let (engine, client, transport) = make([.forceWebsockets(true), .requestTimeout(value)])
            XCTAssertTrue(engine.closed)
            XCTAssertEqual(transport.connects, 0)
            XCTAssertEqual(client.errors, ["Invalid socket configuration: requestTimeout must be a positive finite number of seconds"])
        }
    }

    func testRequestTimeoutDictionaryRoundTripAndInvalidType() {
        let config = (["requestTimeout": 120.5] as [String: Any]).toSocketConfiguration()
        XCTAssertEqual(config.first?.getSocketIOOptionValue() as? Double, 120.5)
        XCTAssertEqual(config.first?.description, "requestTimeout")
        let invalid = (["requestTimeout": "120"] as [String: Any]).toSocketConfiguration()
        XCTAssertTrue(invalid.contains(.invalidConfiguration("")))
    }

    func testPollingRequestTimeoutDoesNotAlterWebSocketRequest() {
        let client = NativeEngineClient()
        let engine = SocketEngine(client: client, url: url,
                                  config: [.forceWebsockets(true), .requestTimeout(125)])
        let transport = NativeEngineTransport()
        engine.webSocketTransportFactory = { request in
            XCTAssertEqual(request.timeoutInterval, 60)
            return transport
        }
        engine.connect(); drain(engine)
        XCTAssertEqual(transport.connects, 1)
        engine.disconnect(reason: "test"); drain(engine)
    }
}
