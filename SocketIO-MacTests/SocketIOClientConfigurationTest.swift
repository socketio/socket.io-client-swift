//
//  TestSocketIOClientConfiguration.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 8/13/16.
//
//

import XCTest
import SocketIO

class TestSocketIOClientConfiguration: XCTestCase {
    var config = [] as SocketIOClientConfiguration

    override func setUp() {
        super.setUp()
        
        config = [.Log(false), .ForceNew(true)]
    }

    func testReplaceSameOption() {
        config.insert(.Log(true))
        
        XCTAssertEqual(config.count, 2)
        
        switch config[0] {
        case let .Log(log):
            XCTAssertTrue(log)
        default:
            XCTFail()
        }
    }
    
    func testIgnoreIfExisting() {
        config.insert(.ForceNew(false), replacing: false)
        
        XCTAssertEqual(config.count, 2)
        
        switch config[1] {
        case let .ForceNew(new):
            XCTAssertTrue(new)
        default:
            XCTFail()
        }
    }
}
