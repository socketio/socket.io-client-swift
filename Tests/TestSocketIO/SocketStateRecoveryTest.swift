import XCTest
@testable import SocketIO

private extension SocketPacket {
    init(type: PacketType, nsp: String, placeholders: Int = 0, id: Int = -1, data: [Any]) {
        self.init(type: type, data: data, id: id, nsp: nsp, placeholders: placeholders)
    }
}

private final class HandleEventTrackingSocketIOClient: SocketIOClient {
    var didHandleEventOverride = false

    override func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int = -1) {
        didHandleEventOverride = true
        super.handleEvent(event, data: data, isInternalMessage: isInternalMessage, withAck: ack)
    }
}

final class SocketStateRecoveryTest: XCTestCase {
    private var manager: SocketManager!
    private var socket: SocketIOClient!

    override func setUp() {
        super.setUp()
        manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false)])
        socket = manager.defaultSocket
        socket.setTestable()
    }

    // MARK: U4 — currentConnectPayload merges pid + offset + user payload

    func testU4_currentConnectPayloadMergesPidOffsetAndUser() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "t"]

        let merged = socket.currentConnectPayload()

        XCTAssertEqual(merged?["pid"] as? String, "p1")
        XCTAssertEqual(merged?["offset"] as? String, "offset-1")
        XCTAssertEqual(merged?["token"] as? String, "t")
    }

    // MARK: U4b — user-supplied "pid" / "offset" keys override injected ones

    func testU4b_userKeysOverrideInjectedPidAndOffset() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["pid": "usercustom"]

        let merged = socket.currentConnectPayload()

        XCTAssertEqual(merged?["pid"] as? String, "usercustom",
                       "user key must win; dict iteration order is not guaranteed so compare by key")
        XCTAssertEqual(merged?["offset"] as? String, "offset-1")
    }

    // MARK: U2 — event with String last-arg updates _lastOffset

    func testU2_eventLastStringArgBecomesOffset() {
        socket._pid = "p1"
        let packet = SocketPacket(type: .event, data: ["msg", "hello", "offset-1"], id: -1, nsp: "/", placeholders: 0)
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-1")
    }

    // MARK: U3 — subsequent event with any String last-arg is captured

    func testU3_anyStringLastArgIsCapturedMatchingJS() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1, data: ["msg", "hi"])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "hi")
    }

    // MARK: U3b — non-String last-arg leaves offset unchanged

    func testU3b_nonStringLastArgLeavesOffsetUnchanged() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1, data: ["msg", 42])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-1")
    }

    // MARK: U3c — offset string exceeding cap is dropped (D1 divergence)

    func testU3c_oversizedOffsetStringIsDropped() {
        socket._pid = "p1"
        socket._lastOffset = "safe"
        let big = String(repeating: "x", count: 300)
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1, data: ["msg", big])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "safe", "offset > 256 bytes must not overwrite")
    }

    // MARK: U7 — capture is gated on _pid != nil

    func testU7_offsetNotCapturedWhenPidUnset() {
        XCTAssertNil(socket._pid)
        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "foo", "offset-x"])
        socket.handlePacket(packet)

        XCTAssertNil(socket._lastOffset, "must not capture before server confirms recovery via pid")
    }

    // MARK: U9 — binaryEvent with String last-arg captures offset

    func testU9_binaryEventLastStringArgBecomesOffset() {
        socket._pid = "p1"
        let bin = Data([0x00, 0x01])
        let packet = SocketPacket(type: .binaryEvent, nsp: "/", placeholders: 0, id: -1,
                                  data: ["img", bin, "offset-b"])
        socket.handlePacket(packet)

        XCTAssertEqual(socket._lastOffset, "offset-b")
    }

    // MARK: U9b — replay event during reconnect is buffered until didConnect, then delivered while connected

    func testU9b_replayEventDuringReconnectIsBufferedUntilDidConnectAndCaptured() {
        socket._pid = "p1"
        socket.setTestStatus(.connecting)
        let replayExpect = expectation(description: "replay event delivered after connect")
        let connectExpect = expectation(description: ".connect fired after replay flush")
        var received: [Any] = []
        var order = [String]()
        socket.on("msg") { data, _ in
            received = data
            order.append("msg:\(self.socket.status.description)")
            replayExpect.fulfill()
        }
        socket.on(clientEvent: .connect) { _, _ in
            order.append("connect")
            connectExpect.fulfill()
        }

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "replayed", "offset-r"])
        socket.handlePacket(packet)

        XCTAssertTrue(order.isEmpty, "replay packets must stay buffered before didConnect")
        XCTAssertNil(socket._lastOffset, "offset capture must wait until buffered replay is emitted")

        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [replayExpect, connectExpect], timeout: 1)
        XCTAssertEqual(received.first as? String, "replayed")
        XCTAssertEqual(received.last as? String, "offset-r")
        XCTAssertEqual(socket._lastOffset, "offset-r")
        XCTAssertEqual(order, ["msg:connected", "connect"])
    }

    // MARK: U9c — async replay event ack is sent after buffered replay flush

    func testU9c_asyncReplayEventAckIsSentAfterBufferedReplayFlush() {
        let engine = CaptureEngine()
        manager.engine = engine
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        let expect = expectation(description: "async replay ack sent")
        var errors = [[Any]]()
        socket.on(clientEvent: .error) { data, _ in
            errors.append(data)
        }
        socket.on("msg") { _, ack in
            DispatchQueue.main.socketAsync {
                ack.with("ok")
                expect.fulfill()
            }
        }

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: 7,
                                  data: ["msg", "replayed", "offset-r"])
        socket.handlePacket(packet)

        XCTAssertNil(engine.lastSent, "buffered replay must not ack before didConnect")

        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [expect], timeout: 1)
        let expectedAck = SocketPacket.packetFromEmit(["ok"], id: 7, nsp: "/", ack: true).packetString
        XCTAssertEqual(engine.lastSent, expectedAck)
        XCTAssertTrue(errors.isEmpty, "ack path must not surface not-connected error during replay recovery")
    }

    // MARK: U9d — ordinary emit from replayed handler succeeds once buffered replay flushes on connect

    func testU9d_emitFromReplayedHandlerSucceedsAfterBufferedReplayFlush() {
        let engine = CaptureEngine()
        manager.engine = engine
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        let expect = expectation(description: "emit sent during replay flush")
        var errors = [[Any]]()
        socket.on(clientEvent: .error) { data, _ in
            errors.append(data)
        }
        socket.on("msg") { _, _ in
            self.socket.emit("client-event", "hello")
            expect.fulfill()
        }

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "replayed", "offset-r"])
        socket.handlePacket(packet)

        XCTAssertNil(engine.lastSent, "buffered replay must not trigger emits before didConnect")

        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [expect], timeout: 1)
        let expectedEmit = SocketPacket.packetFromEmit(["client-event", "hello"], id: -1, nsp: "/", ack: false).packetString
        XCTAssertEqual(engine.lastSent, expectedEmit)
        XCTAssertTrue(errors.isEmpty, "ordinary emits from replayed handlers should run after status becomes connected")
    }

    // MARK: U9e — replay window buffers ordinary emits instead of sending them

    func testU9e_replayWindowBuffersOrdinaryEmitDuringReconnect() {
        let engine = CaptureEngine()
        manager.engine = engine
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        socket.emit("msg", "hello")

        XCTAssertNil(engine.lastSent, "Nothing may reach the wire before the socket is connected")

        // The emit is owed, not lost: JS holds it in `sendBuffer` and writes it
        // on the next CONNECT. Before, it was dropped with an `.error`.
        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        let expectedEmit = SocketPacket.packetFromEmit(["msg", "hello"], id: -1, nsp: "/", ack: false).packetString
        XCTAssertEqual(engine.lastSent, expectedEmit)
    }

    // MARK: U9f — buffered replay packets still flow through handleEvent override hook when flushed

    func testU9f_bufferedReplayPacketsUseHandleEventOverrideWhenFlushed() {
        let trackingSocket = HandleEventTrackingSocketIOClient(manager: manager, nsp: "/")
        trackingSocket._pid = "p1"
        trackingSocket.setTestStatus(.connecting)
        trackingSocket.didHandleEventOverride = false

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "hello"])
        trackingSocket.handlePacket(packet)

        XCTAssertFalse(trackingSocket.didHandleEventOverride, "buffered replay should not dispatch before didConnect")

        trackingSocket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        XCTAssertTrue(trackingSocket.didHandleEventOverride)
    }

    // MARK: U9g — buffered replay packets are discarded if the pending connect aborts

    func testU9g_bufferedReplayPacketsAreDiscardedWhenConnectAborts() {
        socket._pid = "p1"
        socket.setTestStatus(.connecting)
        let noReplay = expectation(description: "replay event not delivered after abort")
        noReplay.isInverted = true
        socket.on("msg") { _, _ in
            noReplay.fulfill()
        }

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "replayed", "offset-r"])
        socket.handlePacket(packet)

        socket.abortPendingConnect()
        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [noReplay], timeout: 0.1)
        XCTAssertNil(socket._lastOffset, "discarded replay packets must not advance offset")
    }

    // MARK: U9h — direct emitAck outside replay callback is still rejected during reconnect

    func testU9h_directEmitAckOutsideReplayCallbackIsRejectedDuringReconnect() {
        let engine = CaptureEngine()
        manager.engine = engine
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        let expect = expectation(description: ".error fired")
        var captured: [Any] = []
        socket.on(clientEvent: .error) { data, _ in
            captured = data
            expect.fulfill()
        }

        socket.emitAck(7, with: ["ok"])

        wait(for: [expect], timeout: 1)
        XCTAssertNil(engine.lastSent)
        XCTAssertEqual(captured.first as? String, "Tried emitting when not connected")
    }

    // MARK: U5 — reconnect with same pid → recovered=true

    func testU5_sameServerPidSetsRecoveredTrue() {
        socket._pid = "p1"
        let expect = expectation(description: ".connect fired")
        var connectData: [Any] = []
        socket.on(clientEvent: .connect) { data, _ in
            connectData = data
            expect.fulfill()
        }
        socket.setTestStatus(.connecting)
        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [expect], timeout: 1)
        XCTAssertEqual(socket._pid, "p1")
        XCTAssertTrue(socket.recovered)
        let payload = connectData.dropFirst().first as? [String: Any]
        XCTAssertEqual(payload?["recovered"] as? Bool, true)
    }

    // MARK: U6 — reconnect with different pid → recovered=false, _pid overwritten

    func testU6_differentServerPidResetsRecovered() {
        socket._pid = "p1"
        socket.setTestRecovered(true)            // simulate previous true state
        let expect = expectation(description: ".connect fired")
        socket.on(clientEvent: .connect) { _, _ in expect.fulfill() }
        socket.setTestStatus(.connecting)
        socket.didConnect(toNamespace: "/", payload: ["sid": "s3", "pid": "p2"])

        wait(for: [expect], timeout: 1)
        XCTAssertEqual(socket._pid, "p2")
        XCTAssertFalse(socket.recovered)
    }


    // MARK: U11 — clearRecoveryState resets pid, offset, and recovered

    func testU11_clearRecoveryStateResetsAllFields() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.setTestRecovered(true)

        socket.clearRecoveryState()

        XCTAssertNil(socket._pid)
        XCTAssertNil(socket._lastOffset)
        XCTAssertFalse(socket.recovered)
    }

    // MARK: U11b — clearRecoveryState discards buffered replay packets from prior session

    func testU11b_clearRecoveryStateDiscardsBufferedReplayPackets() {
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        let noReplay = expectation(description: "stale replay not delivered after clearRecoveryState")
        noReplay.isInverted = true
        socket.on("msg") { _, _ in
            noReplay.fulfill()
        }

        let replayPacket = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                        data: ["msg", "prior-session", "offset-prior"])
        socket.handlePacket(replayPacket)

        socket.clearRecoveryState()

        // Next session CONNECT ack arrives (new pid, fresh identity)
        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p2"])

        wait(for: [noReplay], timeout: 0.1)
        XCTAssertEqual(socket._pid, "p2")
        XCTAssertNil(socket._lastOffset,
                     "buffered replay from prior identity must not advance offset of new session")
    }

    // MARK: U9i — replay handler disconnecting mid-flush must not advance offset past undelivered packets

    func testU9i_replayHandlerDisconnectStopsOffsetAdvanceForUndeliveredPackets() {
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        let firstHandled = expectation(description: "first replay delivered")
        let secondNotHandled = expectation(description: "second replay not delivered after disconnect")
        secondNotHandled.isInverted = true

        socket.on("first") { _, _ in
            self.socket.disconnect()
            firstHandled.fulfill()
        }
        socket.on("second") { _, _ in
            secondNotHandled.fulfill()
        }

        let first = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                 data: ["first", "a", "offset-a"])
        let second = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["second", "b", "offset-b"])
        socket.handlePacket(first)
        socket.handlePacket(second)

        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [firstHandled, secondNotHandled], timeout: 0.1)
        XCTAssertEqual(socket._lastOffset, "offset-a",
                       "offset must stop at the last delivered packet; undelivered buffered packets must not advance it")
    }

    // MARK: U9j — didConnect skips .connect emission if replay flush already disconnected socket

    func testU9j_didConnectSkipsConnectEmissionWhenReplayDisconnects() {
        socket._pid = "p1"
        socket.setTestStatus(.connecting)

        let msgHandled = expectation(description: "replay delivered")
        let noConnect = expectation(description: ".connect not emitted after replay-triggered disconnect")
        noConnect.isInverted = true

        socket.on("msg") { _, _ in
            self.socket.disconnect()
            msgHandled.fulfill()
        }
        socket.on(clientEvent: .connect) { _, _ in
            noConnect.fulfill()
        }

        let packet = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                  data: ["msg", "forced-out", "offset-x"])
        socket.handlePacket(packet)

        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [msgHandled, noConnect], timeout: 0.1)
        XCTAssertEqual(socket.status, .disconnected,
                       "status must reflect the replay-triggered disconnect, not bounce back to connected")
    }

    // MARK: U1 — fresh connect stores pid, recovered=false

    func testU1_freshConnectStoresPidAndRecoveredFalse() {
        let expect = expectation(description: ".connect fired with recovered=false")
        var connectData: [Any] = []
        socket.on(clientEvent: .connect) { data, _ in
            connectData = data
            expect.fulfill()
        }

        // Reset status so didConnect runs (setTestable sets it to .connected)
        socket.setTestStatus(.connecting)

        socket.didConnect(toNamespace: "/", payload: ["sid": "s1", "pid": "p1"])

        wait(for: [expect], timeout: 1)
        XCTAssertEqual(socket._pid, "p1")
        XCTAssertFalse(socket.recovered)
        XCTAssertEqual(connectData.first as? String, "/")
        let payload = connectData.dropFirst().first as? [String: Any]
        XCTAssertEqual(payload?["recovered"] as? Bool, false)
        XCTAssertEqual(payload?["pid"] as? String, "p1")
    }


    // MARK: U10 — server omits pid → _pid stays nil, recovered=false

    func testU10_serverOmitsPidLeavesStateClean() {
        let expect = expectation(description: ".connect fired")
        socket.on(clientEvent: .connect) { _, _ in expect.fulfill() }
        socket.setTestStatus(.connecting)
        socket.didConnect(toNamespace: "/", payload: ["sid": "s1"])

        wait(for: [expect], timeout: 1)
        XCTAssertNil(socket._pid)
        XCTAssertFalse(socket.recovered)
    }

    // MARK: U12 — CONNECT_ERROR path does not clear _pid (matches JS)

    func testU12_errorPacketDoesNotClearPid() {
        socket._pid = "p1"
        // Simulate the packet branch without driving the engine
        socket.handleEvent("error", data: ["boom"], isInternalMessage: true, withAck: -1)
        XCTAssertEqual(socket._pid, "p1", "pid must survive internal error dispatch")
    }

    // MARK: U13 — explicit disconnect preserves pid + offset; next payload carries both

    func testU13_disconnectPreservesRecoveryStateForNextConnect() {
        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "t"]

        // engine is nil on a test-only socket; disconnectSocket uses engine?.send (safe no-op)
        socket.disconnect()

        XCTAssertEqual(socket._pid, "p1", "disconnect must not clear pid")
        XCTAssertEqual(socket._lastOffset, "offset-1", "disconnect must not clear offset")

        let merged = socket.currentConnectPayload()
        XCTAssertEqual(merged?["pid"] as? String, "p1")
        XCTAssertEqual(merged?["offset"] as? String, "offset-1")
        XCTAssertEqual(merged?["token"] as? String, "t")
    }

    // MARK: Manager injection — reconnect path sends {pid, offset, ...user}

    func testConnectSocketSendsPidAndOffsetOnReconnect() throws {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)

        socket._pid = "p1"
        socket._lastOffset = "offset-1"
        socket.connectPayload = ["token": "t"]

        manager.connectSocket(socket, withPayload: nil)

        let sent = try XCTUnwrap(engine.lastSent)
        XCTAssertTrue(sent.hasPrefix("0/,"),
                      "expected \"0<nsp>,<json>\", got \(sent)")
        let jsonStart = sent.index(sent.startIndex, offsetBy: 3)
        let jsonStr = String(sent[jsonStart...])
        let data = Data(jsonStr.utf8)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["pid"] as? String, "p1")
        XCTAssertEqual(obj["offset"] as? String, "offset-1")
        XCTAssertEqual(obj["token"] as? String, "t")
    }

    // MARK: Manager injection — invalid payload emits .error and aborts

    func testConnectSocketEmitsErrorOnInvalidPayload() {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)

        // Date() is not JSON-serializable via JSONSerialization; it throws.
        socket.connectPayload = ["bad": Date()]

        let expect = expectation(description: ".error fired")
        var captured: [Any] = []
        socket.on(clientEvent: .error) { data, _ in
            captured = data
            expect.fulfill()
        }

        manager.connectSocket(socket, withPayload: nil)

        wait(for: [expect], timeout: 1)
        XCTAssertNil(engine.lastSent, "engine must NOT be sent to on serialization failure")
        let msg = captured.first as? String
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("serialization failed") ?? false)
    }

    // MARK: Public connect — invalid payload emits .error and clears pending connect state

    func testConnectWithInvalidPayloadEmitsErrorAndResetsStatus() {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)
        socket.setTestStatus(.notConnected)

        let expect = expectation(description: ".error fired")
        let noDisconnect = expectation(description: ".disconnect not fired")
        noDisconnect.isInverted = true
        var captured: [Any] = []
        socket.on(clientEvent: .error) { data, _ in
            captured = data
            expect.fulfill()
        }
        socket.on(clientEvent: .disconnect) { _, _ in
            noDisconnect.fulfill()
        }

        socket.connect(withPayload: ["bad": Date()], timeoutAfter: 0, withHandler: nil)

        wait(for: [expect, noDisconnect], timeout: 0.1)
        XCTAssertNil(engine.lastSent, "engine must NOT be sent to on serialization failure")
        let msg = captured.first as? String
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("serialization failed") ?? false)
        XCTAssertEqual(socket.status, .notConnected, "immediate connect failure must settle out of .connecting without disconnecting")
    }

    func testConnectWithInvalidPayloadStillFiresTimeoutHandlerWithoutDisconnecting() {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)
        socket.setTestStatus(.notConnected)

        let errorExpect = expectation(description: ".error fired")
        let timeoutExpect = expectation(description: "timeout handler fired")
        let noDisconnect = expectation(description: ".disconnect not fired")
        noDisconnect.isInverted = true
        var captured: [Any] = []

        socket.on(clientEvent: .error) { data, _ in
            captured = data
            errorExpect.fulfill()
        }
        socket.on(clientEvent: .disconnect) { _, _ in
            noDisconnect.fulfill()
        }

        socket.connect(withPayload: ["bad": Date()], timeoutAfter: 0.05, withHandler: {
            timeoutExpect.fulfill()
        })

        wait(for: [errorExpect, timeoutExpect, noDisconnect], timeout: 0.2)
        XCTAssertNil(engine.lastSent, "engine must NOT send CONNECT or namespace leave packets on serialization failure")
        let msg = captured.first as? String
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("serialization failed") ?? false)
    }

    func testTimeoutFailedConnectClearsBufferedReplayPacketsBeforeLaterConnect() {
        let engine = CaptureEngine()
        manager.engine = engine
        manager.setTestStatus(.connected)
        socket.setTestStatus(.notConnected)
        socket._pid = "p1"

        let timeoutExpect = expectation(description: "timeout handler fired")
        let noReplay = expectation(description: "stale replay not delivered")
        noReplay.isInverted = true
        let connectExpect = expectation(description: ".connect fired")
        socket.on("msg") { _, _ in
            noReplay.fulfill()
        }
        socket.on(clientEvent: .connect) { _, _ in
            connectExpect.fulfill()
        }

        socket.connect(timeoutAfter: 0.05, withHandler: {
            timeoutExpect.fulfill()
        })

        let replayPacket = SocketPacket(type: .event, nsp: "/", placeholders: 0, id: -1,
                                        data: ["msg", "stale", "offset-stale"])
        socket.handlePacket(replayPacket)

        wait(for: [timeoutExpect], timeout: 0.2)
        XCTAssertEqual(socket.status, .disconnected, "timeout path should settle to disconnected before later reconnect")

        socket.didConnect(toNamespace: "/", payload: ["sid": "s2", "pid": "p1"])

        wait(for: [connectExpect, noReplay], timeout: 0.1)
        XCTAssertNil(socket._lastOffset, "stale buffered replay packets must not advance offset after timeout")
    }
}

/// Minimal engine stub for capturing `write` calls from `SocketManager.connectSocket`.
/// Mirrors the `TestEngine` pattern used in side-effect tests but records the last sent string.
final class CaptureEngine: SocketEngineSpec {
    weak var client: SocketEngineClient?
    private(set) var lastSent: String?
    /// Every packet written, in order. `lastSent` only keeps the most recent one,
    /// which cannot show that a flushed buffer preserved its order.
    private(set) var sentPackets = [String]()
    let closed = false
    let connected = true
    var connectParams: [String: Any]? = nil
    let cookies: [HTTPCookie]? = nil
    let engineQueue = DispatchQueue.main
    var extraHeaders: [String: String]? = nil
    let fastUpgrade = false
    let forcePolling = false
    let forceWebsockets = false
    let polling = false
    let probing = false
    let sid = ""
    let socketPath = ""
    let urlPolling = URL(string: "http://localhost/")!
    let urlWebSocket = URL(string: "http://localhost/")!


    required init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.client = client
    }

    init() {}

    func connect() {}
    func didError(reason: String) {}
    func disconnect(reason: String) {}
    func doFastUpgrade() {}
    func flushWaitingForPostToWebSocket() {}
    func parseEngineData(_ data: Data) {}
    func parseEngineMessage(_ message: String) {}

    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?) {
        lastSent = msg
        sentPackets.append(msg)
        completion?()
    }
}

extension SocketStateRecoveryTest {
    func testInitialReceiveBufferPreservesBinaryAckAndFlushesBeforeSendAndConnect() throws {
        let engine = MockEngine()
        manager.engine = engine
        socket.setTestStatus(.connecting)
        XCTAssertNil(socket._pid)
        let bytes = Data([0, 1, 255])
        var order: [String] = []
        socket.on("early") { data, ack in
            XCTAssertEqual(data.first as? Data, bytes)
            order.append("receive")
            ack.with("received")
        }
        engine.onWrite = { _, _ in order.append("write") }
        socket.on(clientEvent: .connect) { _, _ in order.append("connect") }
        socket.emit("outgoing")
        socket.handlePacket(SocketPacket(type: .binaryEvent, data: ["early", bytes], id: 42, nsp: "/", placeholders: 0))
        XCTAssertTrue(order.isEmpty)
        socket.didConnect(toNamespace: "/", payload: ["sid": "first"])
        XCTAssertEqual(order.first, "receive")
        XCTAssertEqual(order.last, "connect")
        // Ack emit may enqueue on handleQueue; wait for it before inspecting frames.
        let settled = expectation(description: "ACK sent")
        manager.handleQueue.socketAsync { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        let packets = try engine.sentPackets.map { try manager.parseString($0.0) }
        XCTAssertTrue(packets.contains { $0.type == .ack && $0.id == 42 && $0.data.first as? String == "received" })
        XCTAssertEqual(packets.filter { $0.type == .event }.map { $0.event }, ["outgoing"])
    }

    func testInitialReceiveBufferIsDiscardedAfterAuthenticationRejection() {
        socket.setTestStatus(.connecting)
        var calls = 0
        socket.on("early") { _, _ in calls += 1 }
        socket.handlePacket(SocketPacket(type: .event, data: ["early", "old session"], id: -1, nsp: "/", placeholders: 0))
        socket.handlePacket(SocketPacket(type: .error, data: [["message": "denied"]], id: -1, nsp: "/", placeholders: 0))
        XCTAssertEqual(socket.status, .notConnected)
        socket.didConnect(toNamespace: "/", payload: ["sid": "new identity"])
        XCTAssertEqual(calls, 0)
    }
}
