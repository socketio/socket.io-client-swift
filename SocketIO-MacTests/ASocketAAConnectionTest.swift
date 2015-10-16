//
//  SocketConnectionTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 15.10.15.
//
//

import XCTest

class AASocketAAConnectionTest: XCTestCase {
    
    func testAConnectRegularSocket() {
        weak var expection = expectationWithDescription("connectNormal")
        openConnection(AbstractSocketTest.regularSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testAConnectNamespaceSocket() {
        weak var expection = expectationWithDescription("connectNormalNamespace")
        openConnection(AbstractSocketTest.namespaceSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testAConnectAckSocket() {
        weak var expection = expectationWithDescription("connectAck")
        openConnection(AbstractSocketTest.regularAckSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testAConnectAckNamespaceSocket() {
        weak var expection = expectationWithDescription("connectNormalAckNamespace")
        openConnection(AbstractSocketTest.namespaceAckSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testAConnectPollingSocket() {
        weak var expection = expectationWithDescription("connectPolling")
        openConnection(AbstractSocketTest.regularPollingSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testAConnectPollingNamespaceSocket() {
        weak var expection = expectationWithDescription("connectPollingNamesapce")
        openConnection(AbstractSocketTest.namespacePollingSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testAConnectPollingeAck() {
        weak var expection = expectationWithDescription("connectPollingAck")
        openConnection(AbstractSocketTest.regularPollingAckSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testAConnectPollingNamesapceAck() {
        weak var expection = expectationWithDescription("connectPollingNamesapceAck")
        openConnection(AbstractSocketTest.namespacePollingAckSocket) {
            expection?.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func openConnection(socket: SocketIOClient, isConnectedCallback:()->()) {
        if socket.status == .Connected {
            isConnectedCallback()
        }
        socket.on("connect") {data, ack in
            XCTAssertEqual(socket.status, SocketIOClientStatus.Connected)
            XCTAssertFalse(socket.secure)
            isConnectedCallback()
        }
        socket.connect()
    }
}
