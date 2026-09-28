//
//  SocketEngineTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/15/15.
//
//

import XCTest
@testable import SocketIO

class SocketEngineTest: XCTestCase {


    func testBasicPollingMessage() {
        let expect = expectation(description: "Basic polling test")
        socket.on("blankTest") {data, ack in
            expect.fulfill()
        }

        engine.parsePollingMessage("42[\"blankTest\"]")
        wait(for: [expect], timeout: 3)
    }

    func testTwoPacketsInOnePollTest() {
        let finalExpectation = expectation(description: "Final packet in poll test")
        var gotBlank = false

        socket.on("blankTest") {data, ack in
            gotBlank = true
        }

        socket.on("stringTest") {data, ack in
            if let str = data[0] as? String, gotBlank {
                if str == "hello" {
                    finalExpectation.fulfill()
                }
            }
        }

        engine.parsePollingMessage("42[\"blankTest\"]\u{1e}42[\"stringTest\",\"hello\"]")
        wait(for: [finalExpectation], timeout: 3)
    }

    func testEngineDoesErrorOnUnknownTransport() {
        // setTestable() changes status only. Engine events require the
        // subscription that a real connect() establishes through active.
        socket.setTestActive(true)
        manager.reconnects = false
        let finalExpectation = expectation(description: "Unknown Transport")

        socket.on("error") {data, ack in
            if let error = data.first as? String, error == "Unknown transport" {
                finalExpectation.fulfill()
            }
        }

        engine.engineQueue.sync {
            engine.parseEngineMessage("{\"code\": 0, \"message\": \"Unknown transport\"}")
        }
        wait(for: [finalExpectation], timeout: 3)
    }

    /// engine.io-parser/test/index.ts — "should fail to decode a malformed
    /// payload": an undecodable packet becomes `{type: "error", data: "parser
    /// error"}`, which `_onPacket` routes through `_onError` → `_onClose
    /// ("transport error")`. Reporting the error without closing is not enough.
    func testEngineDoesErrorOnUnknownMessage() {
        socket.setTestActive(true)
        manager.reconnects = false
        let finalExpectation = expectation(description: "Engine Errors")

        socket.on("error") {data, ack in
            finalExpectation.fulfill()
        }

        engine.engineQueue.sync {
            engine.parseEngineMessage("afafafda")
        }
        wait(for: [finalExpectation], timeout: 3)
        engine.engineQueue.sync {
            XCTAssertTrue(engine.closed)
            XCTAssertFalse(engine.connected)
        }
    }

    /// The other malformed payloads from the same JS test. `{}` decodes as JSON
    /// but names no error, and must still close rather than be ignored.
    func testEngineClosesOnEveryMalformedEnginePayload() {
        for message in ["{", "{}", "[\"a123\", \"a456\"]"] {
            let manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                        config: [.log(false), .reconnects(false)])
            let engine = SocketEngine(client: manager, url: URL(string: "http://localhost")!, options: nil)
            manager.engine = engine
            engine.parseEngineMessage(message)
            engine.engineQueue.sync { XCTAssertTrue(engine.closed, message) }
        }
    }

    func testEngineDecodesUTF8Properly() {
        let expect = expectation(description: "Engine Decodes utf8")

        socket.on("stringTest") {data, ack in
            XCTAssertEqual(data[0] as? String, "lïne one\nlīne \rtwo𦅙𦅛", "Failed string test")
            expect.fulfill()
        }

        let stringMessage = "42[\"stringTest\",\"lïne one\\nlīne \\rtwo𦅙𦅛\"]"

        engine.parsePollingMessage("\(stringMessage)")
        wait(for: [expect], timeout: 3)
    }

    func testEncodeURLProperly() {
        engine.connectParams = [
            "created": "2016-05-04T18:31:15+0200"
        ]

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&created=2016-05-04T18%3A31%3A15%2B0200&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&created=2016-05-04T18%3A31%3A15%2B0200&EIO=4")

        // encodeURIComponent preserves !, *, apostrophe and parentheses.
        engine.connectParams = [
            "forbidden": "!*'();:@&=+$,/?%#[]\" {}^|"
        ]

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&forbidden=!*'()%3B%3A%40%26%3D%2B%24%2C%2F%3F%25%23%5B%5D%22%20%7B%7D%5E%7C&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&forbidden=!*'()%3B%3A%40%26%3D%2B%24%2C%2F%3F%25%23%5B%5D%22%20%7B%7D%5E%7C&EIO=4")
    }

    func testBase64Data() {
        let expect = expectation(description: "Engine Decodes base64 data")
        let b64String = "baGVsbG8NCg=="
        let packetString = "451-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0}}]"

        socket.on("test") {data, ack in
            if let data = data[0] as? Data, let string = String(data: data, encoding: .utf8) {
                XCTAssertEqual(string, "hello")
            }

            expect.fulfill()
        }

        engine.parseEngineMessage(packetString)
        engine.parseEngineMessage(b64String)

        wait(for: [expect], timeout: 3)
    }

    func testSettingExtraHeadersBeforeConnectSetsEngineExtraHeaders() {
        let newValue = ["hello": "world"]

        manager.engine = engine
        manager.setTestStatus(.notConnected)
        manager.config = [.extraHeaders(["new": "value"])]
        manager.config.insert(.extraHeaders(newValue), replacing: true)

        XCTAssertEqual(2, manager.config.count)
        XCTAssertEqual(manager.engine!.extraHeaders!, newValue)

        for config in manager.config {
            switch config {
            case let .extraHeaders(headers):
                XCTAssertTrue(headers.keys.contains("hello"), "It should contain hello header key")
                XCTAssertFalse(headers.keys.contains("new"), "It should not contain old data")
            case .path:
                continue
            default:
                XCTFail("It should only have two configs")
            }
        }
    }

    func testSettingExtraHeadersAfterConnectDoesNotIgnoreChanges() {
        let newValue = ["hello": "world"]

        manager.engine = engine
        manager.setTestStatus(.connected)
        engine.setConnected(true)
        manager.config = [.extraHeaders(["new": "value"])]
        manager.config.insert(.extraHeaders(["hello": "world"]), replacing: true)

        XCTAssertEqual(2, manager.config.count)
        XCTAssertEqual(manager.engine!.extraHeaders!, newValue)
    }

    func testSettingPathAfterConnectDoesNotIgnoreChanges() {
        let newValue = "/newpath/"

        manager.engine = engine
        manager.setTestStatus(.connected)
        engine.setConnected(true)
        manager.config.insert(.path(newValue))

        XCTAssertEqual(1, manager.config.count)
        XCTAssertEqual(manager.engine!.socketPath, newValue)
    }

    func testSettingForcePollingAfterConnectDoesNotIgnoreChanges() {
        manager.engine = engine
        manager.setTestStatus(.connected)
        engine.setConnected(true)
        manager.config.insert(.forcePolling(true))

        XCTAssertEqual(2, manager.config.count)
        XCTAssertTrue(manager.engine!.forcePolling)
    }

    func testSettingForceWebSocketsAfterConnectDoesNotIgnoreChanges() {
        manager.engine = engine
        manager.setTestStatus(.connected)
        engine.setConnected(true)
        manager.config.insert(.forceWebsockets(true))

        XCTAssertEqual(2, manager.config.count)
        XCTAssertTrue(manager.engine!.forceWebsockets)
    }

    /// Engine.IO has to pause the polling transport before it sends the upgrade
    /// packet. Sending it while a POST is still on the wire makes the server
    /// answer that late POST with HTTP 400; the client discards the error and
    /// never resends, so the payload is lost without a trace.
    func testUpgradeIsDeferredUntilPollAndPostSettled() {
        engine.setConnected(true)
        engine.setFastUpgrade(true)

        engine.waitingForPoll = true
        engine.waitingForPost = true
        XCTAssertFalse(engine.canSendUpgradePacket, "Neither poll nor post settled")

        engine.waitingForPoll = false
        XCTAssertFalse(
            engine.canSendUpgradePacket, "A POST is still on the wire; upgrading loses it")

        engine.waitingForPost = false
        XCTAssertTrue(engine.canSendUpgradePacket, "Both settled, the upgrade may proceed")

        engine.waitingForPoll = true
        XCTAssertFalse(engine.canSendUpgradePacket, "An outstanding poll still blocks the upgrade")
    }

    /// A polling write attempted while `fastUpgrade` is set can never be POSTed,
    /// because `doRequest` refuses to write on a transport that is upgrading. It
    /// must therefore not mark the transport as writing, or the deferred upgrade
    /// would wait for a callback that never comes and the engine would end up
    /// with no active transport at all. (`upgradeTransport()` itself no longer
    /// enqueues anything; the packet here stands for an application write.)
    func testPendingUpgradeDoesNotMarkTheTransportAsWriting() {
        engine.setConnected(true)
        engine.setFastUpgrade(true)
        engine.waitingForPoll = false
        engine.waitingForPost = false

        engine.sendPollMessage("", withType: .noop, withData: [])

        XCTAssertFalse(engine.waitingForPost, "A POST that cannot start must not block the upgrade")
        XCTAssertTrue(engine.canSendUpgradePacket)
    }

    func testNoUpgradePacketWithoutAPendingUpgrade() {
        engine.setConnected(true)
        engine.waitingForPoll = false
        engine.waitingForPost = false

        XCTAssertFalse(
            engine.canSendUpgradePacket, "Without fastUpgrade there is nothing to upgrade")
    }

    /// engine.io v4 servers advertise a `maxPayload` in the handshake and answer
    /// a POST above it with HTTP 413, discarding every packet it carried. The
    /// batch therefore has to stop short of the limit, like `getWritablePackets()`
    /// in engine.io-client does.
    func testPostBatchStopsAtTheServersMaxPayload() {
        engine.setMaxPayload(20)
        engine.postWait = [
            (msg: "4aaaaaaaaa", completion: nil), // 10 bytes
            (msg: "4bbbbbbbbb", completion: nil), // would make 21 with the separator
            (msg: "4ccccccccc", completion: nil)
        ]

        let req = engine.createRequestForPostWithPostWait()

        XCTAssertEqual(String(data: req.httpBody!, encoding: .utf8), "4aaaaaaaaa")
        XCTAssertEqual(engine.postWait.count, 2, "Packets that did not fit stay queued for the next POST")
    }

    func testPostBatchFillsUpToTheLimitExactly() {
        engine.setMaxPayload(21)
        engine.postWait = [
            (msg: "4aaaaaaaaa", completion: nil),
            (msg: "4bbbbbbbbb", completion: nil),
            (msg: "4ccccccccc", completion: nil)
        ]

        let req = engine.createRequestForPostWithPostWait()

        XCTAssertEqual(req.httpBody!.count, 21, "A payload of exactly maxPayload is still allowed")
        XCTAssertEqual(engine.postWait.count, 1)
    }

    /// A packet cannot be split, so the reference client sends it alone and lets
    /// the server reject it, rather than stalling the queue forever.
    func testAPacketLargerThanMaxPayloadIsStillSentOnItsOwn() {
        engine.setMaxPayload(5)
        engine.postWait = [
            (msg: "4aaaaaaaaa", completion: nil),
            (msg: "4b", completion: nil)
        ]

        let req = engine.createRequestForPostWithPostWait()

        XCTAssertEqual(String(data: req.httpBody!, encoding: .utf8), "4aaaaaaaaa")
        XCTAssertEqual(engine.postWait.count, 1)
    }

    func testMaxPayloadCountsBytesNotCharacters() {
        engine.setMaxPayload(12)
        engine.postWait = [
            (msg: "4\u{e4}\u{e4}\u{e4}\u{e4}\u{e4}", completion: nil), // 11 bytes, 6 characters
            (msg: "4b", completion: nil)
        ]

        let req = engine.createRequestForPostWithPostWait()

        XCTAssertEqual(req.httpBody!.count, 11)
        XCTAssertEqual(engine.postWait.count, 1, "Counting characters instead of bytes would have fit both")
    }

    func testWithoutAnAdvertisedMaxPayloadEverythingGoesInOneBatch() {
        XCTAssertNil(engine.maxPayload, "No handshake happened, so there is no limit to respect")
        engine.postWait = [
            (msg: "4aaaaaaaaa", completion: nil),
            (msg: "4bbbbbbbbb", completion: nil)
        ]

        let req = engine.createRequestForPostWithPostWait()

        XCTAssertEqual(req.httpBody!.count, 21)
        XCTAssertTrue(engine.postWait.isEmpty)
    }


    func testOnlyTheSentPacketsGetTheirCompletionCalled() {
        engine.setMaxPayload(20)
        var firstFired = false
        var secondFired = false
        engine.postWait = [
            (msg: "4aaaaaaaaa", completion: { firstFired = true }),
            (msg: "4bbbbbbbbb", completion: { secondFired = true })
        ]

        _ = engine.createRequestForPostWithPostWait()

        XCTAssertTrue(firstFired)
        XCTAssertFalse(secondFired, "A packet that is still queued has not been written yet")
    }

    /// A batch capped at `maxPayload` can leave packets queued. They belong to the
    /// session that was closed, and their ack ids mean nothing to the next one.
    func testANewSessionDoesNotInheritUnsentPackets() {
        engine.postWait = [(msg: "4left over from the previous session", completion: nil)]

        let reset = expectation(description: "engine reset")
        engine.connect()
        engine.engineQueue.socketAsync { reset.fulfill() }
        wait(for: [reset], timeout: 3)

        XCTAssertTrue(engine.postWait.isEmpty, "Stale packets would be sent under a sid that never issued their ack ids")
    }

    /// url.ts — "works with ipv6". A bracketed IPv6 literal has to survive URL
    /// construction; losing the brackets produces a host nothing can resolve.
    func testIpv6HostSurvivesEngineUrlConstruction() {
        let engine = SocketEngine(client: manager, url: URL(string: "http://[::1]:8080")!, options: nil)

        XCTAssertEqual(engine.urlPolling.host, "::1")
        XCTAssertEqual(engine.urlPolling.port, 8080)
        XCTAssertEqual(engine.urlWebSocket.host, "::1")
        XCTAssertEqual(engine.urlWebSocket.scheme, "ws")
    }

    func testChangingEngineHeadersAfterInit() {
        engine.extraHeaders = ["Hello": "World"]

        let req = engine.createRequestForPostWithPostWait()

        XCTAssertEqual("World", req.allHTTPHeaderFields?["Hello"])
    }

    // MARK: engine.io-client — Polling.uri() / WS.uri() cache buster

    private func queryItems(of url: URL) -> [String: String] {
        var dict = [String: String]()
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            dict[item.name] = item.value ?? ""
        }

        return dict
    }

    func testPollingUrlsCarryADifferentCacheBusterEachTime() {
        let first = queryItems(of: engine.urlPollingWithSid)
        let second = queryItems(of: engine.urlPollingWithSid)

        XCTAssertNotNil(first["t"], "Polling requests must carry the cache-busting parameter by default")
        XCTAssertNotNil(second["t"])
        XCTAssertFalse(first["t"]!.isEmpty)
        XCTAssertNotEqual(first["t"], second["t"], "The value must be unique per request")
    }

    func testWebSocketUrlHasNoCacheBusterByDefault() {
        XCTAssertNil(queryItems(of: engine.urlWebSocketWithSid)["t"],
                     "The WebSocket URL is only stamped when timestampRequests is explicitly true")
    }

    func testTimestampRequestsTrueStampsWebSocketAndFalseDisablesPolling() {
        engine.setConfigs([.timestampRequests(true)])

        XCTAssertNotNil(queryItems(of: engine.urlWebSocketWithSid)["t"])
        XCTAssertNotNil(queryItems(of: engine.urlPollingWithSid)["t"])

        engine.setConfigs([.timestampRequests(false)])

        XCTAssertNil(queryItems(of: engine.urlPollingWithSid)["t"])
        XCTAssertNil(queryItems(of: engine.urlWebSocketWithSid)["t"])
    }

    func testTimestampParamRenamesTheCacheBuster() {
        engine.setConfigs([.timestampParam("ts")])

        let items = queryItems(of: engine.urlPollingWithSid)

        XCTAssertNotNil(items["ts"])
        XCTAssertNil(items["t"], "A renamed parameter must not also appear under the default name")
    }

    func testCacheBusterLeavesExistingQueryParametersUnchanged() {
        engine.connectParams = ["foo": "bar"]

        let polling = queryItems(of: engine.urlPollingWithSid)

        XCTAssertEqual(polling["transport"], "polling")
        XCTAssertEqual(polling["b64"], "1")
        XCTAssertEqual(polling["EIO"], "4")
        XCTAssertNotNil(polling["sid"], "The sid parameter must still be present")
        XCTAssertEqual(polling["foo"], "bar", "connectParams must survive the appended parameter")
        XCTAssertNotNil(polling["t"])

        let ws = queryItems(of: engine.urlWebSocketWithSid)

        XCTAssertEqual(ws["transport"], "websocket")
        XCTAssertEqual(ws["EIO"], "4")
        XCTAssertEqual(ws["foo"], "bar")
    }

    /// A handshake that finishes after the engine was closed (e.g. the GET
    /// still in flight when `.connectTimeout(0)` closed it) must not revive
    /// the engine. JS-aligned with the `readyState` guard in `_onPacket`.
    func testOpenPacketArrivingAfterCloseIsIgnored() {
        manager.reconnects = false
        engine.disconnect(reason: "timeout")
        engine.engineQueue.sync {}
        XCTAssertTrue(engine.closed, "disconnect must close the engine")

        engine.parseEngineMessage("0{\"sid\":\"x\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000}")

        XCTAssertFalse(engine.connected, "A late OPEN packet must not reopen a closed engine")
        XCTAssertTrue(engine.closed)

        // Pump handleQueue so a stray engineDidOpen would have run by now.
        let settled = expectation(description: "queues settle")
        manager.handleQueue.socketAsync { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertFalse(engine.connected)
        XCTAssertNotEqual(manager.status, .connected, "The manager must not see an open from a closed engine")
    }

    /// The close notification is one-shot per session: closing twice still
    /// clears state twice but tells the manager only once. Otherwise the
    /// zombie engine's eventual failure delivers a second close that can
    /// start a spurious reconnect cycle.
    func testClosingTwiceNotifiesTheClientOnce() {
        let countingManager = CloseCountingManager(socketURL: URL(string: "http://localhost")!)
        countingManager.reconnects = false
        let testEngine = SocketEngine(client: countingManager, url: URL(string: "http://localhost")!, options: nil)

        testEngine.disconnect(reason: "a")
        testEngine.disconnect(reason: "b")
        testEngine.engineQueue.sync {}

        let settled = expectation(description: "close notifications settle")
        countingManager.handleQueue.socketAsync { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(countingManager.closeCount, 1, "closeOutEngine must notify exactly once per session")
    }

    /// `doRequest` binds every polling request to the URLSession it was issued on and
    /// drops responses from a previous session. A fresh engine has no session at all —
    /// `session` is only created in `resetEngine`, which runs inside `_connect` and does
    /// networking — so the stale-session half cannot be driven without a network round
    /// trip and is covered by `testOpenPacketArrivingAfterCloseIsIgnored` plus the E2E
    /// `testAttemptReconnectsAfterAFailedReconnect`. This pins the no-session half: with
    /// no session no request starts and the callback never fires.
    func testDoRequestWithoutSessionNeverCallsBack() {
        XCTAssertNil(engine.session, "Fresh engine has no session without networking (resetEngine runs only in _connect)")

        let never = expectation(description: "callback for a request that never started must not fire")
        never.isInverted = true

        engine.doRequest(for: URLRequest(url: URL(string: "http://localhost/")!)) { _, _, _ in
            never.fulfill()
        }

        wait(for: [never], timeout: 0.5)
    }

    var manager: SocketManager!
    var socket: SocketIOClient!
    var engine: SocketEngine!

    override func setUp() {
        super.setUp()

        manager = SocketManager(socketURL: URL(string: "http://localhost")!)
        socket = manager.defaultSocket
        engine = SocketEngine(client: manager, url: URL(string: "http://localhost")!, options: nil)

        socket.setTestable()
    }
}

private class CloseCountingManager: SocketManager {
    var closeCount = 0

    override func engineDidClose(reason: String) {
        closeCount += 1
        super.engineDidClose(reason: reason)
    }
}


extension SocketEngineTest {
    func testEngineIO4CannotBeOverriddenAndEscapedQueriesStayIntact() {
        for query in ["EIO=3", "containsEIO=x", "EIO=3&EIO=2", "%45IO=3&value=a%2Bb%2Fc%3Ad"] {
            let url = URL(string: "http://localhost/?" + query)!
            let engine = SocketEngine(client: manager, url: url, config: [.timestampRequests(false)])
            for candidate in [engine.urlPolling, engine.urlWebSocket, engine.urlPollingHandshake,
                              engine.urlPollingWithSid, engine.urlWebSocketWithSid] {
                let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false)!
                XCTAssertEqual(components.queryItems?.filter { $0.name == "EIO" }.map { $0.value }, ["4"])
                if query.contains("value=") {
                    XCTAssertTrue(components.percentEncodedQuery!.contains("value=a%2Bb%2Fc%3Ad"))
                }
            }
        }
        let engine = SocketEngine(client: manager, url: URL(string: "http://localhost")!,
                                  config: [.connectParams(["EIO": "3"]), .timestampRequests(false)])
        XCTAssertEqual(URLComponents(url: engine.urlPolling, resolvingAgainstBaseURL: false)!
            .queryItems?.filter { $0.name == "EIO" }.map { $0.value }, ["4"])
    }
}
