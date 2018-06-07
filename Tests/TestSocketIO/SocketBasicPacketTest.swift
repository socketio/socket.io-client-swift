//
//  SocketBasicPacketTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/7/15.
//
//

import XCTest
@testable import SocketIO

class SocketBasicPacketTest : XCTestCase {
    func testEmptyEmit() {
        let sendData = ["test"]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testNullEmit() {
		let sendData: [Any] = ["test", NSNull()]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testStringEmit() {
        let sendData = ["test", "foo bar"]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testStringEmitWithQuotes() {
        let sendData = ["test", "\"he\"llo world\""]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testJSONEmit() {
        let sendData: [Any] = ["test", ["foobar": true, "hello": 1, "test": "hello", "null": NSNull()]]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testArrayEmit() {
        let sendData: [Any] = ["test", ["hello", 1, ["test": "test"]]]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testBinaryEmit() {
        let sendData: [Any] = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryEvent)
        XCTAssertEqual(packet.binary, [data])
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: [
            "test",
            ["_placeholder": true, "num": 0]
        ]))
    }

    func testMultipleBinaryEmit() {
        let sendData: [Any] = ["test", ["data1": data, "data2": data2] as NSDictionary]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryEvent)

        let binaryObj = parsed.data[1] as! [String: Any]
        let data1Loc = (binaryObj["data1"] as! [String: Any])["num"] as! Int
        let data2Loc = (binaryObj["data2"] as! [String: Any])["num"] as! Int

        XCTAssertEqual(packet.binary[data1Loc], data)
        XCTAssertEqual(packet.binary[data2Loc], data2)
    }

    func testEmitWithAck() {
        let sendData = ["test"]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: false).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testEmitDataWithAck() {
        let sendData: [Any] = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryEvent)
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: [
            "test",
            ["_placeholder": true, "num": 0]
        ]))
        XCTAssertEqual(packet.binary, [data])
    }

    // Acks
    func testEmptyAck() {
        let packetStr = SocketPacket.packetFromEmit([], id: 0, nsp: "/", ack: true).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: []))
    }

    func testNullAck() {
        let sendData = [NSNull()]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testStringAck() {
        let sendData = ["test"]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testJSONAck() {
        let sendData = [["foobar": true, "hello": 1, "test": "hello", "null": NSNull()]]
        let packetStr = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true).packetString
        let parsed = parser.parseSocketMessage(packetStr)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testBinaryAck() {
        let sendData = [data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryAck)
        XCTAssertEqual(packet.binary, [data])
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: [
            ["_placeholder": true, "num": 0]
        ]))
    }

    func testMultipleBinaryAck() {
        let sendData = [["data1": data, "data2": data2]]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.id, 0)
        XCTAssertEqual(parsed.type, .binaryAck)

        let binaryObj = parsed.data[0] as! [String: Any]
        let data1Loc = (binaryObj["data1"] as! [String: Any])["num"] as! Int
        let data2Loc = (binaryObj["data2"] as! [String: Any])["num"] as! Int

        XCTAssertEqual(packet.binary[data1Loc], data)
        XCTAssertEqual(packet.binary[data2Loc], data2)
    }

    func testBinaryStringPlaceholderInMessage() {
        let engineString = "52-[\"test\",\"~~0\",{\"num\":0,\"_placeholder\":true},{\"_placeholder\":true,\"num\":1}]"
        let manager = SocketManager(socketURL: URL(string: "http://localhost/")!)

        var packet = try! manager.parseString(engineString)

        XCTAssertEqual(packet.event, "test")
        _ = packet.addData(data)
        _ = packet.addData(data2)
        XCTAssertEqual(packet.args[0] as? String, "~~0")
    }

    private func compareAnyArray(input: [Any], expected: [Any]) -> Bool {
        guard input.count == expected.count else { return false }

        return (input as NSArray).isEqual(to: expected)
    }

    let data = "test".data(using: String.Encoding.utf8)!
    let data2 = "test2".data(using: String.Encoding.utf8)!
    var parser: SocketParsable!

    override func setUp() {
        super.setUp()

        parser = SocketManager(socketURL: URL(string: "http://localhost")!)
    }
}
