import Foundation
import XCTest
@testable import SocketIO

/// JS parity: `Manager.ondata` in `socket.io-client/lib/manager.ts` wraps
/// `decoder.add(data)` in try/catch and calls `onclose("parse error")` — an
/// undecodable packet is fatal for the transport, never silently dropped.
class SocketParseErrorTest: XCTestCase {
    private func makeConnectedManager() -> (SocketManager, SocketIOClient, FakeParseErrorEngine) {
        let manager = SocketManager(socketURL: URL(string: "http://localhost/")!,
                                    config: [.log(false), .reconnects(false)])
        let socket = manager.defaultSocket
        let fake = FakeParseErrorEngine(client: manager, url: URL(string: "http://localhost/")!, options: nil)
        manager.engine = fake
        socket.didConnect(toNamespace: "/", payload: ["sid": "s1"])
        manager.setTestStatus(.connected)

        return (manager, socket, fake)
    }

    func testUndecodableMessageClosesEngineWithParseError() {
        let (manager, socket, fake) = makeConnectedManager()

        let disconnected = expectation(description: "socket disconnect")
        var reason: String?
        socket.on(clientEvent: .disconnect) { data, _ in
            reason = data.first as? String
            disconnected.fulfill()
        }

        manager.parseEngineMessage("bad")

        wait(for: [disconnected], timeout: 3)
        XCTAssertEqual(fake.disconnectReasons, ["parse error"])
        XCTAssertEqual(reason, "parse error")
    }

    func testUnexpectedBinaryDataClosesEngineWithParseError() {
        let (manager, socket, fake) = makeConnectedManager()

        let disconnected = expectation(description: "socket disconnect")
        var reason: String?
        socket.on(clientEvent: .disconnect) { data, _ in
            reason = data.first as? String
            disconnected.fulfill()
        }

        // No packet is waiting for binary, so `parseBinaryData` rejects this.
        manager.parseEngineBinaryData(Data([0xff, 0x00, 0x13]))

        wait(for: [disconnected], timeout: 3)
        XCTAssertEqual(fake.disconnectReasons, ["parse error"])
        XCTAssertEqual(reason, "parse error")
    }

    func testWellFormedEventDoesNotCloseEngine() {
        let (manager, socket, fake) = makeConnectedManager()

        let handled = expectation(description: "event handled")
        socket.on("hello") { _, _ in handled.fulfill() }

        manager.parseEngineMessage("2[\"hello\"]")

        wait(for: [handled], timeout: 3)
        XCTAssertTrue(fake.disconnectReasons.isEmpty)
    }

    func testParseErrorAfterDisconnectDoesNotCloseAgain() {
        let (manager, _, fake) = makeConnectedManager()
        manager.disconnect()

        manager.parseEngineMessage("bad")

        let settled = expectation(description: "settled")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        // Only the explicit disconnect; the late "bad" packet must not close again.
        XCTAssertEqual(fake.disconnectReasons, ["io client disconnect"])
    }
}

/// Fake engine modelled on `TestEngine` in `SocketSideEffectTest.swift`.
private class FakeParseErrorEngine: SocketEngineSpec {
    weak var client: SocketEngineClient?
    private(set) var closed = false
    private(set) var connected = false
    var connectParams: [String: Any]? = nil
    private(set) var cookies: [HTTPCookie]? = nil
    private(set) var engineQueue = DispatchQueue.main
    var extraHeaders: [String: String]? = nil
    private(set) var fastUpgrade = false
    private(set) var forcePolling = false
    private(set) var forceWebsockets = false
    private(set) var polling = false
    private(set) var probing = false
    private(set) var sid = ""
    private(set) var socketPath = ""
    private(set) var urlPolling = URL(string: "http://localhost/")!
    private(set) var urlWebSocket = URL(string: "http://localhost/")!


    private(set) var disconnectReasons = [String]()

    required init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.client = client
    }

    func connect() { }

    func didError(reason: String) { }

    func disconnect(reason: String) {
        disconnectReasons.append(reason)
        client?.engineDidClose(reason: reason)
    }

    func doFastUpgrade() { }
    func flushWaitingForPostToWebSocket() { }
    func parseEngineData(_ data: Data) { }
    func parseEngineMessage(_ message: String) { }
    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) { }
}
