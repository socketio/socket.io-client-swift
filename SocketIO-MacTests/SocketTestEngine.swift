//
//  SocketTestEngine.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/7/15.
//
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

// Test engine used to test SocketIOClient

import Foundation
import XCTest

class SocketTestEngine: NSObject, SocketEngineSpec {
    private let expectedNumberOfBinary: Int
    private let expectedSendString: String
    private var expectedBinary: [NSData]?
    private var binary: [NSData]?
    private var sendString = ""
    private var numOfBinary = -1
    
    private(set) var sid = ""
    private(set) var cookies: [NSHTTPCookie]?
    private(set) var socketPath = ""
    private(set) var urlPolling = ""
    private(set) var urlWebSocket = ""
    private(set) var ws: WebSocket?
    
    weak var client: SocketEngineClient?
    var expectation: XCTestExpectation?
    
    init(client: SocketIOClient, expectedSendString: String, expectedNumberOfBinary: Int, expectedBinary: [NSData]?) {
        self.client = client
        self.expectedSendString = expectedSendString
        self.expectedNumberOfBinary = expectedNumberOfBinary
        self.expectedBinary = expectedBinary
    }
    
    required init(client: SocketEngineClient, sessionDelegate: NSURLSessionDelegate?) {
        expectedSendString = ""
        expectedNumberOfBinary = 0
    }
    
    required init(client: SocketEngineClient, opts: NSDictionary?) {
        expectedSendString = ""
        expectedNumberOfBinary = 0
    }
    
    func close(fast fast: Bool) {}
    func open(opts: [String: AnyObject]?) {}
    
    func send(msg: String, withData datas: [NSData]?) {
        sendString = msg
        numOfBinary = datas?.count ?? 0
        binary = datas
    }
    
    func socketDidCorrectlyCreatePacket() -> Bool {
        if expectedNumberOfBinary == numOfBinary
            && sendString == expectedSendString
            && expectedBinary ?? [] == binary ?? [] {
                expectation?.fulfill()
                return true
        } else {
            return false
        }
    }
    
    func write(msg: String, withType type: SocketEnginePacketType, withData data: [NSData]?) {}
}