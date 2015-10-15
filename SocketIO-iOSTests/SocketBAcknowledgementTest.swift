//
//  SocketAcknowledgementTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 27.07.15.
//
//

import XCTest

class SocketBAcknowledgementTest: AbstractSocketTest {
    
    override func setUp() {
        super.setUp()
        socket = AbstractSocketTest.regularAckSocket
        testKind = TestKind.Acknowledgement
        
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
