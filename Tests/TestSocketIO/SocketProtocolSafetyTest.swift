import Foundation
import XCTest
@testable import SocketIO

/// Malformed-peer regressions. Each input used to reach an unchecked index/cast,
/// or could retain an unbounded/incoherent binary reconstruction.
final class SocketProtocolSafetyTest: XCTestCase {
    private func parser(_ options: SocketParserOptions = SocketParserOptions()) -> SocketManager {
        SocketManager(socketURL: URL(string: "http://localhost")!, config: [.log(false), .parserOptions(options)])
    }

    // socket.io-parser/test/parser.js — "throw an error upon parsing error"
    // (every input JS rejects), plus the Swift-only binary attachment guards.
    func testTruncatedAndOverflowingHeadersAreRejectedWithoutTrapping() {
        let manager = parser()
        for input in ["", "5", "6", "51-", "51", "5-", "5x-[\"x\"]", "5a-", "51.23-",
                      "50-[\"x\"]", "511-[\"x\"]", "59999999999999999999999-[\"x\"]", "999",
                      "442[\"some\",\"data\"", "0/admin,\"invalid\"", "0[]", "1[]", "1/admin,{}",
                      "2/admin,\"invalid", "2/admin,{}", "2[]", "2{}", "2[true]", "2[null]",
                      "2[true,\"foo\"]", "2[null,\"bar\"]", "2[{\"toString\":\"foo\"}]",
                      "2[\"disconnect\",\"123\"]", "3{}", "8"] {
            XCTAssertThrowsError(try manager.parseString(input), input)
        }
    }

    func testOriginalParsingErrorsPreserveNativeErrorCategories() {
        let manager = parser()
        let invalidPayloads = ["442[\"some\",\"data\"", "0/admin,\"invalid\"", "0[]",
                               "1/admin,{}", "2/admin,\"invalid", "2/admin,{}",
                               "2[{\"toString\":\"foo\"}]", "2[true,\"foo\"]",
                               "2[null,\"bar\"]", "2[\"connect\"]", "2[\"disconnect\",\"123\"]"]
        for input in invalidPayloads {
            XCTAssertThrowsError(try manager.parseString(input), input) { error in
                XCTAssertEqual(error as? SocketParsableError, .invalidDataArray)
            }
        }
        for input in ["5", "51", "50-", "5a-", "51.23-"] {
            XCTAssertThrowsError(try manager.parseString(input), input) { error in
                XCTAssertEqual(error as? SocketParsableError, .invalidPacket)
            }
        }
        XCTAssertThrowsError(try manager.parseString("999")) { error in
            XCTAssertEqual(error as? SocketParsableError, .invalidPacketType)
        }
        // Decoder.add(999) is not a representable call to native parseString:
        // the compiler requires String; binary input has its own Data API.
    }

    func testOriginalPacketValidityPayloadCases() throws {
        let manager = parser()
        let valid = try manager.parseString("0")
        XCTAssertEqual(valid.type, .connect)
        XCTAssertEqual(valid.nsp, "/")
        XCTAssertTrue(valid.data.isEmpty)
        for wire in ["0/admin,\"invalid\"", "0[]", "1/admin,{}",
                     "2/admin,\"invalid\"", "2/admin,{}", "2{\"toString\":\"foo\"}",
                     "2[true,\"foo\"]", "2[null,\"bar\"]", "2[\"connect\"]",
                     "2[\"disconnect\",\"123\"]"] {
            XCTAssertThrowsError(try manager.parseString(wire), wire) { error in
                XCTAssertEqual(error as? SocketParsableError, .invalidDataArray)
            }
        }
    }

    /// JS `Decoder.decodeString` only parses a payload `if (str.charAt(++i))`, so
    /// these decode with `data === undefined`. `onevent` (`packet.data || []`)
    /// then emits nothing and `onack` logs "bad ack" — neither is a parse error.
    func testPayloadLessEventAndAckDecodeAsEmptyData() throws {
        let manager = parser()
        for input in ["2", "3", "2/namespace,", "2123", "399"] {
            XCTAssertTrue(try manager.parseString(input).data.isEmpty, input)
        }
        XCTAssertEqual(try manager.parseString("2").type, .event)
        XCTAssertEqual(try manager.parseString("2").id, -1)
        XCTAssertEqual(try manager.parseString("2123").id, 123)
        XCTAssertEqual(try manager.parseString("2/namespace,").nsp, "/namespace")
        XCTAssertEqual(try manager.parseString("399").id, 99)
        XCTAssertEqual(try manager.parseString("2").event, "")
        // A binary header without a payload has no placeholders to fill.
        XCTAssertThrowsError(try manager.parseString("51-"))
    }

    /// JS reads the id with `Number(...)`: an id past `Int` becomes a float that
    /// matches no handler, so the packet is delivered without an acknowledgement
    /// instead of killing the connection.
    func testAckIdBeyondIntIsDeliveredWithoutAnAcknowledgement() throws {
        let manager = parser()
        let event = try manager.parseString("299999999999999999999999999[\"x\"]")
        XCTAssertEqual(event.id, -1)
        XCTAssertEqual(event.event, "x")
        XCTAssertEqual(try manager.parseString("399999999999999999999999999[\"x\"]").id, -1)
    }

    /// The shipped defaults decode everything JS decodes: only `maximumAttachments`
    /// (JS `maxAttachments`) limits a well-formed packet out of the box.
    func testDefaultParserOptionsImposeNoJavaScriptForeignLimits() throws {
        let manager = parser()
        let options = SocketParserOptions()
        XCTAssertEqual(options.maximumAttachments, 10)
        XCTAssertEqual(options.maximumBinaryPacketBytes, .max)
        XCTAssertEqual(options.maximumTextPacketBytes, .max)
        let big = String(repeating: "ü", count: 9 * 1024 * 1024) // > the former 16 MiB cap
        XCTAssertEqual(try manager.parseString("2[\"x\",\"\(big)\"]").args.first as? String, big)
        let deep = String(repeating: "[", count: 120) + String(repeating: "]", count: 120)
        XCTAssertNotNil(try manager.parseString("2[\"x\",\(deep)]"))
    }

    func testAllProtocolReservedNamesAreRejectedAsIncomingEvents() {
        let manager = parser()
        for name in ["connect", "connect_error", "disconnect", "disconnecting", "newListener", "removeListener"] {
            XCTAssertThrowsError(try manager.parseString("2[\"\(name)\"]"), name)
        }
    }

    func testInvalidBinaryPlaceholderIndicesFailAtTheHeader() {
        let manager = parser()
        for index in ["-1", "1", "99", "true", "0.5", "1e300", "\"0\"", "null"] {
            XCTAssertThrowsError(try manager.parseString("51-[\"x\",{\"_placeholder\":true,\"num\":\(index)}]"), index)
        }
        XCTAssertThrowsError(try manager.parseString("51-[\"x\",{\"_placeholder\":true}]"))
    }

    func testUnicodeNamespaceAckAndNestedBinaryRoundTrip() throws {
        let manager = parser()
        var packet = try manager.parseString("52-/é🦧,123[\"x\",{\"nested\":[{\"_placeholder\":true,\"num\":1}]},{\"_placeholder\":true,\"num\":0}]")
        XCTAssertEqual(packet.nsp, "/é🦧")
        XCTAssertEqual(packet.id, 123)
        XCTAssertFalse(packet.addData(Data([1])))
        XCTAssertTrue(packet.addData(Data([2, 3])))
        XCTAssertEqual(packet.args.last as? Data, Data([1]))
        let nested = try XCTUnwrap(packet.args.first as? [String: [Data]])
        XCTAssertEqual(nested["nested"], [Data([2, 3])])
    }

    func testJSONNestingAndTextByteLimitsIncludingEscapedQuotes() throws {
        let manager = parser(SocketParserOptions(maximumTextPacketBytes: 64, maximumNestingDepth: 3))
        XCTAssertNotNil(try manager.parseString("2[\"x\",{\"v\":[1]}]"))
        XCTAssertNotNil(try manager.parseString("2[\"x\",\"[[[\\\"\"]"))
        XCTAssertThrowsError(try manager.parseString("2[\"x\",{\"v\":[[1]]}]"))
        XCTAssertThrowsError(try manager.parseString("2[\"x\",\"" + String(repeating: "ä", count: 40) + "\"]"))
    }


    func testAckZeroNumericEventsAndEmptyAckArray() throws {
        let manager = parser()
        XCTAssertEqual(try manager.parseString("20[\"x\"]").id, 0)
        XCTAssertEqual(try manager.parseString("2[123,\"x\"]").event, "123")
        XCTAssertTrue(try manager.parseString("30[]").data.isEmpty)
    }

    func testLowLevelPacketAlsoRejectsMalformedPlaceholderWithoutTrapping() {
        var packet = SocketPacket(type: .binaryEvent,
            data: ["x", ["_placeholder": true, "num": -1] as [String: Any]], nsp: "/", placeholders: 1)
        XCTAssertFalse(packet.addData(Data([1])))
        XCTAssertTrue(packet.reconstructionFailed)
        XCTAssertEqual(SocketPacket(type: .event, nsp: "/").event, "")
    }

    func testBinaryPacketBudgetIsAggregateAndReleasesOnFailure() throws {
        let manager = parser(SocketParserOptions(maximumBinaryPacketBytes: 3))
        manager.waitingPackets = [try manager.parseString("52-[\"x\",{\"_placeholder\":true,\"num\":0},{\"_placeholder\":true,\"num\":1}]")]
        XCTAssertNil(manager.parseBinaryData(Data([1, 2])))
        XCTAssertEqual(manager.waitingPackets.count, 1)
        XCTAssertNil(manager.parseBinaryData(Data([3, 4])))
        XCTAssertTrue(manager.waitingPackets.isEmpty)
    }

    func testAttachmentLimitCanBeConfiguredWithoutDisablingValidation() throws {
        let manager = parser(SocketParserOptions(maximumAttachments: 12))
        XCTAssertNotNil(try manager.parseString("512-[\"x\"]"))
        XCTAssertThrowsError(try manager.parseString("513-[\"x\"]"))
        XCTAssertFalse(SocketParserOptions(maximumAttachments: 0).isValid)
        XCTAssertTrue(SocketParserOptions(maximumNestingDepth: 1024).isValid)
        XCTAssertFalse(SocketParserOptions(maximumNestingDepth: 1025).isValid)
    }


    func testTextCannotInterleaveBinaryAndFailureIsTerminalUntilReconnect() {
        let manager = parser()
        let engine = ReviewParseEngine(client: manager, url: manager.socketURL, options: nil)
        manager.engine = engine
        manager.setTestStatus(.connected)
        let socket = manager.defaultSocket
        socket.setTestStatus(.connected)
        var events = 0
        socket.on("x") { _, _ in events += 1 }
        manager.parseEngineMessage("51-[\"x\",{\"_placeholder\":true,\"num\":0}]")
        manager.parseEngineMessage("2[\"x\"]")
        manager.parseEngineBinaryData(Data([1]))
        manager.parseEngineMessage("2[\"x\"]")
        let finished = expectation(description: "queued parser operations finished")
        manager.handleQueue.socketAsync { finished.fulfill() }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(engine.reasons, ["parse error"])
        XCTAssertTrue(manager.waitingPackets.isEmpty)
        XCTAssertEqual(events, 0)
    }

    /// socket.io-parser/test/parser.js — "should resume decoding after calling
    /// destroy()". Swift's `destroy()` is the reconnect in `SocketManager.connect()`,
    /// which clears `parserFailed` and `waitingPackets`; the next packet must
    /// decode and be delivered again.
    func testDecodingResumesAfterReconnectClearsTheParserFailure() {
        let manager = parser()
        let engine = ReviewParseEngine(client: manager, url: manager.socketURL, options: nil)
        manager.engine = engine
        manager.setTestStatus(.connected)
        let socket = manager.defaultSocket
        socket.setTestStatus(.connected)
        var received = 0
        socket.on("hello") { _, _ in received += 1 }

        // A binary header owns the stream; the text packet that follows loses
        // framing, which is fatal (JS `Decoder.add` throws "got plaintext data").
        manager.parseEngineMessage("51-[\"hello\",{\"_placeholder\":true,\"num\":0}]")
        manager.parseEngineMessage("2[\"hello\"]")
        drainHandleQueue(of: manager)
        XCTAssertEqual(engine.reasons, ["parse error"])
        XCTAssertEqual(received, 0)

        manager.setTestStatus(.notConnected)
        manager.connect()
        manager.setTestStatus(.connected)
        socket.setTestStatus(.connected)
        manager.parseEngineMessage("2[\"hello\"]")
        drainHandleQueue(of: manager)
        XCTAssertTrue(manager.waitingPackets.isEmpty)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(engine.reasons, ["parse error"])
    }

    private func drainHandleQueue(of manager: SocketManager) {
        let drained = expectation(description: "queued parser operations finished")
        manager.handleQueue.socketAsync { drained.fulfill() }
        wait(for: [drained], timeout: 3)
    }

    func testTwoBinaryHeadersAndEmptyEngineMessageAreFatal() {
        for second in ["51-[\"x\"]", ""] {
            let manager = parser()
            let engine = ReviewParseEngine(client: manager, url: manager.socketURL, options: nil)
            manager.engine = engine
            manager.setTestStatus(.connected)
            manager.parseEngineMessage("51-[\"x\"]")
            manager.parseEngineMessage(second)
            let finished = expectation(description: "second header processed")
            manager.handleQueue.socketAsync { finished.fulfill() }
            wait(for: [finished], timeout: 3)
            XCTAssertEqual(engine.reasons, ["parse error"])
        }
    }
}

/// Deliberately delays engineDidClose so the parser's own terminal fence is tested.
private final class ReviewParseEngine: TestEngine {
    var reasons = [String]()
    override func disconnect(reason: String) { reasons.append(reason) }
}


extension SocketProtocolSafetyTest {
    func testModernConnectErrorPayloadsRemainSupported() throws {
        let manager = parser()
        XCTAssertEqual(try manager.parseString("4\"denied\"").data.first as? String, "denied")
        let packet = try manager.parseString("4/admin,{\"message\":\"denied\",\"data\":{\"code\":401}}")
        XCTAssertEqual(packet.nsp, "/admin")
        XCTAssertEqual((packet.data.first as? [String: Any])?["message"] as? String, "denied")
        for text in ["4", "41", "4true", "4null", "4[]", "4/admin,"] {
            XCTAssertThrowsError(try manager.parseString(text), text)
        }
    }
}

extension SocketProtocolSafetyTest {
    /// Exact malformed sequences from the pinned buffer.js/parser.js. Native
    /// decoding reports a terminal parse error instead of throwing from add().
    func testOriginalMalformedBinarySequencesCloseOnceWithoutDeliveringAnEvent() {
        let sequences: [(String?, Bool, String?)] = [
            ("51-[\"hello\",{\"_placeholder\":true,\"num\":\"splice\"}]", true, nil),
            ("51-[\"hello\",{\"_placeholder\":true,\"num\":1}]", true, nil),
            (nil, true, nil),
            ("51-[\"hello\",{\"_placeholder\":true,\"num\":0}]", false, "2[\"hello\"]"),
            ("5", false, nil)
        ]
        for (header, binary, text) in sequences {
            let manager = parser()
            let engine = ReviewParseEngine(client: manager, url: manager.socketURL, options: nil)
            manager.engine = engine
            manager.setTestStatus(.connected)
            let socket = manager.defaultSocket
            socket.setTestStatus(.connected)
            var deliveries = 0
            socket.on("hello") { _, _ in deliveries += 1 }
            if let header { manager.parseEngineMessage(header) }
            if binary { manager.parseEngineBinaryData(Data("world".utf8)) }
            if let text { manager.parseEngineMessage(text) }
            drainHandleQueue(of: manager)
            XCTAssertEqual(engine.reasons, ["parse error"])
            XCTAssertEqual(deliveries, 0)
            XCTAssertTrue(manager.waitingPackets.isEmpty)
        }
    }

    func testOriginalAttachmentLimitRejectsThreeWhenOnlyTwoAreAllowed() {
        let manager = parser(SocketParserOptions(maximumAttachments: 2))
        XCTAssertThrowsError(try manager.parseString(
            "53-[\"hello\",{\"_placeholder\":true,\"num\":0},{\"_placeholder\":true,\"num\":1},{\"_placeholder\":true,\"num\":2}]"))
        XCTAssertTrue(manager.waitingPackets.isEmpty)
    }

    func testReconnectDiscardsAnUnfinishedBinaryPacketAndDecodesTheNextTextEvent() {
        let manager = parser()
        let engine = ReviewParseEngine(client: manager, url: manager.socketURL, options: nil)
        manager.engine = engine
        manager.setTestStatus(.connected)
        let socket = manager.defaultSocket
        socket.setTestStatus(.connected)
        var deliveries = 0
        socket.on("hello") { data, _ in
            XCTAssertTrue(data.isEmpty)
            deliveries += 1
        }
        manager.parseEngineMessage("51-[\"hello\"]")
        drainHandleQueue(of: manager)
        XCTAssertEqual(manager.waitingPackets.count, 1)
        XCTAssertEqual(deliveries, 0)
        manager.setTestStatus(.notConnected)
        manager.connect()
        manager.setTestStatus(.connected)
        socket.setTestStatus(.connected)
        manager.parseEngineMessage("2[\"hello\"]")
        drainHandleQueue(of: manager)
        XCTAssertEqual(deliveries, 1)
        XCTAssertTrue(manager.waitingPackets.isEmpty)
        XCTAssertTrue(engine.reasons.isEmpty)
        manager.disconnect()
    }
}
