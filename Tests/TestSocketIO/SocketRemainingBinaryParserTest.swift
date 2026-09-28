import Foundation
import XCTest
@testable import SocketIO

final class SocketRemainingBinaryParserTest: XCTestCase {
    private func assertRoundTrip(_ items: [Any], ack: Bool = false, id: Int = 0, namespace: String = "/binary") throws {
        let safe = try SocketPacket.jsonSafeEmitData(items, allowBinary: true)
        let packet = SocketPacket.packetFromEmit(safe, id: id, nsp: namespace, ack: ack)
        XCTAssertEqual(packet.type, ack ? .binaryAck : .binaryEvent)
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false)])
        var decoded = try XCTUnwrap(manager.parseSocketMessage(packet.encodedPacketString()))
        for (index, attachment) in packet.binary.enumerated() {
            XCTAssertEqual(decoded.addData(attachment), index == packet.binary.count - 1)
        }
        XCTAssertEqual(decoded.type, ack ? .binaryAck : .binaryEvent)
        XCTAssertFalse(decoded.reconstructionFailed)
        XCTAssertEqual(decoded.id, id); XCTAssertEqual(decoded.nsp, namespace)
        XCTAssertTrue((decoded.data as NSArray).isEqual(to: items))
    }
    func testArrayBufferEquivalentHasExactWireAndAttachment() throws {
        let bytes = Data([0, 1, 2, 3, 4])
        let packet = SocketPacket.packetFromEmit(["hello", bytes], id: 0, nsp: "/binary", ack: false)
        XCTAssertEqual(try packet.encodedPacketString(), "51-/binary,0[\"hello\",{\"_placeholder\":true,\"num\":0}]")
        XCTAssertEqual(packet.binary, [bytes])
        try assertRoundTrip(["hello", bytes])
        try assertRoundTrip(["a", Data(repeating: 0, count: 2)], namespace: "/")
    }
    func testTypedArrayEquivalentEncodesOnlySelectedBytes() throws {
        let source = Data([99, 0, 1, 2, 3, 4, 88])
        let slice = source.subdata(in: 1..<6)
        let packet = SocketPacket.packetFromEmit(["slice", slice], id: 0, nsp: "/binary", ack: false)
        XCTAssertEqual(packet.binary, [Data([0, 1, 2, 3, 4])])
        XCTAssertEqual(source, Data([99, 0, 1, 2, 3, 4, 88]))
        try assertRoundTrip(["slice", slice])
        try assertRoundTrip(["a", Data([0, 1, 2, 3, 4])], namespace: "/")
    }
    func testNativeDictionaryHasNoPrototypeAndPreservesSpecialKeys() throws {
        try assertRoundTrip(["dictionary", ["__proto__": Data([1]), "constructor": "value"] as [String: Any]])
    }
    func testBlobEquivalentPreservesEmptyAndNonemptyData() throws {
        for data in [Data(), Data([0, 1, 127, 128, 255])] { try assertRoundTrip(["blob", data]) }
        try assertRoundTrip(["a", Data(repeating: 0, count: 2)], namespace: "/")
    }
    func testBlobEquivalentDeepInJSON() throws {
        try assertRoundTrip(["deep", ["a": [NSNull(), ["b": Data([1, 2, 3])]]]])
        try assertRoundTrip(["a", ["a": "hi", "b": ["why": Data(repeating: 0, count: 2)], "c": "bye"] as [String: Any]],
                           id: 999, namespace: "/deep")
    }
    func testBinaryAckBlobEquivalent() throws {
        try assertRoundTrip([Data([0, 1, 2, 3, 4])], ack: true)
        try assertRoundTrip([["a": "hi ack", "b": ["why": Data(repeating: 0, count: 2)], "c": "bye ack"] as [String: Any]],
                           ack: true, id: 999, namespace: "/deep")
    }
    func testPublicPacketTypesMatchWireNumbers() {
        let types: [SocketPacket.PacketType] = [.connect, .disconnect, .event, .ack, .error, .binaryEvent, .binaryAck]
        XCTAssertEqual(types.map { $0.rawValue }, Array(0...6))
    }
}
