//
//  AbstractSocketTest.swift
//  AbstractSocketTest.socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 02.08.15.
//
//

import XCTest

class AbstractSocketTest: XCTestCase {
    static let serverURL = "localhost:6979"
    static let TEST_TIMEOUT = 3.0
    static var socket: SocketIOClient!
    static let regularSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL)
    
    static let regularPollingSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL,
        opts: ["forcePolling": true])
    static let namespaceSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL, opts: ["nsp": "/swift"])
    static let namespacePollingSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL, opts: ["forsePolling": true,"nsp": "/swift"])
    var testKind:TestKind?
    
    func openConnection(socket: SocketIOClient) {
        guard socket.status == SocketIOClientStatus.NotConnected else {return}
        
        weak var expection = self.expectationWithDescription("connect")
        XCTAssertTrue(socket.status == SocketIOClientStatus.NotConnected)
        socket.on("connect") {data, ack in
            XCTAssertEqual(socket.status, SocketIOClientStatus.Connected)
            XCTAssertFalse(socket.secure)
            if let expection = expection {
                expection.fulfill()
            }
        }
        socket.connect()
        XCTAssertEqual(socket.status, SocketIOClientStatus.Connecting)
        waitForExpectationsWithTimeout(AbstractSocketTest.TEST_TIMEOUT, handler: nil)
    }
    
    func generateTestName(rawTestName:String) -> String {
        return rawTestName + testKind!.rawValue
    }
    
    func checkConnectionStatus() {
        XCTAssertEqual(AbstractSocketTest.socket.status, SocketIOClientStatus.Connected)
        XCTAssertFalse(AbstractSocketTest.socket.secure)
    }
    
    func socketMultipleEmit(testName:String, emitData:Array<AnyObject>, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:[AnyObject], ack:SocketAckEmitter?) {
            callback(result, ack)
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        AbstractSocketTest.socket.emit(finalTestname, withItems: emitData)
        AbstractSocketTest.socket.on(finalTestname + "Return", callback: didGetEmit)
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    
    func socketEmit(testName:String, emitData:AnyObject?, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:[AnyObject], ack:SocketAckEmitter?) {
            callback(result, ack)
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        AbstractSocketTest.socket.on(finalTestname + "Return", callback: didGetEmit)
        if let emitData = emitData {
            AbstractSocketTest.socket.emit(finalTestname, emitData)
        } else {
            AbstractSocketTest.socket.emit(finalTestname)
        }
        
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    
    func socketAcknwoledgeMultiple(testName:String, Data:Array<AnyObject>, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetResult(result: [AnyObject]) {
            callback(result, SocketAckEmitter(socket: AbstractSocketTest.socket, ackNum: -1))
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        AbstractSocketTest.socket.emitWithAck(finalTestname, withItems: Data)(timeoutAfter: 5, callback: didGetResult)
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    func socketAcknwoledge(testName:String, Data:AnyObject?, callback:NormalCallback){
        let finalTestname = generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGet(result:[AnyObject]) {
            callback(result, SocketAckEmitter(socket: AbstractSocketTest.socket, ackNum: -1))
            if let expection = expection {
                expection.fulfill()
            }
        }
        var ack:OnAckCallback!
        if let Data = Data {
            ack = AbstractSocketTest.socket.emitWithAck(finalTestname, Data)
        } else {
            ack = AbstractSocketTest.socket.emitWithAck(finalTestname)
        }
        ack(timeoutAfter: 20, callback: didGet)
        
        waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
}
