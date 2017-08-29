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
        ackManager.executeAck(1, with: itemsArray, onQueue: DispatchQueue.main)

        waitForExpectations(timeout: 3.0, handler: nil)
    }

    func testManagerTimeoutAck() {
        let callbackExpection = expectation(description: "Manager should timeout ack with noAck status")
        let itemsArray = ["Hi", "ho"]

        func callback(_ items: [Any]) {
            XCTAssertEqual(items.count, 1, "Timed out ack should have one value")
            guard let timeoutReason = items[0] as? String else {
                XCTFail("Timeout reason should be a string")

                return
            }

            XCTAssertEqual(timeoutReason, SocketAckStatus.noAck.rawValue)

            callbackExpection.fulfill()
        }

        ackManager.addAck(1, callback: callback)
        ackManager.timeoutAck(1, onQueue: DispatchQueue.main)

        waitForExpectations(timeout: 0.2, handler: nil)
    }
}
