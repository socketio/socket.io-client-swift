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
        client = SocketIOClient(socketURL: "")
        engine = SocketEngine(client: client, url: "", options: nil)
        
        client.setTestable()
    }
    
    func testBasicPollingMessage() {
        let expectation = expectationWithDescription("Basic polling test")
        client.on("blankTest") {data, ack in
            expectation.fulfill()
        }
        
        engine.parsePollingMessage("15:42[\"blankTest\"]")
        waitForExpectationsWithTimeout(3, handler: nil)
    }
    
    func testTwoPacketsInOnePollTest() {
        let finalExpectation = expectationWithDescription("Final packet in poll test")
        var gotBlank = false
        
        client.on("blankTest") {data, ack in
            gotBlank = true
        }
        
        client.on("stringTest") {data, ack in
            if let str = data[0] as? String where gotBlank {
                if str == "hello" {
                    finalExpectation.fulfill()
                }
            }
        }
        
        engine.parsePollingMessage("15:42[\"blankTest\"]24:42[\"stringTest\",\"hello\"]")
        waitForExpectationsWithTimeout(3, handler: nil)
    }
}
