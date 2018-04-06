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
        XCTAssertEqual(manager.status, .notConnected)
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

    func testManagerEmitAll() {
        setUpSockets()

        socket.expectations[ManagerExpectation.emitAllEventCalled] = expectation(description: "The manager should emit an event to the default socket")
        socket2.expectations[ManagerExpectation.emitAllEventCalled] = expectation(description: "The manager should emit an event to the socket")

        socket2.on(clientEvent: .connect) {data, ack in
            self.manager.emitAll("event", "testing")
        }

        socket.connect()
        socket2.connect()

        manager.fakeConnecting()
        manager.fakeConnecting(toNamespace: "/swift")

        waitForExpectations(timeout: 0.3)
    }

    func testManagerSetsConfigs() {
        let queue = DispatchQueue(label: "testQueue")

        manager = TestManager(socketURL: URL(string: "http://localhost/")!, config: [
            .handleQueue(queue),
            .forceNew(true),
            .reconnects(false),
            .reconnectWait(5),
            .reconnectAttempts(5)
        ])

        XCTAssertEqual(manager.handleQueue, queue)
        XCTAssertTrue(manager.forceNew)
        XCTAssertFalse(manager.reconnects)
        XCTAssertEqual(manager.reconnectWait, 5)
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

public enum ManagerExpectation : String {
    case didConnectCalled
    case didDisconnectCalled
    case emitAllEventCalled
}

public class TestManager : SocketManager {
    public override func disconnect() {
        setTestStatus(.disconnected)
    }

    @objc
    public func testSocket(forNamespace nsp: String) -> TestSocket {
        return socket(forNamespace: nsp) as! TestSocket
    }

    @objc
    public func fakeConnecting(toNamespace nsp: String) {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
            // Fake connecting
            self.parseEngineMessage("0\(nsp)")
        }
    }

    @objc
    public func fakeDisconnecting() {
        engineDidClose(reason: "")
    }

    @objc
    public func fakeConnecting() {
        engineDidOpen(reason: "")
    }

    public override func socket(forNamespace nsp: String) -> SocketIOClient {
        // set socket to our test socket, the superclass method will get this from nsps
        nsps[nsp] = TestSocket(manager: self, nsp: nsp)

        return super.socket(forNamespace: nsp)
    }
}

public class TestSocket : SocketIOClient {
    public var expectations = [ManagerExpectation: XCTestExpectation]()

    @objc
    public var expects =  NSMutableDictionary()

    public override func didConnect(toNamespace nsp: String) {
        expectations[ManagerExpectation.didConnectCalled]?.fulfill()
        expectations[ManagerExpectation.didConnectCalled] = nil

        if let expect = expects[ManagerExpectation.didConnectCalled.rawValue] as? XCTestExpectation {
            expect.fulfill()
            expects[ManagerExpectation.didConnectCalled.rawValue] = nil
        }

        super.didConnect(toNamespace: nsp)
    }

    public override func didDisconnect(reason: String) {
        expectations[ManagerExpectation.didDisconnectCalled]?.fulfill()
        expectations[ManagerExpectation.didDisconnectCalled] = nil

        if let expect = expects[ManagerExpectation.didDisconnectCalled.rawValue] as? XCTestExpectation {
            expect.fulfill()
            expects[ManagerExpectation.didDisconnectCalled.rawValue] = nil
        }

        super.didDisconnect(reason: reason)
    }

    public override func emit(_ event: String, with items: [Any]) {
        expectations[ManagerExpectation.emitAllEventCalled]?.fulfill()
        expectations[ManagerExpectation.emitAllEventCalled] = nil

        if let expect = expects[ManagerExpectation.emitAllEventCalled.rawValue] as? XCTestExpectation {
            expect.fulfill()
            expects[ManagerExpectation.emitAllEventCalled.rawValue] = nil
        }
    }
}
