//
//  SocketTestCases.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 02.08.15.
//
//

import XCTest
import Foundation

class SocketTestCases: NSObject {
    typealias SocketSendFunction = (testName:String, emitData:AnyObject?, callback:NormalCallback)->()
    
    static func testBasic(abstractSocketSend:SocketSendFunction) {
        let testName = "basicTest"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            
        }
        abstractSocketSend(testName: testName, emitData: nil, callback: didGetResult)
    }
    
    static func testNull(abstractSocketSend:SocketSendFunction) {
        let testName = "testNull"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let _ = result.first as? NSNull {
                
            }else
            {
                XCTFail("Should have NSNull as result")
            }
        }
        abstractSocketSend(testName: testName, emitData: NSNull(), callback: didGetResult)
    }
    
    static func testBinary(abstractSocketSend:SocketSendFunction) {
        let testName = "testBinary"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let data = result.first as? NSData {
                let string = NSString(data: data, encoding: NSUTF8StringEncoding)!
                XCTAssertEqual(string, "gakgakgak2")
            }else {
                XCTFail("Should have NSData as result")
            }
        }
        let data = NSString(string: "gakgakgak2").dataUsingEncoding(NSUTF8StringEncoding)!
        abstractSocketSend(testName: testName, emitData: data, callback: didGetResult)
    }
    
    static func testArray(abstractSocketSend:SocketSendFunction) {
        let testName = "testArray"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let array = result.first as? NSArray {
                XCTAssertEqual(array.count, 2)
                XCTAssertEqual((array.firstObject! as! String), "test3")
                XCTAssertEqual((array.lastObject! as! String), "test4")
            }else {
                XCTFail("Should have NSArray as result")
            }
        }
        abstractSocketSend(testName: testName, emitData: ["test1", "test2"], callback: didGetResult)
    }
    
    static func testString(abstractSocketSend:SocketSendFunction) {
        let testName = "testString"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let string = result.first as? String {
                XCTAssertEqual(string, "polo")
            }else {
                XCTFail("Should have String as result")
            }
        }
        abstractSocketSend(testName: testName, emitData: "marco", callback: didGetResult)
    }
    
    static func testBool(abstractSocketSend:SocketSendFunction) {
        let testName = "testBool"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let bool = result.first as? NSNumber {
                XCTAssertTrue(bool.boolValue)
            }else {
                XCTFail("Should have Boolean as result")
            }
        }
        abstractSocketSend(testName: testName, emitData: false, callback: didGetResult)
    }
    
    static func testInteger(abstractSocketSend:SocketSendFunction) {
        let testName = "testInteger"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let integer = result.first as? Int {
                XCTAssertEqual(integer, 20)
            }else {
                XCTFail("Should have Integer as result")
            }
        }
        abstractSocketSend(testName: testName, emitData: 10, callback: didGetResult)
    }
    
    static func testDouble(abstractSocketSend:SocketSendFunction) {
        let testName = "testDouble"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let double = result.first as? NSNumber {
                XCTAssertEqual(double.floatValue, 1.2)
            }else {
                XCTFail("Should have Double as result")
            }
        }
        abstractSocketSend(testName: testName, emitData: 1.1, callback: didGetResult)
    }
    
    static func testJSONWithBuffer(abstractSocketSend:SocketSendFunction) {
        let testName = "testJSONWithBuffer"
        let data = "0".dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
        
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let json = result.first as? NSDictionary {
                XCTAssertEqual((json.valueForKey("testString")! as! String), "test")
                XCTAssertEqual((json.valueForKey("testNumber")! as! Int), 15)
                XCTAssertEqual((json.valueForKey("testArray")! as! Array<AnyObject>).count, 2)
                XCTAssertEqual(((json.valueForKey("testArray")! as! Array<AnyObject>).last! as! Int), 1)
                let string = NSString(data: (json.valueForKey("testArray")! as! Array<AnyObject>).first! as! NSData, encoding: NSUTF8StringEncoding)!
                XCTAssertEqual(string, "gakgakgak2")
            }else {
                XCTFail("Should have NSDictionary as result")
            }
        }
        let json = ["name": "test", "testArray": ["hallo"], "nestedTest": ["test": "test"], "number": 15, "buf": data]
        
        abstractSocketSend(testName: testName, emitData: json, callback: didGetResult)
    }
    
    static func testJSON(abstractSocketSend:SocketSendFunction) {
        let testName = "testJSON"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let json = result.first as? NSDictionary {
                XCTAssertEqual((json.valueForKey("testString")! as! String), "test")
                XCTAssertEqual(json.valueForKey("testNumber")! as? Int, 15)
                XCTAssertEqual((json.valueForKey("testArray")! as! Array<AnyObject>).count, 2)
                XCTAssertEqual((json.valueForKey("testArray")! as! Array<AnyObject>).first! as? Int, 1)
                XCTAssertEqual((json.valueForKey("testArray")! as! Array<AnyObject>).last! as? Int, 1)
                
            }else {
                XCTFail("Should have NSDictionary as result")
            }
        }
        let json = ["name": "test", "testArray": ["hallo"], "nestedTest": ["test": "test"], "number": 15]
        
        abstractSocketSend(testName: testName, emitData: json, callback: didGetResult)
    }
    
    static func testUnicode(abstractSocketSend:SocketSendFunction) {
        let testName = "testUnicode"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            if let unicode = result.first as? String {
                XCTAssertEqual(unicode, "🚄")
            }else {
                XCTFail("Should have String as result")
            }
        }
        abstractSocketSend(testName: testName, emitData: "🚀", callback: didGetResult)
    }
    
    static func testMultipleItemsWithBuffer(abstractSocketMultipleSend:(testName:String, emitData:Array<AnyObject>, callback:NormalCallback)->()) {
        let testName = "testMultipleItemsWithBuffer"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            XCTAssertEqual(result.count, 5)
            if result.count != 5 {
                XCTFail("Fatal Fail. Lost some Data")
                return
            }
            if let array = result.first as? Array<AnyObject> {
                XCTAssertEqual((array.last! as! Int), 2)
                XCTAssertEqual((array.first! as! Int), 1)
            }else {
                XCTFail("Should have Array as result")
            }
            if let dict = result[1] as? NSDictionary {
                XCTAssertEqual((dict.valueForKey("test") as! String), "bob")
                
            }else {
                XCTFail("Should have NSDictionary as result")
            }
            if let number = result[2] as? Int {
                XCTAssertEqual(number, 25)
                
            }else {
                XCTFail("Should have Integer as result")
            }
            if let string = result[3] as? String {
                XCTAssertEqual(string, "polo")
                
            }else {
                XCTFail("Should have Integer as result")
            }
            if let data = result[4] as? NSData {
                let string = NSString(data: data, encoding: NSUTF8StringEncoding)!
                XCTAssertEqual(string, "gakgakgak2")
            }else {
                XCTFail("Should have NSData as result")
            }
        }
        let data = NSString(string: "gakgakgak2").dataUsingEncoding(NSUTF8StringEncoding)!
        let emitArray = [["test1", "test2"], ["test": "test"], 15, "marco", data]
        abstractSocketMultipleSend(testName: testName, emitData: emitArray, callback: didGetResult)
    }
    
    static func testMultipleItems(abstractSocketMultipleSend:(testName:String, emitData:Array<AnyObject>, callback:NormalCallback)->()) {
        let testName = "testMultipleItems"
        func didGetResult(result:[AnyObject], ack:SocketAckEmitter?) {
            XCTAssertEqual(result.count, 5)
            if result.count != 5 {
                XCTFail("Fatal Fail. Lost some Data")
                return
            }
            if let array = result.first as? Array<AnyObject> {
                XCTAssertEqual((array.last! as! Int), 2)
                XCTAssertEqual((array.first! as! Int), 1)
            }else {
                XCTFail("Should have Array as result")
            }
            if let dict = result[1] as? NSDictionary {
                XCTAssertEqual((dict.valueForKey("test") as! String), "bob")
                
            }else {
                XCTFail("Should have NSDictionary as result")
            }
            if let number = result[2] as? Int {
                XCTAssertEqual(number, 25)
                
            }else {
                XCTFail("Should have Integer as result")
            }
            if let string = result[3] as? String {
                XCTAssertEqual(string, "polo")
            }else {
                XCTFail("Should have Integer as result")
            }
            if let bool = result[4] as? NSNumber {
                XCTAssertFalse(bool.boolValue)
            }else {
                XCTFail("Should have NSNumber as result")
            }
        }
        let emitArray = [["test1", "test2"], ["test": "test"], 15, "marco", false]
        abstractSocketMultipleSend(testName: testName, emitData: emitArray, callback: didGetResult)
    }
}
