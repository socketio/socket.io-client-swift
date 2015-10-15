//
//  SocketConnectionTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 15.10.15.
//
//

import XCTest

class AASocketConnectionTest: AbstractSocketTest {
    
    func testConnectRegularSocket() {
        let expection = expectationWithDescription("connectNormal")
        openConnection(AbstractSocketTest.regularSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testConnectNamespaceSocket() {
        let expection = expectationWithDescription("connectNormalNamespace")
        openConnection(AbstractSocketTest.namespaceSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testConnectAckSocket() {
        let expection = expectationWithDescription("connectAck")
        openConnection(AbstractSocketTest.regularAckSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testConnectAckNamespaceSocket() {
        let expection = expectationWithDescription("connectNormalAckNamespace")
        openConnection(AbstractSocketTest.namespaceAckSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testConnectPollingSocket() {
        let expection = expectationWithDescription("connectPolling")
        openConnection(AbstractSocketTest.regularPollingSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testConnectPollingNamespaceSocket() {
        let expection = expectationWithDescription("connectPollingNamesapce")
        openConnection(AbstractSocketTest.namespacePollingSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testConnectPollingeAck() {
        let expection = expectationWithDescription("connectPollingAck")
        openConnection(AbstractSocketTest.regularPollingAckSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func testConnectPollingNamesapceAck() {
        let expection = expectationWithDescription("connectPollingNamesapceAck")
        openConnection(AbstractSocketTest.namespacePollingAckSocket) {
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func openConnection(socket: SocketIOClient, isConnectedCallback:()->()) {
        if socket.status == .Connected {
            return
        }
        socket.on("connect") {data, ack in
            XCTAssertEqual(socket.status, SocketIOClientStatus.Connected)
            XCTAssertFalse(socket.secure)
            isConnectedCallback()
        }
        socket.connect()
    }
}
