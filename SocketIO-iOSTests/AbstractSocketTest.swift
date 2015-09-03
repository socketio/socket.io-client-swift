//
//  AbstractSocketTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 02.08.15.
//
//

import XCTest

class AbstractSocketTest: XCTestCase {
    static let serverURL = "milkbartube.com:6979"
    static let TEST_TIMEOUT = 8.0
    var socket:SocketIOClient!
    var testKind:TestKind?
    
    
    
    func openConnection() {
        weak var expection = self.expectationWithDescription("connect")
        XCTAssertTrue(socket.status == SocketIOClientStatus.NotConnected)
        socket.on("connect") {data, ack in
            if let expection = expection {
                expection.fulfill()
            }
        }
        socket.connect()
        XCTAssertEqual(socket.status, SocketIOClientStatus.Connecting)
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func generateTestName(rawTestName:String) ->String {
        return rawTestName + testKind!.rawValue
    }
    
    func checkConnectionStatus() {
        XCTAssertEqual(socket.status, SocketIOClientStatus.Connected)
        XCTAssertFalse(socket.secure)
    }
    
    func socketMultipleEmit(testName:String, emitData:Array<AnyObject>, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            callback(result, ack)
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        socket.emit(finalTestname, withItems: emitData)
        socket.on(finalTestname + "Return", callback: didGetEmit)
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    
    func socketEmit(testName:String, emitData:AnyObject?, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:NSArray?, ack:AckEmitter?) {
            callback(result, ack)
            if let expection = expection {
                expection.fulfill()
            }
            
        }
        
        socket.on(finalTestname + "Return", callback: didGetEmit)
        if let emitData = emitData {
            socket.emit(finalTestname, emitData)
        } else {
            socket.emit(finalTestname)
        }
        
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    func socketAcknwoledgeMultiple(testName:String, Data:Array<AnyObject>, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetResult(result:NSArray?) {
            callback(result, nil)
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        socket.emitWithAck(finalTestname, withItems: Data)(timeoutAfter: 5, callback: didGetResult)
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    func socketAcknwoledge(testName:String, Data:AnyObject?, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGet(result:NSArray?) {
            callback(result, nil)
            if let expection = expection {
                expection.fulfill()
            }
        }
        var ack:OnAckCallback!
        if let Data = Data {
            ack = socket.emitWithAck(finalTestname, Data)
        } else {
            ack = socket.emitWithAck(finalTestname)
        }
        ack(timeoutAfter: 20, callback: didGet)
        
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
}
