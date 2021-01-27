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
    func testBasicPollingMessageV3() {
        let expect = expectation(description: "Basic polling test v3")

        socket.on("blankTest") {data, ack in
            expect.fulfill()
        }

        engine.setConfigs([.version(.two)])
        engine.parsePollingMessage("15:42[\"blankTest\"]")

        waitForExpectations(timeout: 3, handler: nil)
    }

    func testBasicPollingMessage() {
        let expect = expectation(description: "Basic polling test")
        socket.on("blankTest") {data, ack in
            expect.fulfill()
        }

        engine.parsePollingMessage("42[\"blankTest\"]")
        waitForExpectations(timeout: 3, handler: nil)
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
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEngineDoesErrorOnUnknownTransport() {
        let finalExpectation = expectation(description: "Unknown Transport")

        socket.on("error") {data, ack in
            if let error = data[0] as? String, error == "Unknown transport" {
                finalExpectation.fulfill()
            }
        }

        engine.parseEngineMessage("{\"code\": 0, \"message\": \"Unknown transport\"}")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEngineDoesErrorOnUnknownMessage() {
        let finalExpectation = expectation(description: "Engine Errors")

        socket.on("error") {data, ack in
            finalExpectation.fulfill()
        }

        engine.parseEngineMessage("afafafda")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEngineDecodesUTF8Properly() {
        let expect = expectation(description: "Engine Decodes utf8")

        socket.on("stringTest") {data, ack in
            XCTAssertEqual(data[0] as? String, "lïne one\nlīne \rtwo𦅙𦅛", "Failed string test")
            expect.fulfill()
        }

        let stringMessage = "42[\"stringTest\",\"lïne one\\nlīne \\rtwo𦅙𦅛\"]"

        engine.parsePollingMessage("\(stringMessage)")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEncodeURLProperly() {
        engine.connectParams = [
            "created": "2016-05-04T18:31:15+0200"
        ]

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&created=2016-05-04T18%3A31%3A15%2B0200&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&created=2016-05-04T18%3A31%3A15%2B0200&EIO=4")

        engine.connectParams = [
            "forbidden": "!*'();:@&=+$,/?%#[]\" {}^|"
        ]

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&forbidden=%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%2F%3F%25%23%5B%5D%22%20%7B%7D%5E%7C&EIO=4")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&forbidden=%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%2F%3F%25%23%5B%5D%22%20%7B%7D%5E%7C&EIO=4")
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

        waitForExpectations(timeout: 3, handler: nil)
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

    func testSettingCompressAfterConnectDoesNotIgnoreChanges() {
        manager.engine = engine
        manager.setTestStatus(.connected)
        engine.setConnected(true)
        manager.config.insert(.compress)

        XCTAssertEqual(2, manager.config.count)
        XCTAssertTrue(manager.engine!.compress)
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

    func testChangingEngineHeadersAfterInit() {
        engine.extraHeaders = ["Hello": "World"]

        let req = engine.createRequestForPostWithPostWait()

        XCTAssertEqual("World", req.allHTTPHeaderFields?["Hello"])
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
