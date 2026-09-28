import Foundation
import XCTest
@testable import SocketIO

final class CoverageRecordingLogger: SocketLogger {
    private let lock = NSLock()
    private var enabled = true
    private var messages: [String] = []
    var log: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); defer { lock.unlock() }; enabled = newValue }
    }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    func log(_ message: @autoclosure () -> String, type: String) { record(message(), type: type) }
    func error(_ message: @autoclosure () -> String, type: String) { record(message(), type: type) }
    private func record(_ message: @autoclosure () -> String, type: String) {
        lock.lock(); defer { lock.unlock() }
        if enabled { messages.append(type + ": " + message()) }
    }
}

private enum CoverageRepresentationError: Error { case rejected }
private struct CoverageThrowingData: SocketData {
    func socketRepresentation() throws -> SocketData { throw CoverageRepresentationError.rejected }
}

final class SocketPublicAPICoverageTest: XCTestCase {
    private var manager: SocketManager!
    private var engine: MockEngine!
    private var socket: SocketIOClient!
    private let queue = DispatchQueue(label: "public.contracts")
    private var logger: CoverageRecordingLogger!

    override func setUp() {
        super.setUp()
        logger = CoverageRecordingLogger()
        manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                config: [.handleQueue(queue), .logger(logger), .log(true)])
        engine = MockEngine()
        manager.engine = engine
        socket = manager.defaultSocket
        queue.sync { manager.setTestStatus(.connected); socket.setTestStatus(.connected) }
    }
    override func tearDown() {
        queue.sync { manager.disconnect() }
        socket = nil; manager = nil; engine = nil
        DefaultSocketLogger.Logger = DefaultSocketLogger()
        super.tearDown()
    }

    func testRetryDiagnosticsDescribeActualAttemptsAndFinalDiscard() throws {
        try queue.sync {
            socket.retries = 1
            var results: [String] = []
            socket.emit("first", ack: { error, _ in
                XCTAssertEqual(error as? SocketAckError, .timeout)
                results.append("discarded")
            })
            socket.emit("second", ack: { error, data in
                XCTAssertNil(error)
                XCTAssertEqual(data as NSArray, ["ok"] as NSArray)
                results.append("acknowledged")
            })
            for attempt in 0..<2 {
                let packet = try manager.parseString(engine.sentPackets[attempt].0)
                XCTAssertEqual(packet.event, "first")
                socket.ackHandlers.cancelTimedAck(packet.id, fireWith: SocketAckError.timeout)
            }
            let second = try manager.parseString(engine.sentPackets[2].0)
            XCTAssertEqual(second.event, "second")
            socket.handleAck(second.id, data: ["ok"])
            XCTAssertEqual(results, ["discarded", "acknowledged"])
            XCTAssertEqual(socket.testRetryQueueCount, 0)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            XCTAssertEqual(logger.entries.filter { $0.contains("Queueing retriable emit:") }.count, 2)
            XCTAssertEqual(logger.entries.filter { $0.contains("Sending retriable emit [") }.count, 3)
            XCTAssertEqual(logger.entries.filter { $0.contains("discarded after 2 tries") }.count, 1)
        }
    }

    func testReservedEventsFailEveryAcknowledgementEntryBeforeAllocatingIDs() {
        queue.sync {
            var errors = 0
            var acknowledgements = 0
            socket.on(clientEvent: .error) { _, _ in errors += 1 }
            let reply: (Error?, [Any]) -> Void = { error, data in
                XCTAssertEqual((error as NSError?)?.domain, "SocketIO.Emit")
                XCTAssertEqual((error as NSError?)?.code, 1)
                XCTAssertTrue(data.isEmpty)
                acknowledgements += 1
            }
            socket.emit("connect", ack: reply)
            socket.timeout(after: 1).emit("disconnect", ack: reply)
            socket.volatile.emit("connect_error", ack: reply)
            _ = socket.emitWithAck("newListener")
            XCTAssertEqual(acknowledgements, 3)
            XCTAssertEqual(errors, 4)
            XCTAssertEqual(socket.currentAck, -1)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            XCTAssertTrue(engine.sentPackets.isEmpty)
        }
    }

    func testThrowingRepresentationsFailWithoutWritingOrAllocatingAnAck() {
        queue.sync {
            var errors: [Error] = []
            socket.on(clientEvent: .error) { data, _ in
                if let error = data.last as? Error { errors.append(error) }
            }
            let bad = CoverageThrowingData()
            socket.emit("ordinary", bad)
            socket.volatile.emit("volatile", bad)
            socket.rawEmitView.emit("raw", bad)
            _ = socket.rawEmitView.emitWithAck("raw-ack", bad)
            XCTAssertEqual(errors.count, 4)
            XCTAssertTrue(errors.allSatisfy { $0 is CoverageRepresentationError })
            XCTAssertEqual(socket.currentAck, -1)
            XCTAssertTrue(engine.sentPackets.isEmpty)
            XCTAssertEqual(socket.testRetainedBuffers.sendPackets, 0)
        }
        XCTAssertTrue(logger.entries.contains { $0.contains("volatile emit") })
        XCTAssertTrue(logger.entries.contains { $0.contains("raw-ack") })
    }

    func testModernAckWithoutManagerReportsDisconnection() {
        var owner: SocketManager? = SocketManager(socketURL: URL(string: "http://localhost")!, config: [])
        let orphan = owner!.defaultSocket
        owner = nil
        XCTAssertNil(orphan.manager)
        var replies = 0
        orphan.emit("event", ack: { error, items in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            XCTAssertTrue(items.isEmpty)
            replies += 1
        })
        XCTAssertEqual(replies, 1)
    }

    func testReleasedClientStillSettlesQueuedModernAck() {
        let replied = expectation(description: "released client acknowledgement fails")
        queue.suspend()
        var temporary: SocketIOClient? = SocketIOClient(manager: manager, nsp: "/temporary")
        weak var released = temporary
        temporary?.emit("event", ack: { error, items in
            XCTAssertEqual(error as? SocketAckError, .disconnected)
            XCTAssertTrue(items.isEmpty)
            replied.fulfill()
        })
        temporary = nil
        XCTAssertNil(released)
        queue.resume()
        wait(for: [replied], timeout: 2)
        queue.sync { XCTAssertTrue(engine.sentPackets.isEmpty) }
    }

    func testBroadcastUsesEveryNamespaceAndRejectsUnrepresentableInputAtomically() throws {
        try queue.sync {
            let other = manager.socket(forNamespace: "/other")
            other.setTestStatus(.connected)
            manager.emitAll("broadcast", 42)
            XCTAssertEqual(engine.sentPackets.count, 2)
            let decoded = try engine.sentPackets.map { try manager.parseString($0.0) }
            XCTAssertEqual(Set(decoded.map(\.nsp)), ["/", "/other"])
            for packet in decoded { XCTAssertEqual(packet.event, "broadcast"); XCTAssertEqual(packet.args.first as? Int, 42) }
            manager.emitAll("rejected", CoverageThrowingData())
            XCTAssertEqual(engine.sentPackets.count, 2)
        }
        XCTAssertTrue(logger.entries.contains { $0.contains("Error creating socketRepresentation for emit: rejected") })
    }

    func testRemoveNamespaceByNameIsIdempotentAndKeepsActiveSibling() {
        queue.sync {
            socket.setTestActive(true)
            let other = manager.socket(forNamespace: "/other")
            other.setTestActive(true); other.setTestStatus(.connected)
            manager.disconnectSocket(forNamespace: "/other")
            XCTAssertNil(manager.nsps["/other"])
            XCTAssertTrue(manager.nsps["/"] === socket)
            XCTAssertEqual(other.status, .disconnected)
            XCTAssertEqual(engine.sentPackets.map { $0.0 }, ["1/other,"])
            manager.disconnectSocket(forNamespace: "/other")
            XCTAssertEqual(engine.sentPackets.count, 1)
            XCTAssertTrue(engine.disconnectReasons.isEmpty)
        }
    }

    func testConnectOnConnectedSocketDoesNotJoinAgainAndManualReconnectClosesTransport() {
        queue.sync {
            socket.connect()
            XCTAssertTrue(engine.sentPackets.isEmpty)
            manager.reconnect()
            XCTAssertEqual(engine.disconnectReasons, ["transport close"])
        }
        XCTAssertTrue(logger.entries.contains { $0.contains("already connected socket") })
    }

    func testExplicitRecoveryCredentialsOverrideStoredCredentials() throws {
        try queue.sync {
            socket._pid = "stored-pid"; socket._lastOffset = "stored-offset"
            manager.connectSocket(socket, withPayload: ["pid": "explicit-pid", "offset": "explicit-offset"])
            let packet = try manager.parseString(XCTUnwrap(engine.sentPackets.last?.0))
            let payload = try XCTUnwrap(packet.data.first as? [String: String])
            XCTAssertEqual(payload, ["pid": "explicit-pid", "offset": "explicit-offset"])
        }
        XCTAssertTrue(logger.entries.contains { $0.contains("user value takes precedence") })
    }
}
