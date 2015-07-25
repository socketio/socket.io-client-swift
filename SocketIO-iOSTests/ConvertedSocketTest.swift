//
//  ConvertedSocketTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 25.07.15.
//
//

import XCTest
import Foundation

class ConvertedSocketTest: XCTestCase {
    
    var socket:SocketIOClient!
    
    
    let headers = ["testing": "blah", "testing2": "b/:lah"]
    let testCytube = false
    
    override func setUp() {
        super.setUp()
        if testCytube {
            socket = SocketIOClient(socketURL: "https://cytu.be:10443", opts: [
                "forcePolling": false,
                "forceWebsockets": false,
                "log": true
                ])
        } else {
            socket = SocketIOClient(socketURL: "127.0.0.1:8080", opts: [
                "reconnects": true, // default true
                "reconnectAttempts": -1, // default -1
                "reconnectWait": 5, // default 10
                "forcePolling": false,
                "forceWebsockets": false,// default false
                "nsp": "/swift",
                "path": "",
                "extraHeaders": headers,
                //        "connectParams": [
                //            "test": 2.1,
                //            "d": "{}"
                //        ],
                //"cookies": cookieArray
                ])
        }
        openConnection()
    }
    
    override func tearDown() {

        super.tearDown()
    }
    
    func openConnection() {
        let expection = self.expectationWithDescription("connect")
        socket.on("connect") {data, ack in
            expection.fulfill()
        }
        socket.connect()
        XCTAssertTrue(socket.connecting)
        waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func testConnectionStatus() {
        XCTAssertTrue(socket.connected)
        XCTAssertFalse(socket.connecting)
        XCTAssertFalse(socket.reconnecting)
        XCTAssertFalse(socket.closed)
        XCTAssertFalse(socket.secure)
    }
    
    func testEmit() {
        let testName = "testEmit"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            
        }
        abstractSocketEmitTest(testName, emitData: nil, callback: didGetEmit)
    }
    
    func testEmitNull() {
        let testName = "testEmitNull"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let _ = result?.firstObject as? NSNull {
                
            }else
            {
               XCTFail("Should have NSNull as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: NSNull(), callback: didGetEmit)
    }
    
    func testEmitBinary() {
        let testName = "testEmitBinary"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let data = result?.firstObject as? NSData {
                let string = NSString(data: data, encoding: NSUTF8StringEncoding)!
                XCTAssertEqual(string, "gakgakgak2")
            }else {
                XCTFail("Should have NSData as result")
            }
        }
        let data = NSString(string: "gakgakgak2").dataUsingEncoding(NSUTF8StringEncoding)!
        abstractSocketEmitTest(testName, emitData: data, callback: didGetEmit)
    }
    
    func testArrayEmit() {
        let testName = "testEmitArray"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let array = result?.firstObject as? NSArray {
                XCTAssertEqual(array.count, 2)
                XCTAssertEqual(array.firstObject! as! String, "test3")
            }else {
                XCTFail("Should have NSArray as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: ["test1", "test2"], callback: didGetEmit)
    }
    
    func testStringEmit() {
        let testName = "testStringEmit"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let string = result?.firstObject as? String {
                XCTAssertEqual(string, "polo")
            }else {
                XCTFail("Should have String as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: "marco", callback: didGetEmit)
    }
    
    func testBoolEmit() {
        let testName = "testBoolEmit"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let bool = result?.firstObject as? NSNumber {
                XCTAssertTrue(bool.boolValue)
            }else {
                XCTFail("Should have Boolean as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: false, callback: didGetEmit)
    }
    
    func testIntegerEmit() {
        let testName = "testIntegerEmit"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let integer = result?.firstObject as? Int {
                XCTAssertEqual(integer, 20)
            }else {
                XCTFail("Should have Integer as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: 10, callback: didGetEmit)
    }
    
    func testDoubleEmit() {
        let testName = "testDoubleEmit"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let double = result?.firstObject as? NSNumber {
                XCTAssertEqual(double.floatValue, 1.2)
            }else {
                XCTFail("Should have String as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: 1.1, callback: didGetEmit)
    }

    
    func abstractSocketEmitTest(testName:String, emitData:AnyObject?, callback:NormalCallback){
        let expection = self.expectationWithDescription(testName)
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            callback(result, ack)
            expection.fulfill()
        }
        
        socket.on(testName + "Return", callback: didGetEmit)
        if let emitData = emitData {
            socket.emit(testName, emitData)
        } else {
            socket.emit(testName)
        }
        
        waitForExpectationsWithTimeout(5, handler: nil)
    }
    
    func testCloseConnection() {
//        socket.close(fast: false)
//        XCTAssertTrue(socket.closed)
    }
    
}
