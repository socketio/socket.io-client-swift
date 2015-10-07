//
//  AbstractSocketTest.swift
//  socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 02.08.15.
//
//

import XCTest

class AbstractSocketTest: XCTestCase {
    static let serverURL = "localhost:6979"
    static let TEST_TIMEOUT = 5.0
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
    
    func openConnection(socket: SocketIOClient) {
        guard socket.status == SocketIOClientStatus.NotConnected else { return }
        var finished = false
        let semaphore = dispatch_semaphore_create(0)
        socket.on("connect") {data, ack in
            XCTAssertEqual(socket.status, SocketIOClientStatus.Connected)
            XCTAssertFalse(socket.secure)
            finished = true
        }
        socket.connect()
        XCTAssertEqual(socket.status, SocketIOClientStatus.Connecting)
        while !finished {
            NSRunLoop.currentRunLoop().runMode(NSDefaultRunLoopMode, beforeDate: NSDate.distantFuture() as NSDate)
        }
    }
    
    func generateTestName(rawTestName:String) -> String {
        return rawTestName + testKind!.rawValue
    }
    
    func checkConnectionStatus() {
        XCTAssertEqual(socket.status, SocketIOClientStatus.Connected)
        XCTAssertFalse(socket.secure)
    }
    
    func socketMultipleEmit(testName:String, emitData:Array<AnyObject>, callback:NormalCallback) {
        let didConnect = {
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
        
        if socket.status != .Connected {
            openConnection(socket)
        }else {
            didConnect()
        }
    }
    
    
    func socketEmit(testName:String, emitData:AnyObject?, callback:NormalCallback){
        let didConnect = {
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
        if socket.status != .Connected {
            openConnection(socket)
        }else {
            didConnect()
        }
    }
    
    
    func socketAcknwoledgeMultiple(testName:String, Data:Array<AnyObject>, callback:NormalCallback){
        let didConnect = {
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
        if socket.status != .Connected {
            openConnection(socket)
        }else {
            didConnect()
        }
    }
    
    func socketAcknwoledge(testName:String, Data:AnyObject?, callback:NormalCallback){
        let didConnect = {
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
        if socket.status != .Connected {
            openConnection(socket)
        }else {
            didConnect()
        }
    }
}
