import Foundation
import XCTest
@testable import SocketIO

private final class DefaultContractManager: NSObject, SocketManagerSpec {
    let backing: SocketManager
    var disconnected: [SocketIOClient] = []
    init(_ backing: SocketManager) { self.backing = backing }
    var defaultSocket: SocketIOClient { get { backing.defaultSocket } }
    var engine: SocketEngineSpec? { get { backing.engine } set { backing.engine = newValue } }
    var forceNew: Bool { get { backing.forceNew } set { backing.forceNew = newValue } }
    var handleQueue: DispatchQueue { get { backing.handleQueue } set { backing.handleQueue = newValue } }
    var nsps: [String: SocketIOClient] { get { backing.nsps } set { backing.nsps = newValue } }
    var reconnects: Bool { get { backing.reconnects } set { backing.reconnects = newValue } }
    var reconnectWait: Int { get { backing.reconnectWait } set { backing.reconnectWait = newValue } }
    var reconnectWaitMax: Int { get { backing.reconnectWaitMax } set { backing.reconnectWaitMax = newValue } }
    var randomizationFactor: Double { get { backing.randomizationFactor } set { backing.randomizationFactor = newValue } }
    var socketURL: URL { get { backing.socketURL } }
    var status: SocketIOStatus { get { backing.status } }
    func connect() { backing.connect() }
    func connectSocket(_ socket: SocketIOClient, withPayload: [String: Any]?) { backing.connectSocket(socket, withPayload: withPayload) }
    func didDisconnect(reason: String) { backing.didDisconnect(reason: reason) }
    func disconnect() { backing.disconnect() }
    func disconnectSocket(_ socket: SocketIOClient) { disconnected.append(socket); backing.disconnectSocket(socket) }
    func disconnectSocket(forNamespace nsp: String) { backing.disconnectSocket(forNamespace: nsp) }
    func emitAll(_ event: String, _ items: SocketData...) { backing.nsps.values.forEach { $0.emit(event, with: items, completion: nil) } }
    func reconnect() { backing.reconnect() }
    func removeSocket(_ socket: SocketIOClient) -> SocketIOClient? { backing.removeSocket(socket) }
    func socket(forNamespace nsp: String) -> SocketIOClient { backing.socket(forNamespace: nsp) }
    func engineDidError(reason: String) { backing.engineDidError(reason: reason) }
    func engineDidClose(reason: String) { backing.engineDidClose(reason: reason) }
    func engineDidOpen(reason: String) { backing.engineDidOpen(reason: reason) }
    func engineDidReceivePing() { backing.engineDidReceivePing() }
    func engineDidReceivePong() { backing.engineDidReceivePong() }
    func engineDidSendPong() { backing.engineDidSendPong() }
    func parseEngineMessage(_ msg: String) { backing.parseEngineMessage(msg) }
    func parseEngineBinaryData(_ data: Data) { backing.parseEngineBinaryData(data) }
    func engineDidWebsocketUpgrade(headers: [String: String]) { backing.engineDidWebsocketUpgrade(headers: headers) }
}

final class SocketManagerProtocolDefaultsTest: XCTestCase {
    func testCustomManagerRetainsParserDefaultsAndReceivesNamespaceLeave() {
        let queue = DispatchQueue(label: "manager.protocol-defaults")
        let backing = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.handleQueue(queue)])
        let manager = DefaultContractManager(backing)
        let socket = SocketIOClient(manager: manager, nsp: "/custom")
        queue.sync {
            XCTAssertEqual(manager.parserOptions.maximumAttachments, 10)
            XCTAssertEqual(manager.parserOptions.maximumNestingDepth, 512)
            XCTAssertEqual(manager.parserOptions.maximumBinaryPacketBytes, .max)
            XCTAssertEqual(manager.parserOptions.maximumTextPacketBytes, .max)
            socket.setTestStatus(.connected)
            socket.leaveNamespace()
            XCTAssertEqual(manager.disconnected.count, 1)
            XCTAssertTrue(manager.disconnected.first === socket)
            XCTAssertEqual(socket.status, .disconnected)
        }
    }
}
