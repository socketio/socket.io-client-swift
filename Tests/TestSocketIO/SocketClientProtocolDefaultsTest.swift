import Foundation
import XCTest
@testable import SocketIO

/// A third-party protocol conformer inherits the extension defaults rather than
/// SocketIOClient's overrides. All required operations use the real client.
private final class DefaultContractClient: SocketIOClientSpec {
    let backing: SocketIOClient
    init(_ backing: SocketIOClient) { self.backing = backing }
    var anyHandler: ((SocketAnyEvent) -> ())? { backing.anyHandler }
    var handlers: [SocketEventHandler] { backing.handlers }
    var manager: SocketManagerSpec? { backing.manager }
    var nsp: String { backing.nsp }
    var rawEmitView: SocketRawView { backing.rawEmitView }
    var sid: String? { backing.sid }
    var status: SocketIOStatus { backing.status }
    func connect(withPayload payload: [String: Any]?) { backing.connect(withPayload: payload) }
    func connect(withPayload payload: [String: Any]?, timeoutAfter: Double, withHandler handler: (() -> ())?) { backing.connect(withPayload: payload, timeoutAfter: timeoutAfter, withHandler: handler) }
    func didConnect(toNamespace namespace: String, payload: [String: Any]?) { backing.didConnect(toNamespace: namespace, payload: payload) }
    func didDisconnect(reason: String) { backing.didDisconnect(reason: reason) }
    func disconnect() { backing.disconnect() }
    func emit(_ event: String, _ items: SocketData..., completion: (() -> ())?) { backing.emit(event, with: items, completion: completion) }
    func emit(_ event: String, with items: [SocketData], completion: (() -> ())?) { backing.emit(event, with: items, completion: completion) }
    func emitAck(_ ack: Int, with items: [Any]) { backing.emitAck(ack, with: items) }
    func emitWithAck(_ event: String, _ items: SocketData...) -> OnAckCallback { backing.emitWithAck(event, with: items) }
    func emitWithAck(_ event: String, with items: [SocketData]) -> OnAckCallback { backing.emitWithAck(event, with: items) }
    func handleAck(_ ack: Int, data: [Any]) { backing.handleAck(ack, data: data) }
    func handleClientEvent(_ event: SocketClientEvent, data: [Any]) { backing.handleClientEvent(event, data: data) }
    func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int) { backing.handleEvent(event, data: data, isInternalMessage: isInternalMessage, withAck: ack) }
    func handlePacket(_ packet: SocketPacket) { backing.handlePacket(packet) }
    func leaveNamespace() { backing.leaveNamespace() }
    func joinNamespace(withPayload payload: [String: Any]?) { backing.joinNamespace(withPayload: payload) }
    func off(clientEvent event: SocketClientEvent) { backing.off(clientEvent: event) }
    func off(_ event: String) { backing.off(event) }
    func off(id: UUID) { backing.off(id: id) }
    func on(_ event: String, callback: @escaping NormalCallback) -> UUID { backing.on(event, callback: callback) }
    func on(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID { backing.on(clientEvent: event, callback: callback) }
    func once(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID { backing.once(clientEvent: event, callback: callback) }
    func once(_ event: String, callback: @escaping NormalCallback) -> UUID { backing.once(event, callback: callback) }
    func onAny(_ handler: @escaping (SocketAnyEvent) -> ()) { backing.onAny(handler) }
    func removeAllHandlers() { backing.removeAllHandlers() }
    func setReconnecting(reason: String) { backing.setReconnecting(reason: reason) }
}

final class SocketClientProtocolDefaultsTest: XCTestCase {
    func testCustomClientSendOverloadsPreservePayloadCompletionsAndAcknowledgements() throws {
        let queue = DispatchQueue(label: "client.protocol-defaults")
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.handleQueue(queue)])
        let engine = MockEngine()
        manager.engine = engine
        let backing = manager.defaultSocket
        let socket: SocketIOClientSpec = DefaultContractClient(backing)
        defer { queue.sync { manager.disconnect() } }
        let completed = expectation(description: "write completions")
        completed.expectedFulfillmentCount = 2
        try queue.sync {
            manager.setTestStatus(.connected)
            backing.setTestStatus(.connected)
            var replies: [String] = []
            socket.send("one", 1) { completed.fulfill() }
            socket.send(with: ["two", 2]) { completed.fulfill() }
            socket.sendWithAck("three", 3).timingOut(after: 0) { replies.append($0[0] as! String) }
            socket.sendWithAck(with: ["four", 4]).timingOut(after: 0) { replies.append($0[0] as! String) }
            XCTAssertEqual(engine.sentPackets.count, 4)
            let packets = try engine.sentPackets.map { try manager.parseString($0.0) }
            for (index, name) in ["one", "two", "three", "four"].enumerated() {
                XCTAssertEqual(packets[index].data as NSArray, ["message", name, index + 1] as NSArray)
            }
            XCTAssertNotEqual(packets[2].id, packets[3].id)
            socket.handleAck(packets[2].id, data: ["third reply"])
            socket.handleAck(packets[3].id, data: ["fourth reply"])
            XCTAssertEqual(replies, ["third reply", "fourth reply"])
            XCTAssertFalse(socket.recovered)
        }
        wait(for: [completed], timeout: 1)
    }

    func testCustomClientDefaultErrorIsLoggedAndDeliveredToErrorListener() {
        let queue = DispatchQueue(label: "client.protocol-error")
        let logger = CoverageRecordingLogger()
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                    config: [.handleQueue(queue), .logger(logger), .log(true)])
        defer { queue.sync { manager.disconnect() }; DefaultSocketLogger.Logger = DefaultSocketLogger() }
        let socket: SocketIOClientSpec = DefaultContractClient(manager.defaultSocket)
        queue.sync {
            var reasons: [String] = []
            _ = socket.on(clientEvent: .error) { data, _ in reasons.append(data[0] as! String) }
            socket.didError(reason: "custom failure")
            XCTAssertEqual(reasons, ["custom failure"])
            XCTAssertTrue(logger.entries.contains { $0.contains("custom failure") })
        }
    }
}
