//
//  SocketNamespacePacketTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/11/15.
//
//

import XCTest
@testable import SocketIO

class SocketNamespacePacketTest : XCTestCase {
    func testEmptyEmit() {
        let sendData: [Any] = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testNullEmit() {
        let sendData: [Any] = ["test", NSNull()]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testStringEmit() {
        let sendData: [Any] = ["test", "foo bar"]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testJSONEmit() {
        let sendData: [Any] = ["test", ["foobar": true, "hello": 1, "test": "hello", "null": NSNull()] as NSDictionary]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testArrayEmit() {
        let sendData: [Any] = ["test", ["hello", 1, ["test": "test"], true]]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testBinaryEmit() {
        let sendData: [Any] = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryEvent)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(packet.binary, [data])
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: [
            "test",
            ["_placeholder": true, "num": 0]
        ]))
    }

    func testMultipleBinaryEmit() {
        let sendData: [Any] = ["test", ["data1": data, "data2": data2] as NSDictionary]
        let packet = SocketPacket.packetFromEmit(sendData, id: -1, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryEvent)
        XCTAssertEqual(parsed.nsp, "/swift")

        let binaryObj = parsed.data[1] as! [String: Any]
        let data1Loc = (binaryObj["data1"] as! [String: Any])["num"] as! Int
        let data2Loc = (binaryObj["data2"] as! [String: Any])["num"] as! Int

        XCTAssertEqual(packet.binary[data1Loc], data)
        XCTAssertEqual(packet.binary[data2Loc], data2)
    }

    func testEmitWithAck() {
        let sendData = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .event)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testEmitDataWithAck() {
        let sendData: [Any] = ["test", data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: false)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryEvent)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: [
            "test",
            ["_placeholder": true, "num": 0]
        ]))
    }

    // Acks
    func testEmptyAck() {
        let packet = SocketPacket.packetFromEmit([], id: 0, nsp: "/swift", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)
    }

    func testNullAck() {
        let sendData = [NSNull()]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testStringAck() {
        let sendData = ["test"]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testJSONAck() {
        let sendData = [["foobar": true, "hello": 1, "test": "hello", "null": NSNull()]]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .ack)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: sendData))
    }

    func testBinaryAck() {
        let sendData = [data]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryAck)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)
        XCTAssertTrue(compareAnyArray(input: parsed.data, expected: [
            ["_placeholder": true, "num": 0]
        ]))
    }

    func testMultipleBinaryAck() {
        let sendData = [["data1": data, "data2": data2]]
        let packet = SocketPacket.packetFromEmit(sendData, id: 0, nsp: "/swift", ack: true)
        let parsed = parser.parseSocketMessage(packet.packetString)!

        XCTAssertEqual(parsed.type, .binaryAck)
        XCTAssertEqual(parsed.nsp, "/swift")
        XCTAssertEqual(parsed.id, 0)

        let binaryObj = parsed.data[0] as! [String: Any]
        let data1Loc = (binaryObj["data1"] as! [String: Any])["num"] as! Int
        let data2Loc = (binaryObj["data2"] as! [String: Any])["num"] as! Int

        XCTAssertEqual(packet.binary[data1Loc], data)
        XCTAssertEqual(packet.binary[data2Loc], data2)
    }

    let data = "test".data(using: String.Encoding.utf8)!
    let data2 = "test2".data(using: String.Encoding.utf8)!
    var parser: SocketParsable!

    private func compareAnyArray(input: [Any], expected: [Any]) -> Bool {
        guard input.count == expected.count else { return false }

        return (input as NSArray).isEqual(to: expected)
    }

    override func setUp() {
        super.setUp()

        parser = SocketManager(socketURL: URL(string: "http://localhost")!)
    }
}
