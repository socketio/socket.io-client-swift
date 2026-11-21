//
//  MockEngine.swift
//  Socket.IO-Client-Swift
//
//  Phase 7 Task 3 — test-only `SocketEngineSpec` conformer for behavior tests
//  of the volatile-emit gate. Captures sent packets via `write()` (the protocol
//  requirement; `send(_:withData:completion:)` is an extension method that
//  routes through `write`, so dynamic dispatch lands here).
//

import Foundation
@testable import SocketIO

/// Test-only `SocketEngineSpec` conformer. Captures sent packets; lets tests
/// flip `writable` directly to drive the Phase 7 volatile gate.
final class MockEngine: NSObject, SocketEngineSpec {
    weak var client: SocketEngineClient?
    var closed: Bool = false
    var connected: Bool = true
    var connectParams: [String: Any]?
    var cookies: [HTTPCookie]?
    var engineQueue: DispatchQueue = DispatchQueue(label: "mock.engineQueue")
    var extraHeaders: [String: String]?
    var fastUpgrade: Bool = false
    var forcePolling: Bool = false
    var forceWebsockets: Bool = false
    var polling: Bool = false
    var probing: Bool = false
    var sid: String = "mock-sid"
    var socketPath: String = "/socket.io/"
    var urlPolling: URL = URL(string: "http://localhost/")!
    var urlWebSocket: URL = URL(string: "ws://localhost/")!

    /// Test-controlled writable signal. Defaults to `true` (most tests want
    /// non-volatile-drop behavior); flip to `false` to exercise the volatile gate.
    var writable: Bool = true
    var hasPingExpired: Bool = false

    /// Captured packets sent via `write(_:withType:withData:completion:)`.
    /// `SocketIOClient.emit` calls `engine.send(...)` which is an extension
    /// method on `SocketEngineSpec` that routes through `write` (the protocol
    /// requirement), so all sent packets are captured here.
    var sentPackets: [(String, [Data])] = []
    var onWrite: ((String, [Data]) -> Void)?

    required convenience init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.init()
        self.client = client
    }

    override init() {
        super.init()
    }

    /// Every `disconnect(reason:)` the client asked for, in order. Gate R1's
    /// incoming overflows are observable only as a close with a reason.
    var disconnectReasons: [String] = []

    func connect() {}
    func didError(reason: String) {}
    func disconnect(reason: String) { disconnectReasons.append(reason) }
    func doFastUpgrade() {}
    func flushWaitingForPostToWebSocket() {}
    func parseEngineData(_ data: Data) {}
    func parseEngineMessage(_ message: String) {}

    func write(_ msg: String,
               withType type: SocketEnginePacketType,
               withData data: [Data],
               completion: (() -> ())?) {
        sentPackets.append((msg, data))
        onWrite?(msg, data)
        completion?()
    }
}
