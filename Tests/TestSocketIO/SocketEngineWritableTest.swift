//
//  SocketEngineWritableTest.swift
//  Socket.IO-Client-Swift
//
//  Phase 7 Task 1 — verify the `SocketEngineSpec.writable` default fail-safe.
//

import XCTest
@testable import SocketIO

/// A minimal `SocketEngineSpec` conformer that does NOT override `writable`.
/// Verifies the protocol's default fail-safe `false` returns. Most other
/// `SocketEngineSpec` requirements are stubbed.
private final class StubEngine: NSObject, SocketEnginePollable {
    weak var client: SocketEngineClient?
    var invalidated = false
    var postWait: [Post] = []
    var session: URLSession?
    var waitingForPoll = false
    var waitingForPost = false
    var errors: [String] = []
    var packets: [String] = []
    var webSocketFlushes = 0
    var closed: Bool = false
    var connected: Bool = true
    var connectParams: [String: Any]? = nil
    var cookies: [HTTPCookie]? = nil
    var engineQueue: DispatchQueue = DispatchQueue(label: "stub.engineQueue")
    var extraHeaders: [String: String]? = nil
    var fastUpgrade: Bool = false
    var forcePolling: Bool = false
    var forceWebsockets: Bool = false
    var polling: Bool = false
    var probing: Bool = false
    var sid: String = "stub-sid"
    var socketPath: String = "/socket.io/"
    var urlPolling: URL = URL(string: "http://localhost/")!
    var urlWebSocket: URL = URL(string: "ws://localhost/")!



    required convenience init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.init()
        self.client = client
    }

    override init() {
        super.init()
    }

    func connect() {}
    func didError(reason: String) { errors.append(reason) }
    func disconnect(reason: String) {}
    func doFastUpgrade() {}
    func flushWaitingForPostToWebSocket() { webSocketFlushes += 1; postWait.removeAll() }
    func parseEngineData(_ data: Data) {}
    func parseEngineMessage(_ message: String) {
        packets.append(message)
        if message == "1" { closed = true }
    }
    func stopPolling() { invalidated = true }
    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) {}
}

final class SocketEngineWritableTest: XCTestCase {
    func testProtocolDefaultIsFalse() {
        let stub = StubEngine()
        XCTAssertFalse(stub.writable, "default impl must return false (fail-safe)")
    }
}

extension SocketEngineWritableTest {
    func testCustomEngineFlushesQueuedPollingWritesThroughWebSocketAfterUpgrade() {
        let stub = StubEngine()
        stub.polling = false
        stub.postWait = [(msg: "4queued", completion: nil)]
        stub.flushWaitingForPost()
        XCTAssertEqual(stub.webSocketFlushes, 1)
        XCTAssertTrue(stub.postWait.isEmpty)
        XCTAssertFalse(stub.waitingForPost)
    }

    func testCustomEngineInheritsSafeDefaultsAndLegacyErrorForwarding() {
        let stub = StubEngine()
        XCTAssertNil(stub.maxPayload)
        XCTAssertNil(stub.timestampRequests)
        XCTAssertEqual(stub.timestampParam, "t")
        XCTAssertFalse(stub.forceBase64)
        XCTAssertFalse(stub.hasPingExpired)
        stub.didError(reason: "legacy reason", error: SocketTransportError(transport: "polling", operation: "read"))
        XCTAssertEqual(stub.errors, ["legacy reason"])
    }
    func testCustomPollingDecoderStopsDispatchAtClose() {
        let stub = StubEngine()
        stub.parsePollingMessage("4first\u{1e}1\u{1e}4late")
        XCTAssertEqual(stub.packets, ["4first", "1"])
        stub.doPoll()
        XCTAssertFalse(stub.waitingForPoll, "A closed custom engine must not start a new poll")
    }
}
