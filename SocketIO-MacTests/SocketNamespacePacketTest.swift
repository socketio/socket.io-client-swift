//
//  SocketNamespacePacketTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/11/15.
//
//

import XCTest
@testable import SocketIO

class SocketNamespacePacketTest: XCTestCase {
    let data = "test".data(using: String.Encoding.utf8)!
    let data2 = "test2".data(using: String.Encoding.utf8)!
    
    func testEmpyEmit() {
        let expectedSendString = "2/swift,[\"test\"]"
        let sendData: [Any] = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testNullEmit() {
        let expectedSendString = "2/swift,[\"test\",null]"
        let sendData: [Any] = ["test", NSNull()]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testStringEmit() {
        let expectedSendString = "2/swift,[\"test\",\"foo bar\"]"
        let sendData: [Any] = ["test", "foo bar"]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testJSONEmit() {
        let expectedSendString = "2/swift,[\"test\",{\"null\":null,\"test\":\"hello\",\"hello\":1,\"foobar\":true}]"
        let sendData: [Any] = ["test", ["foobar": true, "hello": 1, "test": "hello", "null": NSNull()] as NSDictionary]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testArrayEmit() {
        let expectedSendString = "2/swift,[\"test\",[\"hello\",1,{\"test\":\"test\"},true]]"
        let sendData: [Any] = ["test", ["hello", 1, ["test": "test"], true]]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testBinaryEmit() {
        let expectedSendString = "51-/swift,[\"test\",{\"_placeholder\":true,\"num\":0}]"
        let sendData: [Any] = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data])
    }
    
    func testMultipleBinaryEmit() {
        let expectedSendString = "52-/swift,[\"test\",{\"data2\":{\"_placeholder\":true,\"num\":0},\"data1\":{\"_placeholder\":true,\"num\":1}}]"
        let sendData: [Any] = ["test", ["data1": data, "data2": data2] as NSDictionary]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data2, data])
    }
    
    func testEmitWithAck() {
        let expectedSendString = "2/swift,0[\"test\"]"
        let sendData = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testEmitDataWithAck() {
        let expectedSendString = "51-/swift,0[\"test\",{\"_placeholder\":true,\"num\":0}]"
        let sendData: [Any] = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data])
    }
    
    // Acks
    func testEmptyAck() {
        let expectedSendString = "3/swift,0[]"
        let packet = SocketPacket.packetFromEmit([], id: 0, nsp: "/swift", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testNullAck() {
        let expectedSendString = "3/swift,0[null]"
        let sendData = [NSNull()]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testStringAck() {
        let expectedSendString = "3/swift,0[\"test\"]"
        let sendData = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testJSONAck() {
        let expectedSendString = "3/swift,0[{\"null\":null,\"hello\":1,\"test\":\"hello\",\"foobar\":true}]"
        let sendData = [["foobar": true, "hello": 1, "test": "hello", "null": NSNull()]]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testBinaryAck() {
        let expectedSendString = "61-/swift,0[{\"_placeholder\":true,\"num\":0}]"
        let sendData = [data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data])
    }
    
    func testMultipleBinaryAck() {
        let expectedSendString = "62-/swift,0[{\"data2\":{\"_placeholder\":true,\"num\":0},\"data1\":{\"_placeholder\":true,\"num\":1}}]"
        let sendData = [["data1": data, "data2": data2]]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data2, data])
    }
}
