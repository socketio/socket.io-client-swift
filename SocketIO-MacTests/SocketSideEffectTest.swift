//
//  SocketSideEffectTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/11/15.
//
//

import XCTest
@testable import SocketIO

class SocketSideEffectTest: XCTestCase {
    let data = "test".data(using: String.Encoding.utf8)!
    let data2 = "test2".data(using: String.Encoding.utf8)!
    private var socket: SocketIOClient!
    
    override func setUp() {
        super.setUp()
        socket = SocketIOClient(socketURL: URL(string: "http://localhost/")!)
        socket.setTestable()
    }
    
    func testInitialCurrentAck() {
        XCTAssertEqual(socket.currentAck, -1)
    }
    
    func testFirstAck() {
        socket.emitWithAck("test")(0) {data in}
        XCTAssertEqual(socket.currentAck, 0)
    }
    
    func testSecondAck() {
        socket.emitWithAck("test")(0) {data in}
        socket.emitWithAck("test")(0) {data in}
        
        XCTAssertEqual(socket.currentAck, 1)
    }
    
    func testHandleAck() {
        let expect = expectation(description: "handled ack")
        socket.emitWithAck("test")(0) {data in
            XCTAssertEqual(data[0] as? String, "hello world")
            expect.fulfill()
        }
        
        socket.parseSocketMessage("30[\"hello world\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }
    
    func testHandleAck2() {
        let expect = expectation(description: "handled ack2")
        socket.emitWithAck("test")(0) {data in
            XCTAssertTrue(data.count == 2, "Wrong number of ack items")
            expect.fulfill()
        }
        
        socket.parseSocketMessage("61-0[{\"_placeholder\":true,\"num\":0},{\"test\":true}]")
        socket.parseBinaryData(Data())
        waitForExpectations(timeout: 3, handler: nil)
    }
    
    func testHandleEvent() {
        let expect = expectation(description: "handled event")
        socket.on("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "hello world")
            expect.fulfill()
        }
        
        socket.parseSocketMessage("2[\"test\",\"hello world\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }
    
    func testHandleStringEventWithQuotes() {
        let expect = expectation(description: "handled event")
        socket.on("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "\"hello world\"")
            expect.fulfill()
        }
        
        socket.parseSocketMessage("2[\"test\",\"\\\"hello world\\\"\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }
    
    func testHandleOnceEvent() {
        let expect = expectation(description: "handled event")
        socket.once("test") {data, ack in
            XCTAssertEqual(data[0] as? String, "hello world")
            XCTAssertEqual(self.socket.testHandlers.count, 0)
            expect.fulfill()
        }
        
        socket.parseSocketMessage("2[\"test\",\"hello world\"]")
        waitForExpectations(timeout: 3, handler: nil)
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
        let expect = expectation(description: "Handled error")
        socket.on("error") {data, ack in
            if let error = data[0] as? String, error == "test error" {
                expect.fulfill()
            }
        }
        
        socket.parseSocketMessage("4\"test error\"")
        waitForExpectations(timeout: 3, handler: nil)
    }
    
    func testHandleBinaryEvent() {
        let expect = expectation(description: "handled binary event")
        socket.on("test") {data, ack in
            if let dict = data[0] as? NSDictionary, let data = dict["test"] as? NSData {
                XCTAssertEqual(data as Data, self.data)
                expect.fulfill()
            }
        }
        
        socket.parseSocketMessage("51-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0}}]")
        socket.parseBinaryData(data)
        waitForExpectations(timeout: 3, handler: nil)
    }
    
    func testHandleMultipleBinaryEvent() {
        let expect = expectation(description: "handled multiple binary event")
        socket.on("test") {data, ack in
            if let dict = data[0] as? NSDictionary, let data = dict["test"] as? NSData,
                let data2 = dict["test2"] as? NSData {
                    XCTAssertEqual(data as Data, self.data)
                    XCTAssertEqual(data2 as Data, self.data2)
                    expect.fulfill()
            }
        }
        
        socket.parseSocketMessage("52-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0},\"test2\":{\"_placeholder\":true,\"num\":1}}]")
        socket.parseBinaryData(data)
        socket.parseBinaryData(data2)
        waitForExpectations(timeout: 3, handler: nil)
    }
    
    func testSocketManager() {
        let manager = SocketClientManager.sharedManager
        manager["test"] = socket
        
        XCTAssert(manager["test"] === socket, "failed to get socket")
        
        manager["test"] = nil
        
        XCTAssert(manager["test"] == nil, "socket not removed")

    }
}
