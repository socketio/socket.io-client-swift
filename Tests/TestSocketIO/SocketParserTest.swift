//
//  SocketParserTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 05.09.15.
//
//

import XCTest
@testable import SocketIO

class SocketParserTest: XCTestCase {
    func testDisconnect() {
        let message = "1"
        validateParseResult(message)
    }

    func testConnect() {
        let message = "0"
        validateParseResult(message)
    }

    func testDisconnectNameSpace() {
        let message = "1/swift"
        validateParseResult(message)
    }

    func testConnecttNameSpace() {
        let message = "0/swift"
        validateParseResult(message)
    }

    func testIdEvent() {
        let message = "25[\"test\"]"
        validateParseResult(message)
    }

    func testBinaryPlaceholderAsString() {
        let message = "2[\"test\",\"~~0\"]"
        validateParseResult(message)
    }

    func testNameSpaceArrayParse() {
        let message = "2/swift,[\"testArrayEmitReturn\",[\"test3\",\"test4\"]]"
        validateParseResult(message)
    }

    func testNameSpaceArrayAckParse() {
        let message = "3/swift,0[[\"test3\",\"test4\"]]"
        validateParseResult(message)
    }

    func testNameSpaceBinaryEventParse() {
        let message = "51-/swift,[\"testMultipleItemsWithBufferEmitReturn\",[1,2],{\"test\":\"bob\"},25,\"polo\",{\"_placeholder\":true,\"num\":0}]"
        validateParseResult(message)
    }

    func testNameSpaceBinaryAckParse() {
        let message = "61-/swift,19[[1,2],{\"test\":\"bob\"},25,\"polo\",{\"_placeholder\":true,\"num\":0}]"
        validateParseResult(message)
    }

    func testNamespaceErrorParse() {
        let message = "4/swift,"
        validateParseResult(message)
    }

    func testErrorTypeString() {
        let message = "4\"ERROR\""
        validateParseResult(message)
    }

    func testErrorTypeDictionary() {
        let message = "4{\"test\":2}"
        validateParseResult(message)
    }

    func testErrorTypeInt() {
        let message = "41"
        validateParseResult(message)
    }

    func testErrorTypeArray() {
        let message = "4[1, \"hello\"]"
        validateParseResult(message)
    }

    func testInvalidInput() {
        let message = "8"
        do {
            let _ = try testManager.parseString(message)
            XCTFail()
        } catch {

        }
    }

    func testGenericParser() {
        var parser = SocketStringReader(message: "61-/swift,")
        XCTAssertEqual(parser.read(count: 1), "6")
        XCTAssertEqual(parser.currentCharacter, "1")
        XCTAssertEqual(parser.readUntilOccurence(of: "-"), "1")
        XCTAssertEqual(parser.currentCharacter, "/")
    }

    func validateParseResult(_ message: String) {
        let validValues = SocketParserTest.packetTypes[message]!
        let packet = try! testManager.parseString(message)
        let type = String(message.prefix(1))

        XCTAssertEqual(packet.type, SocketPacket.PacketType(rawValue: Int(type) ?? -1)!)
        XCTAssertEqual(packet.nsp, validValues.0)
        XCTAssertTrue((packet.data as NSArray).isEqual(to: validValues.1), "\(packet.data)")
        XCTAssertTrue((packet.binary as NSArray).isEqual(to: validValues.2), "\(packet.binary)")
        XCTAssertEqual(packet.id, validValues.3)
    }

    func testParsePerformance() {
        let keys = Array(SocketParserTest.packetTypes.keys)
        measure {
            for item in keys.enumerated() {
                _ = try! self.testManager.parseString(item.element)
            }
        }
    }

    let testManager = SocketManager(socketURL: URL(string: "http://localhost/")!)

    //Format key: message; namespace-data-binary-id
    static let packetTypes: [String: (String, [Any], [Data], Int)] = [
        "0": ("/", [], [], -1), "1": ("/", [], [], -1),
        "25[\"test\"]": ("/", ["test"], [], 5),
        "2[\"test\",\"~~0\"]": ("/", ["test", "~~0"], [], -1),
        "2/swift,[\"testArrayEmitReturn\",[\"test3\",\"test4\"]]": ("/swift", ["testArrayEmitReturn", ["test3", "test4"] as NSArray], [], -1),
        "51-/swift,[\"testMultipleItemsWithBufferEmitReturn\",[1,2],{\"test\":\"bob\"},25,\"polo\",{\"_placeholder\":true,\"num\":0}]": ("/swift", ["testMultipleItemsWithBufferEmitReturn", [1, 2] as NSArray, ["test": "bob"] as NSDictionary, 25, "polo", ["_placeholder": true, "num": 0] as NSDictionary], [], -1),
        "3/swift,0[[\"test3\",\"test4\"]]": ("/swift", [["test3", "test4"] as NSArray], [], 0),
        "61-/swift,19[[1,2],{\"test\":\"bob\"},25,\"polo\",{\"_placeholder\":true,\"num\":0}]":
        ("/swift", [ [1, 2] as NSArray, ["test": "bob"] as NSDictionary, 25, "polo", ["_placeholder": true, "num": 0] as NSDictionary], [], 19),
        "4/swift,": ("/swift", [], [], -1),
        "0/swift": ("/swift", [], [], -1),
        "1/swift": ("/swift", [], [], -1),
        "4\"ERROR\"": ("/", ["ERROR"], [], -1),
        "4{\"test\":2}": ("/", [["test": 2]], [], -1),
        "41": ("/", [1], [], -1),
        "4[1, \"hello\"]": ("/", [1, "hello"], [], -1)
    ]
}
