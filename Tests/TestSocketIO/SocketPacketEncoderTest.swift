//
//  SocketPacketEncoderTest.swift
//  Socket.IO-Client-Swift
//
//  Round 2 of the JavaScript-parity port: the outgoing encoder.
//
//  Ports the encoder expectations of `socket.io-parser/test/parser.js`,
//  `test/buffer.js` and `test/arraybuffer.js`, plus the JS `JSON.stringify`
//  rules this client now follows instead of substituting an empty payload
//  (`Date` → ISO-8601, non-finite → `null`, anything else → a thrown
//  `SocketPacketError`).
//
//  The JS helpers `test()`/`test_bin()` encode a packet and assert that the
//  pinned decoder reproduces it, so the binary cases below assert the exact
//  header and then round-trip through this client's decoder: which attachment
//  index a nested buffer gets depends on dictionary iteration order, and only
//  the reconstruction has to match.
//

import XCTest
@testable import SocketIO

final class SocketPacketEncoderTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!
    private var engine: MockEngine!
    private var parser: SocketParsable!

    override func setUp() {
        super.setUp()

        let queue = DispatchQueue(label: "test.SocketPacketEncoderTest.handleQueue")
        manager = SocketManager(socketURL: URL(string: "http://localhost/")!,
                                config: [.log(false), .handleQueue(queue)])
        engine = MockEngine()
        manager.engine = engine
        socket = manager.defaultSocket
        socket.setTestStatus(.connected)
        parser = manager
    }

    override func tearDown() {
        manager = nil
        socket = nil
        engine = nil
        parser = nil
        super.tearDown()
    }

    private func drain() {
        manager.handleQueue.sync { /* barrier */ }
    }

    /// Decodes `packet`'s own wire form back into a packet, feeding its
    /// attachments in order — the Swift equivalent of the JS `test_bin` helper.
    private func roundTrip(_ packet: SocketPacket) throws -> SocketPacket {
        var decoded = try XCTUnwrap(parser.parseSocketMessage(packet.encodedPacketString()))

        for (index, attachment) in packet.binary.enumerated() {
            XCTAssertEqual(decoded.addData(attachment), index == packet.binary.count - 1)
        }

        XCTAssertFalse(decoded.reconstructionFailed)
        XCTAssertEqual(decoded.type, packet.type)
        XCTAssertEqual(decoded.nsp, packet.nsp)
        XCTAssertEqual(decoded.id, packet.id)

        return decoded
    }

    private func isEqual(_ lhs: [Any], _ rhs: [Any]) -> Bool {
        return (lhs as NSArray).isEqual(to: rhs)
    }

    // MARK: socket.io-parser/test/parser.js — "encodes connection"

    func testEncodesConnection() throws {
        let packet = SocketPacket(type: .connect, data: [["token": "123"]], nsp: "/woot")

        XCTAssertEqual(try packet.encodedPacketString(), "0/woot,{\"token\":\"123\"}")

        // The client writes CONNECT through the manager, not through
        // `SocketPacket`; the wire string has to be the same one.
        let socket = manager.socket(forNamespace: "/woot")
        manager.setTestStatus(.connected)
        manager.connectSocket(socket, withPayload: ["token": "123"])
        drain()

        XCTAssertEqual(engine.sentPackets.last?.0, "0/woot,{\"token\":\"123\"}")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/parser.js — "encodes disconnection"

    func testEncodesDisconnection() throws {
        let packet = SocketPacket(type: .disconnect, nsp: "/woot")

        XCTAssertEqual(try packet.encodedPacketString(), "1/woot,")

        let socket = manager.socket(forNamespace: "/woot")
        manager.disconnectSocket(socket)
        drain()

        XCTAssertEqual(engine.sentPackets.last?.0, "1/woot,")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/parser.js — "encodes an event"

    func testEncodesAnEvent() throws {
        let packet = SocketPacket.packetFromEmit(["a", 1, [String: Any]()], id: -1, nsp: "/", ack: false)

        XCTAssertEqual(packet.type, .event)
        XCTAssertEqual(try packet.encodedPacketString(), "2[\"a\",1,{}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/parser.js — "encodes an event (with an integer as event name)"

    func testEncodesAnEventWithAnIntegerAsEventName() throws {
        let packet = SocketPacket.packetFromEmit([1, "a", [String: Any]()], id: -1, nsp: "/", ack: false)

        XCTAssertEqual(try packet.encodedPacketString(), "2[1,\"a\",{}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/parser.js — "encodes an event (with ack)"

    func testEncodesAnEventWithAck() throws {
        let packet = SocketPacket.packetFromEmit(["a", 1, [String: Any]()], id: 1, nsp: "/test", ack: false)

        XCTAssertEqual(try packet.encodedPacketString(), "2/test,1[\"a\",1,{}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/parser.js — "encodes an ack"

    func testEncodesAnAck() throws {
        let packet = SocketPacket.packetFromEmit(["a", 1, [String: Any]()], id: 123, nsp: "/", ack: true)

        XCTAssertEqual(packet.type, .ack)
        XCTAssertEqual(try packet.encodedPacketString(), "3123[\"a\",1,{}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/parser.js — "encodes an connect error"

    /// A CONNECT_ERROR is server-to-client only, so no Swift emit path produces
    /// one; the encoder still has to render the JS wire form, which is what the
    /// encode direction of the decoder differential exercises.
    func testEncodesAConnectError() throws {
        let packet = SocketPacket(type: .error, data: ["Unauthorized"], nsp: "/")

        XCTAssertEqual(try packet.encodedPacketString(), "4\"Unauthorized\"")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/parser.js — "encodes an connect error (with object)"

    func testEncodesAConnectErrorWithObject() throws {
        let packet = SocketPacket(type: .error, data: [["message": "Unauthorized"]], nsp: "/")

        XCTAssertEqual(try packet.encodedPacketString(), "4{\"message\":\"Unauthorized\"}")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, packet.data))
    }

    // MARK: socket.io-parser/test/buffer.js — "encodes a Buffer"

    func testEncodesABuffer() throws {
        let buffer = Data("abc".utf8)
        let items: [Any] = ["a", buffer]
        let packet = SocketPacket.packetFromEmit(items, id: 23, nsp: "/cool", ack: false)

        XCTAssertEqual(packet.type, .binaryEvent)
        XCTAssertEqual(packet.binary, [buffer])
        XCTAssertEqual(try packet.encodedPacketString(),
                       "51-/cool,23[\"a\",{\"_placeholder\":true,\"num\":0}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, items))
    }

    // MARK: socket.io-parser/test/buffer.js — "encodes a nested Buffer"

    func testEncodesANestedBuffer() throws {
        let buffer = Data("abc".utf8)
        let items: [Any] = ["a", ["b": ["c", buffer]]]
        let packet = SocketPacket.packetFromEmit(items, id: 23, nsp: "/cool", ack: false)

        XCTAssertEqual(packet.binary, [buffer])
        XCTAssertEqual(try packet.encodedPacketString(),
                       "51-/cool,23[\"a\",{\"b\":[\"c\",{\"_placeholder\":true,\"num\":0}]}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, items))
    }

    // MARK: socket.io-parser/test/buffer.js — "encodes a binary ack with Buffer"

    func testEncodesABinaryAckWithBuffer() throws {
        let buffer = Data("xxx".utf8)
        let items: [Any] = ["a", buffer, [String: Any]()]
        let packet = SocketPacket.packetFromEmit(items, id: 127, nsp: "/back", ack: true)

        XCTAssertEqual(packet.type, .binaryAck)
        XCTAssertEqual(try packet.encodedPacketString(),
                       "61-/back,127[\"a\",{\"_placeholder\":true,\"num\":0},{}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, items))
    }

    // MARK: socket.io-parser/test/arraybuffer.js — "encodes ArrayBuffers deep in JSON"

    /// `new ArrayBuffer(n)` is `n` zero bytes; `Data` is this client's binary type.
    func testEncodesArrayBuffersDeepInJSON() throws {
        let items: [Any] = ["a", [
            "a": "hi",
            "b": ["why": Data(count: 3)],
            "c": ["a": "bye", "b": ["a": Data(count: 6)]]
        ]]
        let packet = SocketPacket.packetFromEmit(items, id: 999, nsp: "/deep", ack: false)

        XCTAssertEqual(packet.binary.count, 2)
        XCTAssertEqual(try packet.encodedPacketString(),
                       "52-/deep,999[\"a\",{\"a\":\"hi\",\"b\":{\"why\":{\"_placeholder\":true,\"num\":0}},"
                        + "\"c\":{\"a\":\"bye\",\"b\":{\"a\":{\"_placeholder\":true,\"num\":1}}}}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, items))
    }

    // MARK: socket.io-parser/test/arraybuffer.js — "encodes deep binary JSON with null values"

    func testEncodesDeepBinaryJSONWithNullValues() throws {
        let items: [Any] = ["a", ["a": "b", "c": 4, "e": ["g": NSNull()], "h": Data(count: 9)]]
        let packet = SocketPacket.packetFromEmit(items, id: 600, nsp: "/", ack: false)

        XCTAssertEqual(packet.binary.count, 1)
        XCTAssertEqual(try packet.encodedPacketString(),
                       "51-600[\"a\",{\"a\":\"b\",\"c\":4,\"e\":{\"g\":null},\"h\":{\"_placeholder\":true,\"num\":0}}]")
        XCTAssertTrue(isEqual(try roundTrip(packet).data, items))
    }

    // MARK: socket.io-parser/test/arraybuffer.js — "should not modify the input packet"

    func testShouldNotModifyTheInputPacket() throws {
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])
        let items: [Any] = ["a", first, second]

        let packet = SocketPacket.packetFromEmit(items, id: -1, nsp: "/", ack: false)
        _ = try packet.encodedPacketString()
        XCTAssertEqual(packet.type, .binaryEvent)
        XCTAssertEqual(packet.nsp, "/")
        XCTAssertEqual(packet.id, -1)

        XCTAssertTrue(isEqual(items, ["a", first, second]),
                      "Shredding must not replace the caller's data with placeholders")
    }

    // MARK: connection.ts — "should emit date as string"

    func testEmitsDateAsString() {
        socket.emit("getDate", Date(timeIntervalSince1970: 1_704_164_645.678))
        drain()

        XCTAssertEqual(engine.sentPackets.last?.0, "2[\"getDate\",\"2024-01-02T03:04:05.678Z\"]")
    }

    // MARK: connection.ts — "should emit date in object"

    func testEmitsDateInObject() {
        socket.emit("getDateObj", ["date": Date(timeIntervalSince1970: 1_704_164_645.678)])
        drain()

        XCTAssertEqual(engine.sentPackets.last?.0,
                       "2[\"getDateObj\",{\"date\":\"2024-01-02T03:04:05.678Z\"}]")
    }

    /// The same rule inside arrays, which `JSON.stringify` also applies.
    func testEmitsDateNestedInArrays() {
        socket.emit("dates", [[Date(timeIntervalSince1970: 0)]])
        drain()

        XCTAssertEqual(engine.sentPackets.last?.0, "2[\"dates\",[[\"1970-01-01T00:00:00.000Z\"]]]")
    }

    // MARK: connection.ts — "should receive date with ack"

    /// The JS test asserts that a `Date` crossing the ack boundary arrives as a
    /// string. The client side of that contract is the outgoing ack frame.
    func testAcksADateAsString() {
        socket.emitAck(7, with: [Date(timeIntervalSince1970: 1_704_164_645.678)])
        drain()

        XCTAssertEqual(engine.sentPackets.last?.0, "37[\"2024-01-02T03:04:05.678Z\"]")
    }

    // MARK: JSON.stringify(NaN) === "null"

    func testNonFiniteNumbersEncodeAsNull() {
        socket.emit("numbers", [Double.nan, Double.infinity, -Double.infinity, 1.5])
        drain()

        XCTAssertEqual(engine.sentPackets.last?.0, "2[\"numbers\",[null,null,null,1.5]]")
    }

    // MARK: JSON.stringify throws instead of changing the operation

    func testUnencodableValueThrowsAndSendsNothing() {
        let sentBefore = engine.sentPackets.count
        var reported: Error?
        socket.on(clientEvent: .error) { data, _ in reported = data.last as? Error }

        socket.emit("bad", UnencodableData())
        drain()

        XCTAssertEqual(engine.sentPackets.count, sentBefore, "No packet may leave for an unencodable payload")
        guard case .unsupportedValue? = reported as? SocketPacketError else {
            return XCTFail("Expected a SocketPacketError.unsupportedValue, got \(String(describing: reported))")
        }
    }

    func testUnencodableValueSettlesTheAckExactlyOnce() {
        var errors = [Error]()
        var acks = 0
        socket.emit("bad", UnencodableData()) { error, _ in
            acks += 1
            if let error = error { errors.append(error) }
        }
        drain()

        XCTAssertEqual(acks, 1, "The ack settles exactly once with the encoding error")
        XCTAssertTrue(errors.first is SocketPacketError)
        XCTAssertTrue(engine.sentPackets.isEmpty)
    }

    func testUnencodableTimedEmitSettlesTheAckAndReportsTheError() {
        var reported: Error?
        socket.on(clientEvent: .error) { data, _ in reported = data.last as? Error }

        var acks = 0
        var ackError: Error?
        socket.timeout(after: 5).emit("bad", UnencodableData()) { error, _ in
            acks += 1
            ackError = error
        }
        drain()

        XCTAssertEqual(acks, 1)
        XCTAssertTrue(ackError is SocketPacketError)
        XCTAssertTrue(reported is SocketPacketError)
        XCTAssertTrue(engine.sentPackets.isEmpty)
    }

    /// The encoder runs before `_addToQueue`, so a rejected emit never occupies
    /// the retry queue (JS throws out of `emit()` before the queue is touched).
    func testUnencodableValueIsRejectedBeforeRetryQueueRegistration() {
        manager.retries = 3

        socket.emit("bad", UnencodableData())
        drain()

        XCTAssertEqual(socket.testRetryQueueCount, 0)
        XCTAssertTrue(engine.sentPackets.isEmpty)
    }

    /// …and before the send buffer, so a later connect cannot flush it.
    func testUnencodableValueIsNotBufferedWhileDisconnected() {
        socket.setTestStatus(.notConnected)

        socket.emit("bad", UnencodableData())
        drain()

        socket.setTestStatus(.connected)
        socket.emit("good", 1)
        drain()

        XCTAssertEqual(engine.sentPackets.map({ $0.0 }), ["2[\"good\",1]"])
    }

    /// `rawEmitView` does not shred binary into attachments, so `Data` has no
    /// wire form there. It used to be silently replaced by an empty payload.
    func testRawEmitViewRejectsBinary() {
        var reported: Error?
        socket.on(clientEvent: .error) { data, _ in reported = data.last as? Error }

        socket.rawEmitView.emit("bin", with: [Data([1, 2, 3])])
        drain()

        XCTAssertTrue(engine.sentPackets.isEmpty)
        guard case .unsupportedValue? = reported as? SocketPacketError else {
            return XCTFail("Expected a SocketPacketError.unsupportedValue, got \(String(describing: reported))")
        }
    }

    /// A graph deeper than the encoder limit is an error rather than a
    /// stack overflow inside `JSONSerialization`.
    func testTooDeeplyNestedPayloadThrows() {
        var nested: Any = "leaf"
        for _ in 0...SocketPacket.maximumEmitNestingDepth {
            nested = [nested]
        }

        var reported: Error?
        socket.on(clientEvent: .error) { data, _ in reported = data.last as? Error }

        socket.emit("deep", [nested])
        drain()

        XCTAssertTrue(engine.sentPackets.isEmpty)
        guard case .nestingTooDeep? = reported as? SocketPacketError else {
            return XCTFail("Expected a SocketPacketError.nestingTooDeep, got \(String(describing: reported))")
        }
    }

    /// A volatile packet that is discarded is never encoded, so it cannot
    /// report an encoding error either — JS decides `discardPacket` before
    /// `JSON.stringify` ever runs.
    func testDiscardedVolatileEmitIsSilentEvenWithAnUnencodablePayload() {
        engine.writable = false
        var reported = false
        socket.on(clientEvent: .error) { _, _ in reported = true }

        socket.volatile.emit("bad", UnencodableData())
        drain()

        XCTAssertFalse(reported, "A dropped volatile packet stays silent")
        XCTAssertTrue(engine.sentPackets.isEmpty)
    }

    /// A custom `SocketData` whose conversion throws still reports through the
    /// same `.error` channel, and sends nothing.
    func testThrowingSocketRepresentationIsReportedAndSendsNothing() {
        var reported = false
        socket.on(clientEvent: .error) { _, _ in reported = true }

        socket.emit("bad", ThrowingData())  // see SocketSideEffectTest
        drain()

        XCTAssertTrue(reported)
        XCTAssertTrue(engine.sentPackets.isEmpty)
    }
}

/// A `SocketData` that survives `socketRepresentation()` but has no JSON form.
private struct UnencodableData : SocketData {
    let url = URL(string: "http://localhost/")!
}


extension SocketPacketEncoderTest {
    /// The Foundation objects must reach the identity traversal without a Swift
    /// collection bridge; nested native wrappers exercise the same public path.
    func testRejectsCyclicFoundationContainers() {
        let array = NSMutableArray()
        let dictionary = NSMutableDictionary()
        let mixed = NSMutableArray()
        let mixedDictionary = NSMutableDictionary()
        array.add(array)
        dictionary.setObject(dictionary, forKey: "self" as NSString)
        mixed.add(mixedDictionary)
        mixedDictionary.setObject(mixed, forKey: "back" as NSString)
        defer {
            array.removeAllObjects(); dictionary.removeAllObjects()
            mixed.removeAllObjects(); mixedDictionary.removeAllObjects()
        }
        for value: Any in [array, dictionary, mixed, ["nested": dictionary]] {
            XCTAssertThrowsError(try SocketPacket.jsonSafeEmitData(["cycle", value], allowBinary: true)) { error in
                guard case SocketPacketError.cyclicPayload = error else {
                    return XCTFail("Expected a cycle error, got \(error)")
                }
            }
        }
    }

    func testSharedFoundationSubgraphsRemainValid() throws {
        let shared: NSDictionary = ["answer": 42]
        let values = try SocketPacket.jsonSafeEmitData(["shared", [shared, shared]], allowBinary: true)
        let packet = SocketPacket.packetFromEmit(values, id: -1, nsp: "/", ack: false)
        XCTAssertEqual(try packet.encodedPacketString(), "2[\"shared\",[{\"answer\":42},{\"answer\":42}]]")
    }

    func testNodeBudgetRejectsBeforeLargeContainerAllocation() {
        var normalizer = SocketEmitNormalizer(allowBinary: true, maximumNodes: 3)
        XCTAssertThrowsError(try normalizer.normalize([1, 2, 3])) { error in
            guard case SocketPacketError.tooManyNodes(limit: 3) = error else {
                return XCTFail("Expected a node-budget error, got \(error)")
            }
        }
    }

    func testByteBudgetHasExactBoundaryAndCountsEscapingAndBinary() throws {
        var exact = SocketEmitNormalizer(allowBinary: false, maximumNodes: 2, maximumBytes: 9)
        XCTAssertNotNil(try exact.normalize(["12345"])) // ["12345"] is nine bytes.
        var small = SocketEmitNormalizer(allowBinary: false, maximumBytes: 8)
        XCTAssertThrowsError(try small.normalize(["12345"])) { error in
            guard case SocketPacketError.payloadTooLarge(limit: 8) = error else {
                return XCTFail("Expected a byte-budget error, got \(error)")
            }
        }
        var escaped = SocketEmitNormalizer(allowBinary: false, maximumBytes: 5)
        XCTAssertThrowsError(try escaped.normalize(["\n"])) // escaped spelling needs six bytes
        var binary = SocketEmitNormalizer(allowBinary: true, maximumBytes: 66)
        XCTAssertThrowsError(try binary.normalize([Data([1])])) // [] + byte + placeholder allowance
    }

    func testBinaryPlaceholderBudgetsAreCheckedBeforeShredding() throws {
        var tooSmall = SocketEmitNormalizer(allowBinary: true, maximumNodes: 5)
        XCTAssertThrowsError(try tooSmall.normalize([Data()])) { error in
            guard case SocketPacketError.tooManyNodes(limit: 5) = error else {
                return XCTFail("Expected a placeholder node-budget error")
            }
        }
        var exact = SocketEmitNormalizer(allowBinary: true, maximumNodes: 6)
        let values = try XCTUnwrap(try exact.normalize([Data()]) as? [Any])
        let packet = SocketPacket.packetFromEmit(values, id: -1, nsp: "/", ack: false)
        var wire = SocketEmitNormalizer(allowBinary: false, maximumNodes: 6)
        XCTAssertNotNil(try wire.normalize(packet.data))

        var shallow = SocketEmitNormalizer(allowBinary: true)
        XCTAssertNotNil(try shallow.normalize(Data(), depth: SocketPacket.maximumEmitNestingDepth - 1))
        var deep = SocketEmitNormalizer(allowBinary: true)
        XCTAssertThrowsError(try deep.normalize(Data(), depth: SocketPacket.maximumEmitNestingDepth)) { error in
            guard case SocketPacketError.nestingTooDeep = error else {
                return XCTFail("Expected a placeholder depth error")
            }
        }
    }

    func testFoundationBudgetsCountDictionaryKeysAndMutableLeaves() {
        var keys = SocketEmitNormalizer(allowBinary: true, maximumNodes: 2)
        XCTAssertThrowsError(try keys.normalize(["key": 1] as NSDictionary))
        var text = SocketEmitNormalizer(allowBinary: false, maximumBytes: 8)
        XCTAssertThrowsError(try text.normalize(NSMutableString(string: "123456789")))
        var data = SocketEmitNormalizer(allowBinary: true, maximumBytes: 2)
        XCTAssertThrowsError(try data.normalize(NSMutableData(length: 3)!))
    }

    func testHandBuiltPacketRejectsCycleBeforeJSONSerialization() {
        let value = NSMutableDictionary()
        value.setObject(value, forKey: "self" as NSString)
        defer { value.removeAllObjects() }
        let packet = SocketPacket(type: .event, data: ["cycle", value], nsp: "/")
        XCTAssertThrowsError(try packet.encodedPacketString()) { error in
            guard case SocketPacketError.cyclicPayload = error else {
                return XCTFail("Expected a cycle error, got \(error)")
            }
        }
    }

    func testPublicEmitRejectsCycleBeforeAckRegistration() {
        let value = NSMutableArray()
        value.add(value)
        defer { value.removeAllObjects() }
        var events = 0
        var acks = 0
        manager.handleQueue.sync {
            manager.retries = 3
            socket.on(clientEvent: .error) { data, _ in
                events += 1
                guard case .cyclicPayload? = data.last as? SocketPacketError else {
                    return XCTFail("Expected an error event for the cycle")
                }
            }
            socket.emit("cycle", value) { error, _ in
                acks += 1
                guard case .cyclicPayload? = error as? SocketPacketError else {
                    return XCTFail("Expected an acknowledgement error for the cycle")
                }
            }
            XCTAssertEqual(events, 1)
            XCTAssertEqual(acks, 1)
            XCTAssertEqual(socket.currentAck, -1)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            XCTAssertEqual(socket.testRetryQueueCount, 0)
            XCTAssertTrue(engine.sentPackets.isEmpty)
        }
    }

    func testTimedAndRawEmitsRejectCyclesWithoutRetainingAcks() {
        let value = NSMutableDictionary()
        value.setObject(value, forKey: "self" as NSString)
        defer { value.removeAllObjects() }
        var acks = 0
        var events = 0
        manager.handleQueue.sync {
            socket.on(clientEvent: .error) { _, _ in events += 1 }
            socket.timeout(after: .infinity).emit("cycle", value) { error, _ in
                acks += 1
                guard case .cyclicPayload? = error as? SocketPacketError else {
                    return XCTFail("Expected a timed-emit cycle error")
                }
            }
            socket.rawEmitView.emit("cycle", with: [value])
            XCTAssertEqual(acks, 1)
            XCTAssertEqual(events, 2)
            XCTAssertTrue(socket.ackHandlers.pendingTimedAckIDs.isEmpty)
            XCTAssertTrue(engine.sentPackets.isEmpty)
        }
    }

    func testDisconnectedCyclicEmitIsNeverFlushedOnReconnect() {
        let value = NSMutableArray()
        value.add(value)
        defer { value.removeAllObjects() }
        manager.handleQueue.sync {
            socket.setTestStatus(.notConnected)
            socket.emit("cycle", value)
            socket.didConnect(toNamespace: "/", payload: ["sid": "test"])
            socket.emit("good", 1)
            XCTAssertEqual(engine.sentPackets.map { $0.0 }, ["2[\"good\",1]"])
        }
    }
}
