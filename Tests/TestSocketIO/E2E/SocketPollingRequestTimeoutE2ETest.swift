import Foundation
import XCTest
@testable import SocketIO

final class SocketPollingRequestTimeoutE2ETest: XCTestCase {
    private func timeout(mode: String, bounded: Bool = false) throws {
        let server = try TestServerProcess.start(serverScript: "polling-request-timeout.mjs",
            extraEnvironment: ["REQUEST_TIMEOUT_MODE": mode])
        defer { server.stop() }
        let client = RequestTimeoutClient()
        var config: SocketIOClientConfiguration = [.forcePolling(true), .requestTimeout(0.5)]
        if bounded { config.insert(.bufferLimits(.init(maximumPollingResponseBytes: 4096))) }
        let engine = SocketEngine(client: client, url: URL(string: "http://127.0.0.1:\(server.port)")!, config: config)
        defer {
            engine.engineQueue.sync { engine.didError(reason: "test cleanup") }
        }
        let failed = expectation(description: "HTTP request times out")
        failed.assertForOverFulfill = false
        let closed = expectation(description: "engine closes after request timeout")
        closed.assertForOverFulfill = false
        client.onOpen = {
            if mode == "post" { engine.send("payload", withData: []) }
        }
        client.onError = { error in
            XCTAssertEqual((error.underlyingError as? URLError)?.code, .timedOut)
            XCTAssertEqual(error.transport, "polling")
            XCTAssertEqual(error.operation, mode == "post" ? "write" : "read")
            failed.fulfill()
        }
        client.onClose = { closed.fulfill() }
        engine.connect()
        wait(for: [failed, closed], timeout: 6)
        engine.engineQueue.sync { XCTAssertTrue(engine.closed) }
    }

    func testHandshakeRequestTimesOut() throws { try timeout(mode: "handshake") }
    func testEstablishedPollingGETTimesOut() throws { try timeout(mode: "get") }
    func testPollingPOSTTimesOutWhileGETsRemainHealthy() throws { try timeout(mode: "post") }
    func testIncomingBytesDoNotExtendTotalRequestDeadline() throws { try timeout(mode: "trickle") }
    func testBoundedResponseUsesTheSameRequestDeadline() throws { try timeout(mode: "trickle", bounded: true) }
}

private final class RequestTimeoutClient: NSObject, SocketEngineClient {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onError: ((SocketTransportError) -> Void)?
    func engineDidOpen(reason: String) { onOpen?() }
    func engineDidClose(reason: String) { onClose?() }
    func engineDidError(reason: String) { XCTFail("Missing native error: \(reason)") }
    func engineDidError(reason: String, error: SocketTransportError) { onError?(error) }
    func engineDidReceivePing() {}
    func engineDidReceivePong() {}
    func engineDidSendPong() {}
    func parseEngineMessage(_ msg: String) {}
    func parseEngineBinaryData(_ data: Data) {}
    func engineDidWebsocketUpgrade(headers: [String: String]) {}
}
