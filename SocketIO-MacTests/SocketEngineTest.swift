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
    var client: SocketIOClient!
    var engine: SocketEngine!

    override func setUp() {
        super.setUp()
        client = SocketIOClient(socketURL: URL(string: "http://localhost")!)
        engine = SocketEngine(client: client, url: URL(string: "http://localhost")!, options: nil)

        client.setTestable()
    }

    func testBasicPollingMessage() {
        let expect = expectation(description: "Basic polling test")
        client.on("blankTest") {data, ack in
            expect.fulfill()
        }

        engine.parsePollingMessage("15:42[\"blankTest\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testTwoPacketsInOnePollTest() {
        let finalExpectation = expectation(description: "Final packet in poll test")
        var gotBlank = false

        client.on("blankTest") {data, ack in
            gotBlank = true
        }

        client.on("stringTest") {data, ack in
            if let str = data[0] as? String, gotBlank {
                if str == "hello" {
                    finalExpectation.fulfill()
                }
            }
        }

        engine.parsePollingMessage("15:42[\"blankTest\"]24:42[\"stringTest\",\"hello\"]")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEngineDoesErrorOnUnknownTransport() {
        let finalExpectation = expectation(description: "Unknown Transport")

        client.on("error") {data, ack in
            if let error = data[0] as? String, error == "Unknown transport" {
                finalExpectation.fulfill()
            }
        }

        engine.parseEngineMessage("{\"code\": 0, \"message\": \"Unknown transport\"}")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEngineDoesErrorOnUnknownMessage() {
        let finalExpectation = expectation(description: "Engine Errors")

        client.on("error") {data, ack in
            finalExpectation.fulfill()
        }

        engine.parseEngineMessage("afafafda")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEngineDecodesUTF8Properly() {
        let expect = expectation(description: "Engine Decodes utf8")

        client.on("stringTest") {data, ack in
            XCTAssertEqual(data[0] as? String, "lïne one\nlīne \rtwo𦅙𦅛", "Failed string test")
            expect.fulfill()
        }

        let stringMessage = "42[\"stringTest\",\"lïne one\\nlīne \\rtwo𦅙𦅛\"]"

        engine.parsePollingMessage("\(stringMessage.utf16.count):\(stringMessage)")
        waitForExpectations(timeout: 3, handler: nil)
    }

    func testEncodeURLProperly() {
        engine.connectParams = [
            "created": "2016-05-04T18:31:15+0200"
        ]

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&created=2016-05-04T18%3A31%3A15%2B0200")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&created=2016-05-04T18%3A31%3A15%2B0200")

        engine.connectParams = [
            "forbidden": "!*'();:@&=+$,/?%#[]\" {}"
        ]

        XCTAssertEqual(engine.urlPolling.query, "transport=polling&b64=1&forbidden=%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%2F%3F%25%23%5B%5D%22%20%7B%7D")
        XCTAssertEqual(engine.urlWebSocket.query, "transport=websocket&forbidden=%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%2F%3F%25%23%5B%5D%22%20%7B%7D")
    }

    func testBase64Data() {
        let expect = expectation(description: "Engine Decodes base64 data")
        let b64String = "b4aGVsbG8NCg=="
        let packetString = "451-[\"test\",{\"test\":{\"_placeholder\":true,\"num\":0}}]"

        client.on("test") {data, ack in
            if let data = data[0] as? Data, let string = String(data: data, encoding: .utf8) {
                XCTAssertEqual(string, "hello")
            }

            expect.fulfill()
        }

        engine.parseEngineMessage(packetString)
        engine.parseEngineMessage(b64String)

        waitForExpectations(timeout: 3, handler: nil)
    }
}
