import XCTest
@testable import SocketIO

final class StateRecoveryE2ETest: XCTestCase {
    private var server: TestServerProcess!
    private var managers = [SocketManager]()
    private var pendingAuth = [ObjectIdentifier: [String: Any]]()

    override func tearDown() {
        server?.stop()
        server = nil
        managers.removeAll()
        pendingAuth.removeAll()
        super.tearDown()
    }

    // MARK: Helpers

    private func startServer(
        serverScript: String = "server.js",
        recoveryWindowMs: Int? = nil
    ) throws {
        server = try TestServerProcess.start(serverScript: serverScript, recoveryWindowMs: recoveryWindowMs)
    }

    private func makeClient(
        auth: [String: Any]? = nil,
        forceNew: Bool = true
    )
        -> (SocketManager, SocketIOClient) {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        let config: SocketIOClientConfiguration = [
            .log(false),
            .reconnects(true),
            .reconnectWait(1),
            .forceNew(forceNew)
        ]
        let manager = SocketManager(socketURL: url, config: config)
        managers.append(manager)
        let socket = manager.defaultSocket
        if let auth {
            pendingAuth[ObjectIdentifier(socket)] = auth
        }
        return (manager, socket)
    }

    private func adminEmit(event: String, args: [Any], binary: Bool = false) throws {
        let body = try JSONSerialization.data(withJSONObject: ["args": args])
        let suffix = binary ? "&binary=true" : ""
        let (status, _) = try server.admin("/admin/emit?event=\(event)\(suffix)", body: body)
        XCTAssertEqual(status, 200)
    }

    private func adminEmitRaw(sid: String, event: String, args: [Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: ["args": args])
        let (status, responseBody) = try server.admin("/admin/emit-raw?sid=\(sid)&event=\(event)", body: body)
        XCTAssertEqual(status, 200, String(data: responseBody, encoding: .utf8) ?? "")
    }

    private func adminKillTransport(sid: String) throws {
        let (status, _) = try server.admin("/admin/kill-transport?sid=\(sid)")
        XCTAssertEqual(status, 200)
    }

    private func adminKillTransportAndBlockNewConnections(
        sid: String,
        durationMs: Int
    ) throws {
        let (status, _) = try server.admin("/admin/kill-transport-and-block-new-connections?sid=\(sid)&durationMs=\(durationMs)")
        XCTAssertEqual(status, 200)
    }

    private func adminKillTransportAndEmitOnDisconnect(
        sid: String,
        event: String,
        argsList: [[Any]]
    ) throws {
        let body = try JSONSerialization.data(withJSONObject: ["argsList": argsList])
        let (status, _) = try server.admin("/admin/kill-transport-and-emit-on-disconnect?sid=\(sid)&event=\(event)", body: body)
        XCTAssertEqual(status, 200)
    }

    private func adminLastAuth(sid: String) throws -> [String: Any]? {
        let (status, body) = try server.admin("/admin/last-auth?sid=\(sid)", method: "GET")
        XCTAssertEqual(status, 200)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return obj?["auth"] as? [String: Any]
    }

    private func adminSocketLive(sid: String) throws -> Bool {
        let (status, body) = try server.admin("/admin/socket-live?sid=\(sid)", method: "GET")
        XCTAssertEqual(status, 200)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return obj?["live"] as? Bool ?? false
    }

    private func waitUntilSocketNotLive(
        sid: String,
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try !adminSocketLive(sid: sid) {
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        if try !adminSocketLive(sid: sid) {
            return
        }

        XCTFail("timed out waiting for sid \(sid) to disappear server-side before reconnect")
    }

    private func waitForConnect(_ socket: SocketIOClient, timeout: TimeInterval = 10) -> [String: Any]? {
        let expect = expectation(description: "connected")
        var capturedPayload: [String: Any]?
        socket.once(clientEvent: .connect) { data, _ in
            capturedPayload = data.dropFirst().first as? [String: Any]
            expect.fulfill()
        }
        let auth = pendingAuth.removeValue(forKey: ObjectIdentifier(socket))
        socket.connect(withPayload: auth)
        wait(for: [expect], timeout: timeout)
        return capturedPayload
    }

    func testA3_freshConnectReportsNotRecoveredButHasPid() throws {
        try startServer()
        let (_, socket) = makeClient()
        let payload = waitForConnect(socket)

        XCTAssertEqual(payload?["recovered"] as? Bool, false)
        XCTAssertNotNil(socket._pid, "server with recovery enabled must assign pid")
        XCTAssertFalse(socket.recovered)
    }

    func testA1_happyRecoveryDeliversMissedEvents() throws {
        try startServer()
        let (_, socket) = makeClient()
        XCTAssertFalse(socket.recovered)
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)

        // Receive 3 events baseline
        let baseline = expectation(description: "3 baseline events")
        baseline.expectedFulfillmentCount = 3
        var preKill: [String] = []
        socket.on("pre") { data, _ in
            if let body = data.first as? String { preKill.append(body) }
            baseline.fulfill()
        }
        for i in 0..<3 { try adminEmit(event: "pre", args: ["pre-\(i)"]) }
        wait(for: [baseline], timeout: 10)

        // Kill transport abruptly
        try adminKillTransport(sid: originalSid)

        // Emit 2 missed events while disconnected
        try adminEmit(event: "missed", args: ["missed-0"])
        try adminEmit(event: "missed", args: ["missed-1"])

        // Expect reconnect + both missed events
        let recoveredExpect = expectation(description: "reconnected and recovered")
        let missed = expectation(description: "2 missed events")
        missed.expectedFulfillmentCount = 2
        var gotMissed: [String] = []
        var sawRecovered = false
        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            if payload?["recovered"] as? Bool == true {
                sawRecovered = true
                recoveredExpect.fulfill()
            }
        }
        socket.on("missed") { data, _ in
            if let body = data.first as? String { gotMissed.append(body) }
            missed.fulfill()
        }

        wait(for: [recoveredExpect, missed], timeout: 15)
        XCTAssertTrue(sawRecovered)
        XCTAssertTrue(socket.recovered)
        XCTAssertEqual(socket.sid, originalSid)
        XCTAssertEqual(gotMissed.sorted(), ["missed-0", "missed-1"])
    }

    func testA1_replayedMissedEventsCanArriveBeforeRecoveredConnect() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)

        let baseline = expectation(description: "3 baseline events")
        baseline.expectedFulfillmentCount = 3
        socket.on("pre") { _, _ in
            baseline.fulfill()
        }
        for i in 0..<3 { try adminEmit(event: "pre", args: ["pre-\(i)"]) }
        wait(for: [baseline], timeout: 10)

        let missedDelivered = expectation(description: "2 missed events delivered")
        missedDelivered.expectedFulfillmentCount = 2
        let recoveredConnect = expectation(description: "recovered connect")
        var eventOrder = [String]()
        var sawRecoveredConnect = false

        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            guard payload?["recovered"] as? Bool == true else { return }
            sawRecoveredConnect = true
            eventOrder.append("connect")
            recoveredConnect.fulfill()
        }
        socket.on("missed") { data, _ in
            if let body = data.first as? String {
                eventOrder.append("missed:\(body)")
            }
            missedDelivered.fulfill()
        }

        try adminKillTransportAndEmitOnDisconnect(
            sid: originalSid,
            event: "missed",
            argsList: [["missed-0"], ["missed-1"]]
        )

        wait(for: [missedDelivered, recoveredConnect], timeout: 15)
        let missed0Index = try XCTUnwrap(eventOrder.firstIndex(of: "missed:missed-0"))
        let missed1Index = try XCTUnwrap(eventOrder.firstIndex(of: "missed:missed-1"))
        let connectIndex = try XCTUnwrap(eventOrder.firstIndex(of: "connect"))
        XCTAssertLessThan(missed0Index, connectIndex)
        XCTAssertLessThan(missed1Index, connectIndex)
        XCTAssertTrue(sawRecoveredConnect)
    }

    func testA2_windowExpiryProducesFreshSession() throws {
        try startServer(recoveryWindowMs: 2000)
        let (manager, socket) = makeClient()
        manager.reconnectWaitMax = 1
        manager.randomizationFactor = 0
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)
        let originalPid = try XCTUnwrap(socket._pid)

        let reconnectBeforeExpiry = expectation(description: "reconnect before 3 second wait completes")
        reconnectBeforeExpiry.isInverted = true
        let waitedThreeSeconds = expectation(description: "waited 3 seconds")
        let freshConnect = expectation(description: "auto-reconnect outside recovery window")
        var reconnectPayload: [String: Any]?
        var didWaitThreeSeconds = false
        let timingLock = NSLock()
        socket.on(clientEvent: .connect) { data, _ in
            timingLock.lock()
            defer { timingLock.unlock() }

            guard reconnectPayload == nil else { return }
            guard didWaitThreeSeconds else {
                reconnectBeforeExpiry.fulfill()
                return
            }

            reconnectPayload = data.dropFirst().first as? [String: Any]
            freshConnect.fulfill()
        }

        try adminKillTransportAndBlockNewConnections(sid: originalSid, durationMs: 3200)

        DispatchQueue.global().socketAsyncAfter(deadline: .now() + 3) {
            timingLock.lock()
            didWaitThreeSeconds = true
            timingLock.unlock()
            waitedThreeSeconds.fulfill()
        }

        wait(for: [reconnectBeforeExpiry], timeout: 3.0)
        wait(for: [waitedThreeSeconds], timeout: 0.5)
        wait(for: [freshConnect], timeout: 15)

        XCTAssertEqual(reconnectPayload?["recovered"] as? Bool, false)
        XCTAssertFalse(socket.recovered)
        XCTAssertNotEqual(socket.sid, originalSid)
        XCTAssertNotNil(socket._pid)
        XCTAssertNotEqual(socket._pid, originalPid)
    }

    func testA4_explicitDisconnectThenConnectStartsFreshSessionWithinWindow() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let originalSid = try XCTUnwrap(socket.sid)
        let originalPid = try XCTUnwrap(socket._pid)
        XCTAssertNil(socket._lastOffset)

        let seededRecoveryState = expectation(description: "received event that seeds recovery state")
        var seededEvent: [Any]?
        socket.once("seed") { data, _ in
            seededEvent = data
            seededRecoveryState.fulfill()
        }
        try adminEmit(event: "seed", args: ["seed-0"])
        wait(for: [seededRecoveryState], timeout: 10)

        XCTAssertEqual(seededEvent?.first as? String, "seed-0")
        XCTAssertNotNil(socket._lastOffset, "receiving one event should seed recovery offset before reconnect")

        let didDisconnect = expectation(description: "explicit disconnect observed")
        let didReconnectFresh = expectation(description: "manual reconnect starts fresh session")
        var reconnectPayload: [String: Any]?

        socket.once(clientEvent: .disconnect) { _, _ in
            didDisconnect.fulfill()
        }
        socket.once(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            reconnectPayload = payload
            didReconnectFresh.fulfill()
        }

        socket.disconnect()
        wait(for: [didDisconnect], timeout: 10)

        try waitUntilSocketNotLive(sid: originalSid)

        socket.connect()
        wait(for: [didReconnectFresh], timeout: 10)

        XCTAssertEqual(reconnectPayload?["recovered"] as? Bool, false)
        XCTAssertFalse(socket.recovered)
        XCTAssertNotEqual(socket.sid, originalSid)
        XCTAssertNotNil(socket._pid)
        XCTAssertNotEqual(socket._pid, originalPid)
    }

    func testA5_authAndPidOffsetCoexistOnReconnectHandshake() throws {
        try startServer()
        let (_, socket) = makeClient(auth: ["token": "tok-123"])
        _ = waitForConnect(socket)
        let firstSid = try XCTUnwrap(socket.sid)

        let received = expectation(description: "event")
        let offsetCaptured = expectation(description: "offset captured after packet handling")
        var eventOffset: String?
        socket.on("msg") { data, _ in
            eventOffset = data.last as? String
            received.fulfill()
            socket.manager?.handleQueue.socketAsync {
                offsetCaptured.fulfill()
            }
        }
        try adminEmit(event: "msg", args: ["seed"])
        wait(for: [received, offsetCaptured], timeout: 10)
        XCTAssertNotNil(eventOffset, "server must append trailing String offset on seeded event")
        XCTAssertNotNil(socket._lastOffset, "receiving one event should seed recovery offset before reconnect")
        XCTAssertEqual(socket._lastOffset, eventOffset)

        try adminKillTransport(sid: firstSid)

        let reconnected = expectation(description: "reconnected recovered")
        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            if payload?["recovered"] as? Bool == true { reconnected.fulfill() }
        }
        wait(for: [reconnected], timeout: 10)

        let auth = try adminLastAuth(sid: firstSid)
        XCTAssertEqual(auth?["token"] as? String, "tok-123")
        XCTAssertNotNil(auth?["pid"])
        XCTAssertNotNil(auth?["offset"])
    }

    func testA6_offsetAdvancesPerEvent() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)

        var received: [[Any]] = []
        let received5 = expectation(description: "received 5 events")
        received5.expectedFulfillmentCount = 5
        socket.on("msg") { data, _ in
            received.append(data)
            received5.fulfill()
        }

        for i in 0..<5 {
            try adminEmit(event: "msg", args: ["body-\(i)"])
        }
        wait(for: [received5], timeout: 10)

        // Offset is the last String arg appended by the server adapter.
        let lastArgs = received.last ?? []
        XCTAssertTrue(lastArgs.last is String, "server must append offset string on each event")
        XCTAssertNotNil(socket._lastOffset)
        // _lastOffset should equal the offset string of the most recent event.
        XCTAssertEqual(socket._lastOffset, lastArgs.last as? String)
    }

    func testA6_offsetsAdvanceAcrossAllBroadcastEvents() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)

        var offsets = [String]()
        let received5 = expectation(description: "received 5 events with offsets")
        received5.expectedFulfillmentCount = 5
        socket.on("msg") { data, _ in
            if let offset = data.last as? String {
                offsets.append(offset)
            }
            received5.fulfill()
        }

        for i in 0..<5 {
            try adminEmit(event: "msg", args: ["body-\(i)"])
        }
        wait(for: [received5], timeout: 10)

        XCTAssertEqual(offsets.count, 5, "all 5 events must include trailing String offsets")
        XCTAssertEqual(Set(offsets).count, 5, "offsets must change across broadcast events")
        XCTAssertEqual(socket._lastOffset, offsets.last)
    }


    func testA8_binaryEventsAreRecoveredAcrossReconnect() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let firstSid = try XCTUnwrap(socket.sid)

        let seededRecoveryState = expectation(description: "received event that seeds recovery state")
        let seedOffsetCaptured = expectation(description: "seed offset captured after packet handling")
        var seedOffset: String?
        socket.once("seed") { data, _ in
            seedOffset = data.last as? String
            seededRecoveryState.fulfill()
            socket.manager?.handleQueue.socketAsync {
                seedOffsetCaptured.fulfill()
            }
        }
        try adminEmit(event: "seed", args: ["seed-0"])
        wait(for: [seededRecoveryState, seedOffsetCaptured], timeout: 10)
        XCTAssertNotNil(seedOffset, "server must append trailing String offset on seeded event")
        XCTAssertEqual(socket._lastOffset, seedOffset)

        let recoveredBinaryEvent = expectation(description: "recovered binary event")
        let recoveredConnect = expectation(description: "recovered reconnect")
        var payload: Data?
        socket.on(clientEvent: .connect) { data, _ in
            let connectPayload = data.dropFirst().first as? [String: Any]
            if connectPayload?["recovered"] as? Bool == true {
                recoveredConnect.fulfill()
            }
        }
        socket.on("bin") { data, _ in
            payload = data.compactMap { $0 as? Data }.first
            recoveredBinaryEvent.fulfill()
        }

        try adminKillTransportAndBlockNewConnections(sid: firstSid, durationMs: 1200)
        try adminEmit(
            event: "bin",
            args: ["b64:AQIDBA=="],
            binary: true
        )

        wait(for: [recoveredBinaryEvent, recoveredConnect], timeout: 15)
        XCTAssertEqual(payload, Data([1, 2, 3, 4]))
        XCTAssertTrue(socket.recovered)
    }

    func testA9_oversizedOffsetIsDroppedOnClient() throws {
        try startServer()
        let (_, socket) = makeClient()
        _ = waitForConnect(socket)
        let firstSid = try XCTUnwrap(socket.sid)

        let seededRecoveryState = expectation(description: "received event that seeds recovery state")
        let seedOffsetCaptured = expectation(description: "seed offset captured after packet handling")
        var safeOffset: String?
        socket.once("seed") { data, _ in
            safeOffset = data.last as? String
            seededRecoveryState.fulfill()
            socket.manager?.handleQueue.socketAsync {
                seedOffsetCaptured.fulfill()
            }
        }
        try adminEmit(event: "seed", args: ["seed-0"])
        wait(for: [seededRecoveryState, seedOffsetCaptured], timeout: 10)

        let safeOffsetValue = try XCTUnwrap(safeOffset)
        XCTAssertEqual(socket._lastOffset, safeOffsetValue)

        let oversizedOffset = String(repeating: "x", count: 300)
        let oversizedEventDelivered = expectation(description: "oversized raw event delivered")
        let oversizedOffsetCaptureDrained = expectation(description: "oversized raw event offset capture drained")
        var oversizedEventArgs: [Any]?
        socket.once("oversized") { data, _ in
            oversizedEventArgs = data
            oversizedEventDelivered.fulfill()
            socket.manager?.handleQueue.socketAsync {
                oversizedOffsetCaptureDrained.fulfill()
            }
        }
        try adminEmitRaw(sid: firstSid, event: "oversized", args: ["body-0", oversizedOffset])
        wait(for: [oversizedEventDelivered, oversizedOffsetCaptureDrained], timeout: 10)

        XCTAssertEqual(oversizedEventArgs?.first as? String, "body-0")
        XCTAssertEqual(oversizedEventArgs?.last as? String, oversizedOffset)
        XCTAssertEqual(socket._lastOffset, safeOffsetValue)
        XCTAssertNotEqual(socket._lastOffset, oversizedOffset)

        let recoveredConnect = expectation(description: "recovered reconnect")
        socket.on(clientEvent: .connect) { data, _ in
            let payload = data.dropFirst().first as? [String: Any]
            if payload?["recovered"] as? Bool == true {
                recoveredConnect.fulfill()
            }
        }

        try adminKillTransportAndBlockNewConnections(sid: firstSid, durationMs: 1200)
        wait(for: [recoveredConnect], timeout: 15)

        XCTAssertTrue(socket.recovered)
        let auth = try adminLastAuth(sid: firstSid)
        XCTAssertEqual(auth?["offset"] as? String, safeOffsetValue)
        XCTAssertNotEqual(auth?["offset"] as? String, oversizedOffset)
    }

    func testA10_adminEndpointRequiresSecret() throws {
        try startServer()

        func rawPing(secret: String? = nil) -> Int {
            let url = URL(string: "http://127.0.0.1:\(server.port)/admin/ping")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 5
            if let secret {
                req.setValue(secret, forHTTPHeaderField: "X-Admin-Secret")
            }

            let sem = DispatchSemaphore(value: 0)
            var status = -1
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse {
                    status = http.statusCode
                }
                sem.signal()
            }.resume()

            _ = sem.wait(timeout: .now() + 5)
            return status
        }

        XCTAssertEqual(rawPing(), 401)
        XCTAssertEqual(rawPing(secret: "wrong-secret"), 401)

        let (status, body) = try server.admin("/admin/ping")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(data: body, encoding: .utf8), "pong")
    }
}
