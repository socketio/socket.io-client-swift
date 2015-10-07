//
//  SocketBasicEmitTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/7/15.
//
//

import XCTest

class SocketBasicEmitTest: XCTestCase {
    var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        socket = SocketIOClient(socketURL: "")
        socket.setTestable()
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }

    func testEmpyEmit() {
        let engine = SocketTestEngine(client: socket, expectedSendString: "2[\"test\"]", expectedNumberOfBinary: 0)
        socket.setTestEngine(engine)
        socket.emitTest("test")
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
    
    func testStringEmit() {
        let engine = SocketTestEngine(client: socket, expectedSendString: "2[\"test\",\"foo bar\"]", expectedNumberOfBinary: 0)
        socket.setTestEngine(engine)
        socket.emitTest("test", "foo bar")
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
}
