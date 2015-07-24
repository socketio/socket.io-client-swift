//
//  SocketIO_iOSTests.swift
//  SocketIO-iOSTests
//
//  Created by Nacho Soto on 7/11/15.
//
//

import UIKit
import XCTest

class SocketIO_iOSTests: XCTestCase {
    var socketClient:SocketIOClient!
    
    override func setUp() {
        super.setUp()
        self.socketClient = SocketIOClient(socketURL: "localhost:8080")
        openConnection()
    }
    
    override func tearDown() {
        super.tearDown()
    }
    
    func testConnectionStatus() {
        XCTAssertTrue(socketClient.connected)
        XCTAssertFalse(socketClient.connecting)
        XCTAssertFalse(socketClient.reconnecting)
        XCTAssertFalse(socketClient.closed)
        XCTAssertFalse(socketClient.secure)
    }
    
    func testeventWithAcknowledgements() {
        let sendedValue = 15;
        let expection = self.expectationWithDescription("AcknowledgementTestIncomming")
        func didGetEmit(result:NSArray?) {
            let resultValue = result?.firstObject as! Int
            XCTAssertEqual(sendedValue + 20, resultValue)
            expection.fulfill()
        }
        socketClient.emitWithAck("AcknowledgementTestIncomming", sendedValue)(timeoutAfter: 0, callback: didGetEmit)
        waitForExpectationsWithTimeout(10, handler: nil)
    }
    
    func testoutGoingEmit() {
        let sendedValue = 15;
        let expection = self.expectationWithDescription("firstEmitTestIncomming")
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            let resultValue = result?.firstObject as! Int
            XCTAssertEqual(sendedValue + 10, resultValue)
            expection.fulfill()
        }
        socketClient.on("firstEmitTestOutGoing", callback: didGetEmit)
        socketClient.emit("firstEmitTestIncomming", sendedValue)
        waitForExpectationsWithTimeout(10, handler: nil)
    }
    
    func openConnection() {
        let expection = self.expectationWithDescription("connect")
        socketClient.on("connect") {data, ack in
            expection.fulfill()
        }
        socketClient.connect()
        XCTAssertTrue(socketClient.connecting)
        waitForExpectationsWithTimeout(10, handler: nil)
    }
    
    func testCloseConnection() {
        socketClient.close(fast: false)
        XCTAssertTrue(socketClient.closed)
    }
    
}
