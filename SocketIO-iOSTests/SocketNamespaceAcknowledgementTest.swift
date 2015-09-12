//
//  SocketNamespaceAcknowledgementTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 28.07.15.
//
//

import XCTest

class SocketNamespaceAcknowledgementTest: AbstractSocketTest {

    override func setUp() {
        super.setUp()
        testKind = TestKind.Acknowledgement
        if AbstractSocketTest.socket == nil {
            AbstractSocketTest.socket = SocketIOClient(socketURL: AbstractSocketTest.serverURL, opts: [
            "reconnects": true, // default true
            "reconnectAttempts": -1, // default -1
            "reconnectWait": 5, // default 10
            "forcePolling": false,
            "forceWebsockets": false,// default false
            "path": "",
            "nsp": "/swift"])
            openConnection()
        }else {
            AbstractSocketTest.socket.joinNamespace("/swift")
        }
        
        
    }
    
    func testConnectionStatus() {
        super.checkConnectionStatus()
    }
    
    func testBasic() {
        SocketTestCases.testBasic(socketAcknwoledge)
    }
    
    func testNull() {
        SocketTestCases.testNull(socketAcknwoledge)
    }
    
    func testBinary() {
        SocketTestCases.testBinary(socketAcknwoledge)
    }
    
    func testArray() {
        SocketTestCases.testArray(socketAcknwoledge)
    }
    
    func testString() {
        SocketTestCases.testString(socketAcknwoledge)
    }
    
    func testBool() {
        SocketTestCases.testBool(socketAcknwoledge)
    }
    
    func testInteger() {
        SocketTestCases.testInteger(socketAcknwoledge)
    }
    
    func testDouble() {
        SocketTestCases.testDouble(socketAcknwoledge)
    }
    
    func testJSON() {
        SocketTestCases.testJSON(socketAcknwoledge)
    }
    
    func testJSONWithBuffer() {
        SocketTestCases.testJSONWithBuffer(socketAcknwoledge)
    }
    
    func testUnicode() {
        SocketTestCases.testUnicode(socketAcknwoledge)
    }
    
    func testMultipleItems() {
        SocketTestCases.testMultipleItems(socketAcknwoledgeMultiple)
    }
    
    func testMultipleWithBuffer() {
        SocketTestCases.testMultipleItemsWithBuffer(socketAcknwoledgeMultiple)
    }
}
