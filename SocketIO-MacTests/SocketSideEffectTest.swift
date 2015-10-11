//
//  SocketSideEffectTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/11/15.
//
//

import XCTest

class SocketSideEffectTest: XCTestCase {
    private var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        socket = SocketIOClient(socketURL: "")
        socket.setTestable()
    }
    
    func testInitialCurrentAck() {
        XCTAssertEqual(socket.currentAck, -1)
    }
    
    func testFirstAck() {
        socket.emitWithAck("test")(timeoutAfter: 0) {data in}
        XCTAssertEqual(socket.currentAck, 0)
    }
    
    func testSecondAck() {
        socket.emitWithAck("test")(timeoutAfter: 0) {data in}
        socket.emitWithAck("test")(timeoutAfter: 0) {data in}

        XCTAssertEqual(self.socket.currentAck, 1)
    }
    
    func testHandleAck() {
        let expectation = expectationWithDescription("handled ack")
        socket.emitWithAck("test")(timeoutAfter: 0) {data in
            XCTAssertEqual(data[0] as? String, "hello world")
            expectation.fulfill()
        }
        
        socket.handleAck(0, data: ["hello world"])
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testHandleEvent() {
        let expectation = expectationWithDescription("handled event")
        socket.on("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "hello world")
            expectation.fulfill()
        }
        
        socket.parseSocketMessage("2[\"test\",\"hello world\"]")
        waitForExpectationsWithTimeout(3, handler: nil)
    }
}
