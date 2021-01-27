//
//  SocketSideEffectTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/11/15.
//
//

import XCTest
@testable import SocketIO
import Starscream

class SocketSideEffectTest: XCTestCase {
    func testInitialCurrentAck() {
        XCTAssertEqual(socket.currentAck, -1)
    }

    func testFirstAck() {
        socket.emitWithAck("test").timingOut(after: 0) {data in}
        XCTAssertEqual(socket.currentAck, 0)
    }

    func testSecondAck() {
        socket.emitWithAck("test").timingOut(after: 0) {data in}
        socket.emitWithAck("test").timingOut(after: 0) {data in}

        XCTAssertEqual(socket.currentAck, 1)
    }

    func testEmitCompletionSyntax() {
        socket.emit("test", completion: {})
        socket.emit("test", "thing", completion: {})
    }

    func testHandleAck() {
        let expect = expectation(description: "handled ack")
        socket.emitWithAck("test").timingOut(after: 0) {data in
            XCTAssertEqual(data[0] as? String, "hello world")
            expect.fulfill()
        }

        manager.parseEngineMessage("30[\"hello world\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleAckWithAckEmit() {
        let expect = expectation(description: "handled ack")
        socket.emitWithAck("test").timingOut(after: 0) {data in
            XCTAssertEqual(data[0] as? String, "hello world")

            self.socket.emitWithAck("test").timingOut(after: 0) {data in}
            expect.fulfill()
        }

        manager.parseEngineMessage("30[\"hello world\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleAck2() {
        let expect = expectation(description: "handled ack2")
        socket.emitWithAck("test").timingOut(after: 0) {data in
            XCTAssertTrue(data.count == 2, "Wrong number of ack items")
            expect.fulfill()
        }

        manager.parseEngineMessage("61-0[{\"_placeholder\":true,\"num\":0},{\"test\":true}]")
        manager.parseEngineBinaryData(Data())
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleEvent() {
        let expect = expectation(description: "handled event")
        socket.on("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "hello world")
            expect.fulfill()
        }

        manager.parseEngineMessage("2[\"test\",\"hello world\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleStringEventWithQuotes() {
        let expect = expectation(description: "handled event")
        socket.on("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "\"hello world\"")
            expect.fulfill()
        }

        manager.parseEngineMessage("2[\"test\",\"\\\"hello world\\\"\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleOnceEvent() {
        let expect = expectation(description: "handled event")
        socket.once("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "hello world")
            XCTAssertEqual(self.socket.testHandlers.count, 0)
            expect.fulfill()
        }

        manager.parseEngineMessage("2[\"test\",\"hello world\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleOnceClientEvent() {
        let expect = expectation(description: "handled event")

        socket.setTestStatus(.connecting)

        socket.once(clientEvent: .connect) {data, ack in
            XCTAssertEqual(self.socket.testHandlers.count, 0)
            expect.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
            // Fake connecting
            self.manager.parseEngineMessage("0/")
        }

        waitForExpectations(timeout: 3, handler: nil)
    }

    func testOffWithEvent() {
        socket.on("test") {data, ack in }
        socket.on("test") {data, ack in }
        XCTAssertEqual(socket.testHandlers.count, 2)
        socket.off("test")
        XCTAssertEqual(socket.testHandlers.count, 0)
    }

    func testOffClientEvent() {
        socket.on(clientEvent: .connect) {data, ack in }
        socket.on(clientEvent: .disconnect) {data, ack in }
        XCTAssertEqual(socket.testHandlers.count, 2)
        socket.off(clientEvent: .disconnect)
        XCTAssertEqual(socket.testHandlers.count, 1)
        XCTAssertTrue(socket.testHandlers.contains(where: { $0.event == "connect" }))
    }

    func testOffWithId() {
        let handler = socket.on("test") {data, ack in }
        XCTAssertEqual(socket.testHandlers.count, 1)
        socket.on("test") {data, ack in }
        XCTAssertEqual(socket.testHandlers.count, 2)
        socket.off(id: handler)
        XCTAssertEqual(socket.testHandlers.count, 1)
    }

    func testHandlesErrorPacket() {
        let expect = expectation(description: "Handled error")
        socket.on("error") {data, ack in
            if let error = data[0] as? String, error == "test error" {
                expect.fulfill()
            }
        }

        manager.parseEngineMessage("4\"test error\"")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleBinaryEvent() {
        let expect = expectation(description: "handled binary event")
        socket.on("test") {data, ack in
            if let dict = data[0] as? [String: Any], let data = dict["test"] as? Data {
                XCTAssertEqual(data as Data, self.data)
                expect.fulfill()
            }
        }

        manager.parseEngineMessage("51-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0}}]")
        manager.parseEngineBinaryData(data)
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testHandleMultipleBinaryEvent() {
        let expect = expectation(description: "handled multiple binary event")
        socket.on("test") {data, ack in
            if let dict = data[0] as? [String: Any], let data = dict["test"] as? Data,
               let data2 = dict["test2"] as? Data {
                XCTAssertEqual(data as Data, self.data)
                XCTAssertEqual(data2 as Data, self.data2)
                expect.fulfill()
            }
        }

        manager.parseEngineMessage("52-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0},\"test2\":{\"_placeholder\":true,\"num\":1}}]")
        manager.parseEngineBinaryData(data)
        manager.parseEngineBinaryData(data2)
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testChangingStatusCallsStatusChangeHandler() {
        let expect = expectation(description: "The client should announce when the status changes")
        let statusChange = SocketIOStatus.connecting

        socket.on("statusChange") {data, ack in
            guard let status = data[0] as? SocketIOStatus else {
                XCTFail("Status should be one of the defined statuses")

                return
            }

            XCTAssertEqual(status, statusChange, "The status changed should be the one set")

            expect.fulfill()
        }

        socket.setTestStatus(statusChange)

        waitForExpectations(timeout: 0.2)
    }

    func testOnClientEvent() {
        let expect = expectation(description: "The client should call client event handlers")
        let event = SocketClientEvent.disconnect
        let closeReason = "testing"

        socket.on(clientEvent: event) {data, ack in
            guard let reason = data[0] as? String else {
                XCTFail("Client should pass data for client events")

                return
            }

            XCTAssertEqual(closeReason, reason, "The data should be what was sent to handleClientEvent")

            expect.fulfill()
        }

        socket.handleClientEvent(event, data: [closeReason])

        waitForExpectations(timeout: 0.2)
    }

    func testClientEventsAreBackwardsCompatible() {
        let expect = expectation(description: "The client should call old style client event handlers")
        let event = SocketClientEvent.disconnect
        let closeReason = "testing"

        socket.on("disconnect") {data, ack in
            guard let reason = data[0] as? String else {
                XCTFail("Client should pass data for client events")

                return
            }

            XCTAssertEqual(closeReason, reason, "The data should be what was sent to handleClientEvent")

            expect.fulfill()
        }

        socket.handleClientEvent(event, data: [closeReason])

        waitForExpectations(timeout: 0.2)
    }

    func testConnectTimesOutIfNotConnected() {
        let expect = expectation(description: "The client should call the timeout function")

        socket = manager.socket(forNamespace: "/someNamespace")
        socket.setTestStatus(.notConnected)
        manager.engine = TestEngine(client: manager, url: manager.socketURL, options: nil)

        socket.connect(timeoutAfter: 0.5, withHandler: {
            expect.fulfill()
        })

        waitForExpectations(timeout: 0.8)
    }

    func testConnectDoesNotTimeOutIfConnected() {
        let expect = expectation(description: "The client should not call the timeout function")

        socket.setTestStatus(.notConnected)
        manager.engine = TestEngine(client: manager, url: manager.socketURL, options: nil)

        socket.on(clientEvent: .connect) {data, ack in
            expect.fulfill()
        }

        socket.connect(timeoutAfter: 0.5, withHandler: {
            XCTFail("Should not call timeout handler if status is connected")
        })

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
            // Fake connecting
            self.manager.parseEngineMessage("0/")
        }

        waitForExpectations(timeout: 2)
    }

    func testClientCallsConnectOnEngineOpen() {
        let expect = expectation(description: "The client call the connect handler")
        let eng = TestEngine(client: manager, url: manager.socketURL, options: nil)

        eng.onConnect = {
            self.socket.didConnect(toNamespace: self.socket.nsp, payload: nil)
        }

        manager.engine = eng
        socket.setTestStatus(.notConnected)

        socket.on(clientEvent: .connect) {data, ack in
            expect.fulfill()
        }

        socket.connect(timeoutAfter: 0.5, withHandler: {
            XCTFail("Should not call timeout handler if status is connected")
        })

        waitForExpectations(timeout: 2)
    }

    func testConnectIsCalledWithNamespace() {
        let expect = expectation(description: "The client should not call the timeout function")
        let nspString = "/swift"

        socket = manager.socket(forNamespace: "/swift")
        socket.setTestStatus(.notConnected)
        manager.engine = TestEngine(client: manager, url: manager.socketURL, options: nil)

        socket.on(clientEvent: .connect) {data, ack in
            guard let nsp = data[0] as? String else {
                XCTFail("Connect should be called with a namespace")

                return
            }

            XCTAssertEqual(nspString, nsp, "It should connect with the correct namespace")

            expect.fulfill()
        }

        socket.connect(timeoutAfter: 0.3, withHandler: {
            XCTFail("Should not call timeout handler if status is connected")
        })

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
            // Fake connecting
            self.manager.parseEngineMessage("0/swift")
        }

        waitForExpectations(timeout: 2)
    }

    func testErrorInCustomSocketDataCallsErrorHandler() {
        let expect = expectation(description: "The client should call the error handler for emit errors because of " +
                                              "custom data")

        socket.on(clientEvent: .error) {data, ack in
            guard data.count == 3, data[0] as? String == "myEvent",
                  data[2] is ThrowingData.ThrowingError else {
                XCTFail("Incorrect error call")

                return
            }

            expect.fulfill()
        }

        socket.emit("myEvent", ThrowingData())

        waitForExpectations(timeout: 0.2)
    }

    func testErrorInCustomSocketDataCallsErrorHandler_ack() {
        let expect = expectation(description: "The client should call the error handler for emit errors because of " +
                                              "custom data")

        socket.on(clientEvent: .error) {data, ack in
            guard data.count == 3, data[0] as? String == "myEvent",
                  data[2] is ThrowingData.ThrowingError else {
                XCTFail("Incorrect error call")

                return
            }

            expect.fulfill()
        }

        socket.emitWithAck("myEvent", ThrowingData()).timingOut(after: 0.8, callback: {_ in
            XCTFail("Ack callback should not be called")
        })

        waitForExpectations(timeout: 0.2)
    }

    func testSettingConfigAfterInit() {
        socket.setTestStatus(.notConnected)
        manager.config.insert(.log(true))

        XCTAssertTrue(DefaultSocketLogger.Logger.log, "It should set logging to true after creation")

        manager.config = [.log(false)]

        XCTAssertFalse(DefaultSocketLogger.Logger.log, "It should set logging to false after creation")
    }

    func testSettingConfigAfterDisconnect() {
        socket.setTestStatus(.disconnected)
        manager.config.insert(.log(true))

        XCTAssertTrue(DefaultSocketLogger.Logger.log, "It should set logging to true after creation")

        manager.config = [.log(false)]

        XCTAssertFalse(DefaultSocketLogger.Logger.log, "It should set logging to false after creation")
    }

    func testSettingConfigAfterInitWhenConnectedDoesNotIgnoreChanges() {
        manager.setTestStatus(.connected)
        manager.config = [.log(true)]

        XCTAssertTrue(DefaultSocketLogger.Logger.log, "It should set logging to false after creation")
    }

    func testClientCallsSentPingHandler() {
        let expect = expectation(description: "The client should emit a ping event")

        socket.on(clientEvent: .pong) {data, ack in
            expect.fulfill()
        }

        manager.engineDidSendPong()

        waitForExpectations(timeout: 0.2)
    }

    func testClientCallsGotPongHandler() {
        let expect = expectation(description: "The client should emit a pong event")

        socket.on(clientEvent: .ping) {data, ack in
            expect.fulfill()
        }

        manager.engineDidReceivePing()

        waitForExpectations(timeout: 0.2)
    }

    let data = "test".data(using: String.Encoding.utf8)!
    let data2 = "test2".data(using: String.Encoding.utf8)!

    private var manager: SocketManager!
    private var socket: SocketIOClient!

    override func setUp() {
        super.setUp()

        manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestable()
    }
}

struct ThrowingData: SocketData {
    enum ThrowingError : Error {
        case error
    }

    func socketRepresentation() throws -> SocketData {
        throw ThrowingError.error
    }

}

class TestEngine: SocketEngineSpec {
    weak var client: SocketEngineClient?
    private(set) var closed = false
    private(set) var compress = false
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
    private(set) var websocket = false
    private(set) var ws: WebSocket? = nil
    private(set) var version = SocketIOVersion.three

    fileprivate var onConnect: (() -> ())?

    required init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.client = client
    }

    func connect() {
        onConnect?()
    }

    func didError(reason: String) { }
    func disconnect(reason: String) { }
    func doFastUpgrade() { }
    func flushWaitingForPostToWebSocket() { }
    func parseEngineData(_ data: Data) { }
    func parseEngineMessage(_ message: String) { }
    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) { }
}
