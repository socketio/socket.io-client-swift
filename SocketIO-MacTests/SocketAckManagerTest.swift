//
//  SocketAckManagerTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 04.09.15.
//
//

import XCTest
@testable import SocketIOClientSwift

class SocketAckManagerTest: XCTestCase {
    var ackManager = SocketAckManager()
    
    func testAddAcks() {
        let callbackExpection = self.expectationWithDescription("callbackExpection")
        let itemsArray = ["Hi", "ho"]
        func callback(items: [AnyObject]) {
            callbackExpection.fulfill()
        }
        ackManager.addAck(1, callback: callback)
        ackManager.executeAck(1, items: itemsArray)
        waitForExpectationsWithTimeout(3.0, handler: nil)
        
    }
}
