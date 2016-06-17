//
//  SocketSideEffectTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/11/15.
//
//

import XCTest
@testable import SocketIOClientSwift

class SocketSideEffectTest: XCTestCase {
    let data = "test".dataUsingEncoding(NSUTF8StringEncoding)!
    let data2 = "test2".dataUsingEncoding(NSUTF8StringEncoding)!
    private var socket: SocketIOClient!
    
    override func setUp() {
        super.setUp()
        socket = SocketIOClient(socketURL: NSURL())
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
        
        XCTAssertEqual(socket.currentAck, 1)
    }
    
    func testHandleAck() {
        let expectation = expectationWithDescription("handled ack")
        socket.emitWithAck("test")(timeoutAfter: 0) {data in
            XCTAssertEqual(data[0] as? String, "hello world")
            expectation.fulfill()
        }
        
        socket.parseSocketMessage("30[\"hello world\"]")
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testHandleAck2() {
        let expectation = expectationWithDescription("handled ack2")
        socket.emitWithAck("test")(timeoutAfter: 0) {data in
            XCTAssertTrue(data.count == 2, "Wrong number of ack items")
            expectation.fulfill()
        }
        
        socket.parseSocketMessage("61-0[{\"_placeholder\":true,\"num\":0},{\"test\":true}]")
        socket.parseBinaryData(NSData())
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
    
    func testHandleStringEventWithQuotes() {
        let expectation = expectationWithDescription("handled event")
        socket.on("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "\"hello world\"")
            expectation.fulfill()
        }
        
        socket.parseSocketMessage("2[\"test\",\"\\\"hello world\\\"\"]")
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testHandleOnceEvent() {
        let expectation = expectationWithDescription("handled event")
        socket.once("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "hello world")
            XCTAssertEqual(self.socket.testHandlers.count, 0)
            expectation.fulfill()
        }
        
        socket.parseSocketMessage("2[\"test\",\"hello world\"]")
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testOffWithEvent() {
        socket.on("test") {data, ack in }
        XCTAssertEqual(socket.testHandlers.count, 1)
        socket.on("test") {data, ack in }
        XCTAssertEqual(socket.testHandlers.count, 2)
        socket.off("test")
        XCTAssertEqual(socket.testHandlers.count, 0)
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
        let expectation = expectationWithDescription("Handled error")
        socket.on("error") {data, ack in
            if let error = data[0] as? String where error == "test error" {
                expectation.fulfill()
            }
        }
        
        socket.parseSocketMessage("4\"test error\"")
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testHandleBinaryEvent() {
        let expectation = expectationWithDescription("handled binary event")
        socket.on("test") {data, ack in
            if let dict = data[0] as? NSDictionary, data = dict["test"] as? NSData {
                XCTAssertEqual(data, self.data)
                expectation.fulfill()
            }
        }
        
        socket.parseSocketMessage("51-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0}}]")
        socket.parseBinaryData(data)
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testHandleMultipleBinaryEvent() {
        let expectation = expectationWithDescription("handled multiple binary event")
        socket.on("test") {data, ack in
            if let dict = data[0] as? NSDictionary, data = dict["test"] as? NSData,
                data2 = dict["test2"] as? NSData {
                    XCTAssertEqual(data, self.data)
                    XCTAssertEqual(data2, self.data2)
                    expectation.fulfill()
            }
        }
        
        socket.parseSocketMessage("52-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0},\"test2\":{\"_placeholder\":true,\"num\":1}}]")
        socket.parseBinaryData(data)
        socket.parseBinaryData(data2)
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testSocketManager() {
        let manager = SocketClientManager.sharedManager
        manager["test"] = socket
        
        XCTAssert(manager["test"] === socket, "failed to get socket")
        
        manager["test"] = nil
        
        XCTAssert(manager["test"] == nil, "socket not removed")

    }
}
