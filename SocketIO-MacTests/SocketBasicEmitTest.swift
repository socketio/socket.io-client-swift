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
        let engine = SocketTestEngine(client: socket,
            expectedSendString: "2[\"test\"]",
            expectedNumberOfBinary: 0,
            expectedBinary: nil)
        socket.setTestEngine(engine)
        socket.emitTest("test")
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
    
    func testNullEmit() {
        let engine = SocketTestEngine(client: socket,
            expectedSendString: "2[\"test\",null]",
            expectedNumberOfBinary: 0,
            expectedBinary: nil)
        socket.setTestEngine(engine)
        socket.emitTest("test", NSNull())
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
    
    func testStringEmit() {
        let engine = SocketTestEngine(client: socket,
            expectedSendString: "2[\"test\",\"foo bar\"]",
            expectedNumberOfBinary: 0,
            expectedBinary: nil)
        socket.setTestEngine(engine)
        socket.emitTest("test", "foo bar")
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
    
    func testJSONEmit() {
        let engine = SocketTestEngine(client: socket,
            expectedSendString: "2[\"test\",{\"test\":\"hello\",\"hello\":1,\"foobar\":true,\"null\":null}]",
            expectedNumberOfBinary: 0,
            expectedBinary: nil)
        socket.setTestEngine(engine)
        socket.emitTest("test", ["foobar": true, "hello": 1, "test": "hello", "null": NSNull()])
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
    
    func testArrayEmit() {
        let engine = SocketTestEngine(client: socket,
            expectedSendString: "2[\"test\",[\"hello\",1,{\"test\":\"test\"}]]",
            expectedNumberOfBinary: 0,
            expectedBinary: nil)
        socket.setTestEngine(engine)
        socket.emitTest("test", ["hello", 1, ["test": "test"]])
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
    
    func testBinaryEmit() {
        let data = "test".dataUsingEncoding(NSUTF8StringEncoding)!
        let engine = SocketTestEngine(client: socket,
            expectedSendString: "51-[\"test\",{\"num\":0,\"_placeholder\":true}]",
            expectedNumberOfBinary: 1,
            expectedBinary: [data])
        socket.setTestEngine(engine)
        socket.emitTest("test", data)
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
    
    func testMultipleBinaryEmit() {
        let data = "test".dataUsingEncoding(NSUTF8StringEncoding)!
        let data2 = "test2".dataUsingEncoding(NSUTF8StringEncoding)!
        let engine = SocketTestEngine(client: socket,
            expectedSendString: "52-[\"test\",{\"data2\":{\"num\":0,\"_placeholder\":true},\"data1\":{\"num\":1,\"_placeholder\":true}}]",
            expectedNumberOfBinary: 2,
            expectedBinary: [data2, data])
        socket.setTestEngine(engine)
        socket.emitTest("test", ["data1": data, "data2": data2])
        XCTAssert(engine.socketDidCorrectlyCreatePacket())
    }
}
