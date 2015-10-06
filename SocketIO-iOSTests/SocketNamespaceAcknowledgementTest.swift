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
        socket = AbstractSocketTest.namespaceSocket
        testKind = TestKind.Acknowledgement
        openConnection(socket)
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
