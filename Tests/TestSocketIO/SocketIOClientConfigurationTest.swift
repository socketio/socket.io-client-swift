//
//  TestSocketIOClientConfiguration.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 8/13/16.
//
//

import XCTest
import SocketIO

class TestSocketIOClientConfiguration : XCTestCase {
    func testReplaceSameOption() {
        config.insert(.log(true))

        XCTAssertEqual(config.count, 2)

        switch config[0] {
        case let .log(log):
            XCTAssertTrue(log)
        default:
            XCTFail()
        }
    }

    func testIgnoreIfExisting() {
        config.insert(.forceNew(false), replacing: false)

        XCTAssertEqual(config.count, 2)

        switch config[1] {
        case let .forceNew(new):
            XCTAssertTrue(new)
        default:
            XCTFail()
        }
    }

    var config = [] as SocketIOClientConfiguration

    override func setUp() {
        config = [.log(false), .forceNew(true)]

        super.setUp()
    }
}
