//
//  SocketNamespaceAcknowledgementTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 28.07.15.
//
//

import XCTest

class SocketNamespaceAcknowledgementTest: SocketAcknowledgementTest {

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
            "nsp": "/swift",
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
    
    override func testUnicodeEmit() {
        super.testUnicodeEmit()
    }
    
    override func testMultipleItemsEmit() {
        super.testMultipleItemsEmit()
    }
}
