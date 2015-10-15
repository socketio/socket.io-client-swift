//
//  SocketPollingEmitTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 9/28/15.
//
//

import Foundation
import XCTest

class SocketPollingEmitTest: AbstractSocketTest {
    override func setUp() {
        super.setUp()
        socket = AbstractSocketTest.regularPollingSocket
        testKind = TestKind.Emit
        
    }
    
    func testConnectionStatus() {
        super.checkConnectionStatus()
    }
    
    func testBasic() {
        SocketTestCases.testBasic(socketEmit)
    }
    
    func testNull() {
        SocketTestCases.testNull(socketEmit)
    }
    
    func testBinary() {
        SocketTestCases.testBinary(socketEmit)
    }
    
    
    func testArray() {
        SocketTestCases.testArray(socketEmit)
    }
    
    func testString() {
        SocketTestCases.testString(socketEmit)
    }
    
    func testBool() {
        SocketTestCases.testBool(socketEmit)
    }
    
    func testInteger() {
        SocketTestCases.testInteger(socketEmit)
    }
    
    func testDouble() {
        SocketTestCases.testDouble(socketEmit)
    }
    
    func testJSON() {
        SocketTestCases.testJSON(socketEmit)
    }
    
    func testJSONWithBuffer() {
        SocketTestCases.testJSONWithBuffer(socketEmit)
    }
    
    func testUnicode() {
        SocketTestCases.testUnicode(socketEmit)
    }
    
    func testMultipleItems() {
        SocketTestCases.testMultipleItems(socketMultipleEmit)
    }
    
    func testMultipleWithBuffer() {
        SocketTestCases.testMultipleItemsWithBuffer(socketMultipleEmit)
    }
}
