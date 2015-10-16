//
//  AbstractSocketTest.swift
//  socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 02.08.15.
//
//

import XCTest

class AbstractSocketTest: XCTestCase {
    static let serverURL = "milkbartube.com:6979"
    static let TEST_TIMEOUT = 30.0
    var socket: SocketIOClient!
    static let regularSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL)
    static let regularAckSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL)
    static let namespaceSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL,
        opts: ["nsp": "/swift"])
    static let namespaceAckSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL,
        opts: ["nsp": "/swift"])
    
    static let regularPollingSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL,
        opts: ["forcePolling": true])
    static let regularPollingAckSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL,
        opts: ["forcePolling": true])
    static let namespacePollingSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL,
        opts: ["forcePolling": true,"nsp": "/swift"])
    static let namespacePollingAckSocket = SocketIOClient(socketURL: AbstractSocketTest.serverURL,
        opts: ["forcePolling": true,"nsp": "/swift"])
    var testKind:TestKind?
    
    func generateTestName(rawTestName:String) -> String {
        return rawTestName + testKind!.rawValue + NSUUID().UUIDString
    }
    
    func checkConnectionStatus() {
        XCTAssertEqual(socket.status, SocketIOClientStatus.Connected)
        XCTAssertFalse(socket.secure)
    }
    
    func socketMultipleEmit(testName:String, emitData:Array<AnyObject>, callback:NormalCallback) {
        XCTAssert(self.socket.status == .Connected)
        let finalTestname = self.generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:[AnyObject], ack:SocketAckEmitter?) {
            callback(result, ack)
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        self.socket.emit(finalTestname, withItems: emitData)
        self.socket.on(finalTestname + "Return", callback: didGetEmit)
        self.waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    
    func socketEmit(testName:String, emitData:AnyObject?, callback:NormalCallback){
        XCTAssert(self.socket.status == .Connected)
        let finalTestname = self.generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetEmit(result:[AnyObject], ack:SocketAckEmitter?) {
            callback(result, ack)
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        self.socket.on(finalTestname + "Return", callback: didGetEmit)
        if let emitData = emitData {
            self.socket.emit(finalTestname, emitData)
        } else {
            self.socket.emit(finalTestname)
        }
        
        self.waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    
    func socketAcknwoledgeMultiple(testName:String, Data:Array<AnyObject>, callback:NormalCallback){
        XCTAssert(self.socket.status == .Connected)
        let finalTestname = self.generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGetResult(result: [AnyObject]) {
            callback(result, SocketAckEmitter(socket: self.socket, ackNum: -1))
            if let expection = expection {
                expection.fulfill()
            }
        }
        
        self.socket.emitWithAck(finalTestname, withItems: Data)(timeoutAfter: 5, callback: didGetResult)
        self.waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
    
    func socketAcknwoledge(testName:String, Data:AnyObject?, callback:NormalCallback){
        XCTAssert(self.socket.status == .Connected)
        let finalTestname = self.generateTestName(testName)
        weak var expection = self.expectationWithDescription(finalTestname)
        func didGet(result:[AnyObject]) {
            callback(result, SocketAckEmitter(socket: self.socket, ackNum: -1))
            if let expection = expection {
                expection.fulfill()
            }
        }
        var ack:OnAckCallback!
        if let Data = Data {
            ack = self.socket.emitWithAck(finalTestname, Data)
        } else {
            ack = self.socket.emitWithAck(finalTestname)
        }
        ack(timeoutAfter: 20, callback: didGet)
        self.waitForExpectationsWithTimeout(SocketEmitTest.TEST_TIMEOUT, handler: nil)
    }
}
