//
//  SocketSendTest.swift
//  Socket.IO-Client-Swift
//
//  Phase 6 — JS-aligned `send` / `sendWithAck` shortcuts.
//

import XCTest
@testable import SocketIO

/// Test logger that captures every "Emitting: ..." log line so we can assert
/// what packet name reached the wire.
final class CapturingLogger: SocketLogger {
    var log: Bool = true
    var captured: [String] = []
    func log(_ message: @autoclosure () -> String, type: String) {
        let str = message()
        if str.hasPrefix("Emitting: ") { captured.append(str) }
    }
    func error(_ message: @autoclosure () -> String, type: String) {}
}

final class SocketSendTest: XCTestCase {
    var manager: SocketManager!
    var socket: SocketIOClient!
    var logger: CapturingLogger!

    override func setUp() {
        super.setUp()
        logger = CapturingLogger()
        let queue = DispatchQueue(label: "test.SocketSendTest.handleQueue")
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.log(false), .logger(logger), .handleQueue(queue)])
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
    }

    private func drain() { manager.handleQueue.sync { } }

    func testSendVariadicEmitsAsMessage() {
        socket.send("hello")
        drain()
        XCTAssertEqual(logger.captured.count, 1)
        XCTAssertTrue(logger.captured.first?.contains("\"message\"") == true,
                      "expected 'message' event name in captured packet, got: \(logger.captured)")
        XCTAssertTrue(logger.captured.first?.contains("hello") == true)
    }

    func testSendWithItemsArray() {
        socket.send(with: ["hello", 42] as [SocketData])
        drain()
        XCTAssertEqual(logger.captured.count, 1)
        XCTAssertTrue(logger.captured.first?.contains("\"message\"") == true)
    }

    func testSendNoArgsEmitsValidPacket() {
        socket.send()
        drain()
        XCTAssertEqual(logger.captured.count, 1)
        XCTAssertTrue(logger.captured.first?.contains("\"message\"") == true,
                      "send() with no args still emits 'message' event")
    }

    func testSendWithAckReturnsCallback() {
        let ack = socket.sendWithAck("ping")
        XCTAssertNotNil(ack)
        // The OnAckCallback exists; actually triggering it requires .timingOut.
        ack.timingOut(after: 0) { _ in }
        drain()
        XCTAssertEqual(logger.captured.count, 1)
        XCTAssertTrue(logger.captured.first?.contains("\"message\"") == true)
    }

    func testSendWithAckArrayForm() {
        let ack = socket.sendWithAck(with: ["x", "y"] as [SocketData])
        ack.timingOut(after: 0) { _ in }
        drain()
        XCTAssertEqual(logger.captured.count, 1)
        XCTAssertTrue(logger.captured.first?.contains("\"message\"") == true)
    }
}
