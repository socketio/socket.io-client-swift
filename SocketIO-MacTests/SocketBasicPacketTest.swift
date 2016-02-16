//
//  SocketBasicPacketTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/7/15.
//
//

import XCTest
@testable import SocketIOClientSwift

class SocketBasicPacketTest: XCTestCase {
    let data = "test".dataUsingEncoding(NSUTF8StringEncoding)!
    let data2 = "test2".dataUsingEncoding(NSUTF8StringEncoding)!
    
    func testEmpyEmit() {
        let expectedSendString = "2[\"test\"]"
        let sendData = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)

        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testNullEmit() {
        let expectedSendString = "2[\"test\",null]"
        let sendData = ["test", NSNull()]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testStringEmit() {
        let expectedSendString = "2[\"test\",\"foo bar\"]"
        let sendData = ["test", "foo bar"]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testStringEmitWithQuotes() {
        let expectedSendString = "2[\"test\",\"\\\"he\\\"llo world\\\"\"]"
        let sendData = ["test", "\"he\"llo world\""]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testJSONEmit() {
        let expectedSendString = "2[\"test\",{\"test\":\"hello\",\"hello\":1,\"foobar\":true,\"null\":null}]"
        let sendData = ["test", ["foobar": true, "hello": 1, "test": "hello", "null": NSNull()]]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testArrayEmit() {
        let expectedSendString = "2[\"test\",[\"hello\",1,{\"test\":\"test\"}]]"
        let sendData = ["test", ["hello", 1, ["test": "test"]]]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testBinaryEmit() {
        let expectedSendString = "51-[\"test\",{\"num\":0,\"_placeholder\":true}]"
        let sendData = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data])
    }
    
    func testMultipleBinaryEmit() {
        let expectedSendString = "52-[\"test\",{\"data1\":{\"num\":0,\"_placeholder\":true},\"data2\":{\"num\":1,\"_placeholder\":true}}]"
        let sendData = ["test", ["data1": data, "data2": data2]]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data, data2])
    }
    
    func testEmitWithAck() {
        let expectedSendString = "20[\"test\"]"
        let sendData = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: false)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testEmitDataWithAck() {
        let expectedSendString = "51-0[\"test\",{\"num\":0,\"_placeholder\":true}]"
        let sendData = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: false)

        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data])
    }
    
    // Acks
    func testEmptyAck() {
        let expectedSendString = "30[]"
        let packet = SocketPacket.packetFromEmit([], id: 0, nsp: "/", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testNullAck() {
        let expectedSendString = "30[null]"
        let sendData = [NSNull()]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testStringAck() {
        let expectedSendString = "30[\"test\"]"
        let sendData = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testJSONAck() {
        let expectedSendString = "30[{\"test\":\"hello\",\"hello\":1,\"foobar\":true,\"null\":null}]"
        let sendData = [["foobar": true, "hello": 1, "test": "hello", "null": NSNull()]]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
    }
    
    func testBinaryAck() {
        let expectedSendString = "61-0[{\"num\":0,\"_placeholder\":true}]"
        let sendData = [data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data])
    }
    
    func testMultipleBinaryAck() {
        let expectedSendString = "62-0[{\"data2\":{\"num\":0,\"_placeholder\":true},\"data1\":{\"num\":1,\"_placeholder\":true}}]"
        let sendData = [["data1": data, "data2": data2]]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true)
        
        XCTAssertEqual(packet.packetString, expectedSendString)
        XCTAssertEqual(packet.binary, [data2, data])
    }
}
