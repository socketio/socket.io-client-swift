//
//  SocketParserTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 05.09.15.
//
//

import XCTest

class SocketParserTest: XCTestCase {
    
    //Format key: message; namespace-data-binary-id
    static let packetTypes: Dictionary<String, (String, [AnyObject], [NSData], Int)> = [
        "0": ("/", [], [], -1), "1": ("/", [], [], -1),
        "2/swift,[\"testArrayEmitReturn\",[\"test3\",\"test4\"]]": ("/swift", ["testArrayEmitReturn", ["test3", "test4"]], [], -1),
        "51-/swift,[\"testMultipleItemsWithBufferEmitReturn\",[1,2],{\"test\":\"bob\"},25,\"polo\",{\"_placeholder\":true,\"num\":0}]": ("/swift", ["testMultipleItemsWithBufferEmitReturn", [1, 2], ["test": "bob"], 25, "polo", "~~0"], [], -1),
        "3/swift,0[[\"test3\",\"test4\"]]": ("/swift", [["test3", "test4"]], [], 0),
        "61-/swift,19[[1,2],{\"test\":\"bob\"},25,\"polo\",{\"_placeholder\":true,\"num\":0}]": ("/swift", [ [1, 2], ["test": "bob"], 25, "polo", "~~0"], [], 19),
        "4/swift,": ("/swift", [], [], -1),
        "10": ("/swift", [], [], -1)]
    
    func testDisconnect() {
        let message = "1"
        validateParseResult(message)
    }

    func testConnect() {
        let message = "0"
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
    
    func testInvalidInput() {
        let message = "8"
        let packet = SocketParser.parseString(message)
        XCTAssertNil(packet)
    }
    
    func testGenericParser() {
        var parser = GenericParser(message: "61-/swift,", currentIndex: 0)
        XCTAssertEqual(parser.read(1), "6")
        XCTAssertEqual(parser.currentCharacter, "1")
        XCTAssertEqual(parser.readUntilStringOccurence("-"), "1")
       XCTAssertEqual(parser.currentCharacter, "-")
        
    }
    
    func validateParseResult(message:String) {
        let validValues = SocketParserTest.packetTypes[message]!
        let packet = SocketParser.parseString(message)
        let type = message.substringWithRange(Range<String.Index>(start: message.startIndex, end: message.startIndex.advancedBy(1)))
        if let packet = packet {
            XCTAssertEqual(packet.type, SocketPacket.PacketType(str:type)!)
            XCTAssertEqual(packet.nsp, validValues.0)
            XCTAssertTrue((packet.data as NSArray).isEqualToArray(validValues.1))
            XCTAssertTrue((packet.binary as NSArray).isEqualToArray(validValues.2))
            XCTAssertEqual(packet.id, validValues.3)
        }else {
            XCTFail()
        }
    }
    
    func testParsePerformance() {
        let keys = Array(SocketParserTest.packetTypes.keys)
        measureBlock({
            for item in keys.enumerate() {
                SocketParser.parseString(item.element)
            }
        })
        
    }
}
