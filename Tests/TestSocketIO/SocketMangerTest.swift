//
// Created by Erik Little on 10/21/17.
//

import Dispatch
import Foundation
@testable import SocketIO
import XCTest

class SocketMangerTest : XCTestCase {
    func testManagerProperties() {
        XCTAssertNotNil(manager.defaultSocket)
        XCTAssertNil(manager.engine)
        XCTAssertFalse(manager.forceNew)
        XCTAssertEqual(manager.handleQueue, DispatchQueue.main)
        XCTAssertTrue(manager.reconnects)
        XCTAssertEqual(manager.reconnectWait, 10)
        XCTAssertEqual(manager.reconnectWaitMax, 30)
        XCTAssertEqual(manager.randomizationFactor, 0.5)
        XCTAssertEqual(manager.status, .notConnected)
    }

    func testSettingConfig() {
        let manager = SocketManager(socketURL: URL(string: "https://example.com/")!)

        XCTAssertEqual(manager.config.first!, .secure(true))

        manager.config = []

        XCTAssertEqual(manager.config.first!, .secure(true))
    }

    func testBackoffIntervalCalulation() {
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: -1), Double(manager.reconnectWaitMax))
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 0), 15)
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 1), 22.5)
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 2), 33.75)
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 50), Double(manager.reconnectWaitMax))
        XCTAssertLessThanOrEqual(manager.reconnectInterval(attempts: 10000), Double(manager.reconnectWaitMax))

        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: -1), Double(manager.reconnectWait))
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 0), Double(manager.reconnectWait))
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 1), 15)
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 2), 22.5)
        XCTAssertGreaterThanOrEqual(manager.reconnectInterval(attempts: 10000), Double(manager.reconnectWait))
    }

    func testManagerCallsConnect() {
        setUpSockets()

        socket.expectations[ManagerExpectation.didConnectCalled] = expectation(description: "The manager should call connect on the default socket")
        socket2.expectations[ManagerExpectation.didConnectCalled] = expectation(description: "The manager should call connect on the socket")

        socket.connect()
        socket2.connect()

        manager.fakeConnecting()
        manager.fakeConnecting(toNamespace: "/swift")

        waitForExpectations(timeout: 0.3)
    }

    func testManagerCallsDisconnect() {
        setUpSockets()

        socket.expectations[ManagerExpectation.didDisconnectCalled] = expectation(description: "The manager should call disconnect on the default socket")
        socket2.expectations[ManagerExpectation.didDisconnectCalled] = expectation(description: "The manager should call disconnect on the socket")

        socket2.on(clientEvent: .connect) {data, ack in
            self.manager.disconnect()
            self.manager.fakeDisconnecting()
        }

        socket.connect()
        socket2.connect()

        manager.fakeConnecting()
        manager.fakeConnecting(toNamespace: "/swift")

        waitForExpectations(timeout: 0.3)
    }

//    func testManagerEmitAll() {
//        setUpSockets()
//
//        socket.expectations[ManagerExpectation.emitAllEventCalled] = expectation(description: "The manager should emit an event to the default socket")
//        socket2.expectations[ManagerExpectation.emitAllEventCalled] = expectation(description: "The manager should emit an event to the socket")
//
//        socket2.on(clientEvent: .connect) {data, ack in
//            print("connect")
//            self.manager.emitAll("event", "testing")
//        }
//
//        socket.connect()
//        socket2.connect()
//
//        manager.fakeConnecting(toNamespace: "/swift")
//
//        waitForExpectations(timeout: 0.3)
//    }

    func testManagerSetsConfigs() {
        let queue = DispatchQueue(label: "testQueue")

        manager = TestManager(socketURL: URL(string: "http://localhost/")!, config: [
            .handleQueue(queue),
            .forceNew(true),
            .reconnects(false),
            .reconnectWait(5),
            .reconnectWaitMax(5),
            .randomizationFactor(0.7),
            .reconnectAttempts(5)
        ])

        XCTAssertEqual(manager.handleQueue, queue)
        XCTAssertTrue(manager.forceNew)
        XCTAssertFalse(manager.reconnects)
        XCTAssertEqual(manager.reconnectWait, 5)
        XCTAssertEqual(manager.reconnectWaitMax, 5)
        XCTAssertEqual(manager.randomizationFactor, 0.7)
        XCTAssertEqual(manager.reconnectAttempts, 5)
    }

    func testManagerRemovesSocket() {
        setUpSockets()

        manager.removeSocket(socket)

        XCTAssertNil(manager.nsps[socket.nsp])
    }

    private func setUpSockets() {
        socket = manager.testSocket(forNamespace: "/")
        socket2 = manager.testSocket(forNamespace: "/swift")
    }

    private var manager: TestManager!
    private var socket: TestSocket!
    private var socket2: TestSocket!

    override func setUp() {
        super.setUp()

        manager = TestManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false)])
        socket = nil
        socket2 = nil
    }
}

public enum ManagerExpectation: String {
    case didConnectCalled
    case didDisconnectCalled
    case emitAllEventCalled
}

public class TestManager: SocketManager {
    public override func disconnect() {
        setTestStatus(.disconnected)
    }

    public func testSocket(forNamespace nsp: String) -> TestSocket {
        return socket(forNamespace: nsp) as! TestSocket
    }

    public func fakeDisconnecting() {
        engineDidClose(reason: "")
    }

    public func fakeConnecting(toNamespace nsp: String = "/") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Fake connecting
            self.parseEngineMessage("0\(nsp)")
        }
    }

    public override func socket(forNamespace nsp: String) -> SocketIOClient {
        // set socket to our test socket, the superclass method will get this from nsps
        nsps[nsp] = TestSocket(manager: self, nsp: nsp)

        return super.socket(forNamespace: nsp)
    }
}

public class TestSocket: SocketIOClient {
    public var expectations = [ManagerExpectation: XCTestExpectation]()

    public override func didConnect(toNamespace nsp: String, payload: [String: Any]?) {
        expectations[ManagerExpectation.didConnectCalled]?.fulfill()
        expectations[ManagerExpectation.didConnectCalled] = nil

        super.didConnect(toNamespace: nsp, payload: payload)
    }

    public override func didDisconnect(reason: String) {
        expectations[ManagerExpectation.didDisconnectCalled]?.fulfill()
        expectations[ManagerExpectation.didDisconnectCalled] = nil

        super.didDisconnect(reason: reason)
    }

    public override func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil) {
        expectations[ManagerExpectation.emitAllEventCalled]?.fulfill()
        expectations[ManagerExpectation.emitAllEventCalled] = nil
    }
}
