//
//  SocketAckManagerTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 04.09.15.
//
//

import XCTest
@testable import SocketIO

class SocketAckManagerTest : XCTestCase {
    var ackManager = SocketAckManager()

    func testAddAcks() {
        let callbackExpection = expectation(description: "callbackExpection")
        let itemsArray = ["Hi", "ho"]

        func callback(_ items: [Any]) {
            callbackExpection.fulfill()
        }

        ackManager.addAck(1, callback: callback)
        ackManager.executeAck(1, with: itemsArray)

        let result = XCTWaiter().wait(for: [callbackExpection], timeout: 3)
        XCTAssert(result == .completed)
    }

    func testManagerTimeoutAck() {
        let callbackExpection = expectation(description: "Manager should timeout ack with noAck status")

        func callback(_ items: [Any]) {
            XCTAssertEqual(items.count, 1, "Timed out ack should have one value")
            guard let timeoutReason = items[0] as? String else {
                XCTFail("Timeout reason should be a string")

                return
            }

            XCTAssert(timeoutReason == SocketAckStatus.noAck)

            callbackExpection.fulfill()
        }

        ackManager.addAck(1, callback: callback)
        ackManager.timeoutAck(1)

        let result = XCTWaiter().wait(for: [callbackExpection], timeout: 0.2)
        XCTAssert(result == .completed)
    }
}
