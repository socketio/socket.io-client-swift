//
//  SocketAcknowledgementTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 27.07.15.
//
//

import XCTest

class SocketAcknowledgementTest: SocketEmitTest {
    override func setUp() {
        super.setUp()
        testKind = TestKind.Acknowledgement
        socket = SocketIOClient(socketURL: "127.0.0.1:8080", opts: [
            "reconnects": true, // default true
            "reconnectAttempts": -1, // default -1
            "reconnectWait": 5, // default 10
            "forcePolling": false,
            "forceWebsockets": false,// default false
            "path": "",
            "extraHeaders": headers])
        openConnection()
    }
    
    override func testConnectionStatus() {
        super.testConnectionStatus()
    }
    
    override func testEmit() {
        super.testEmit()
    }
    
    override func testEmitNull() {
        super.testEmitNull()
    }
    
    override func testEmitBinary() {
        super.testEmitBinary()
    }
    
    override func testArrayEmit() {
        super.testArrayEmit()
    }
    
    override func testStringEmit() {
        super.testStringEmit()
    }
    
    override func testBoolEmit() {
        super.testBoolEmit()
    }
    
    override func testIntegerEmit() {
        super.testIntegerEmit()
    }
    
    override func testDoubleEmit() {
        super.testDoubleEmit()
    }
    
    override func testJSONEmit() {
        super.testJSONEmit()
    }
    
    func testJSONWithoutBuffer() {
        SocketTestCases.testJSONEmit(abstractSocketEmit, testKind: self.testKind)
    }
    
    override func testUnicodeEmit() {
        super.testUnicodeEmit()
    }
    
    override func testMultipleItemsEmit() {
        super.testMultipleItemsEmit()
    }
    
    override func abstractSocketMultipleEmit(testName:String, emitData:Array<AnyObject>, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        let expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:NSArray?) {
            callback(result, nil)
            expection.fulfill()
        }
        
        socket.emitWithAck(finalTestname, withItems: emitData)(timeoutAfter: 5, callback: didGetEmit)
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
        
    }
    
    override func abstractSocketEmit(testName:String, emitData:AnyObject?, callback:NormalCallback){
        let finalTestname = testName + testKind.rawValue
        let expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:NSArray?) {
            callback(result, nil)
            expection.fulfill()
        }
        var ack:OnAckCallback!
        if let emitData = emitData {
            ack = socket.emitWithAck(finalTestname, emitData)
        } else {
            ack = socket.emitWithAck(finalTestname)
        }
        ack(timeoutAfter: 20, callback: didGetEmit)
        
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
}
