//
//  ConvertedSocketTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 25.07.15.
//
//

import XCTest
import Foundation

class SocketEmitTest: XCTestCase {
    static let TEST_TIMEOUT = 5.0
    var socket:SocketIOClient!
    let headers = ["testing": "blah", "testing2": "b/:lah"]
    var testKind = TestKind.Emit
    
    override func setUp() {
        super.setUp()
        socket = SocketIOClient(socketURL: "127.0.0.1:8080", opts: [
            "reconnects": true, // default true
            "reconnectAttempts": -1, // default -1
            "reconnectWait": 5, // default 10
            "forcePolling": false,
            "forceWebsockets": false,// default false
            "path": "",
            "extraHeaders": headers])
        openConnection()
    }
    
    override func tearDown() {
        socket.close(fast: false)
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
        let testName = "basicTest"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            
        }
        abstractSocketEmitTest(testName, emitData: nil, callback: didGetEmit)
    }
    
    func testEmitNull() {
        let testName = "testNull"
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
        let testName = "testBinary"
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
        let testName = "testArray"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let array = result?.firstObject as? NSArray {
                XCTAssertEqual(array.count, 2)
                XCTAssertEqual(array.firstObject! as! String, "test3")
                XCTAssertEqual(array.lastObject! as! String, "test4")
            }else {
                XCTFail("Should have NSArray as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: ["test1", "test2"], callback: didGetEmit)
    }
    
    func testStringEmit() {
        let testName = "testString"
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
        let testName = "testBool"
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
        let testName = "testInteger"
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
        let testName = "testDouble"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let double = result?.firstObject as? NSNumber {
                XCTAssertEqual(double.floatValue, 1.2)
            }else {
                XCTFail("Should have Double as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: 1.1, callback: didGetEmit)
    }
    
    func testJSONEmit() {
        let testName = "testJSON"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let json = result?.firstObject as? NSDictionary {
                XCTAssertEqual(json.valueForKey("testString")! as! String, "test")
                XCTAssertEqual(json.valueForKey("testNumber")! as! Int, 15)
                XCTAssertEqual((json.valueForKey("testArray")! as! Array<AnyObject>).count, 2)
                XCTAssertEqual((json.valueForKey("testArray")! as! Array<AnyObject>).last! as! Int, 1)
                let string = NSString(data: (json.valueForKey("testArray")! as! Array<AnyObject>).first! as! NSData, encoding: NSUTF8StringEncoding)!
                XCTAssertEqual(string, "gakgakgak2")
            }else {
                XCTFail("Should have NSDictionary as result")
            }
        }
        let json = ["name": "test", "testArray": ["hallo"], "nestedTest": ["test": "test"], "number": 15]
        
        abstractSocketEmitTest(testName, emitData: json, callback: didGetEmit)
    }
    
    func testUnicodeEmit() {
        let testName = "testUnicode"
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            if let unicode = result?.firstObject as? String {
                XCTAssertEqual(unicode, "🚄")
            }else {
                XCTFail("Should have String as result")
            }
        }
        abstractSocketEmitTest(testName, emitData: "🚀", callback: didGetEmit)
    }
    
    func testMultipleItemsEmit() {
        let testName = "testMultipleItems"
        let expection = self.expectationWithDescription(testName)
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            XCTAssertEqual(result!.count, 5)
            if let array = result?.firstObject as? Array<AnyObject> {
                XCTAssertEqual(array.last! as! Int, 2)
                let string = NSString(data: array.first! as! NSData, encoding: NSUTF8StringEncoding)!
                XCTAssertEqual(string, "gakgakgak2")
            }else {
                XCTFail("Should have Array as result")
            }
            if let dict = result?[1] as? NSDictionary {
                XCTAssertEqual(dict.valueForKey("test") as! String, "bob")
                
            }else {
                XCTFail("Should have NSDictionary as result")
            }
            if let number = result?[2] as? Int {
                XCTAssertEqual(number, 25)
                
            }else {
                XCTFail("Should have Integer as result")
            }
            if let string = result?[3] as? String {
                XCTAssertEqual(string, "polo")
                
            }else {
                XCTFail("Should have Integer as result")
            }
            if let data = result?[4] as? NSData {
                let string = NSString(data: data, encoding: NSUTF8StringEncoding)!
                XCTAssertEqual(string, "gakgakgak2")
            }else {
                XCTFail("Should have NSData as result")
            }
            expection.fulfill()
        }
        let data = NSString(string: "gakgakgak2").dataUsingEncoding(NSUTF8StringEncoding)!
        socket.emit(testName, withItems: [["test1", "test2"], ["test": "test"], 15, "marco", data])
        socket.on(testName + "Return", callback: didGetEmit)
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }

    
    func abstractSocketEmitTest(testName:String, emitData:AnyObject?, callback:NormalCallback){
        let finalTestname = testName + testKind.rawValue
        let expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            callback(result, ack)
            expection.fulfill()
        }
        
        socket.on(finalTestname + "Return", callback: didGetEmit)
        if let emitData = emitData {
            socket.emit(finalTestname, emitData)
        } else {
            socket.emit(finalTestname)
        }
        
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
}
