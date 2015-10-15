//
//  SocketTestSocket.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/15/15.
//
//

import Foundation

class SocketTestSocket: NSObject, SocketEngineClient {
    private let expectedStrings: [String]
    private let expectedNumberOfBinary: Int
    private let expectedBinary: [NSData]?
    
    var actualStrings = [String]()
    var binary = [NSData]()

    var socketURL = ""
    var secure = false
    
    init(expectedStrings: [String], expectedNumberOfBinary: Int, expectedBinary: [NSData]?) {
        self.expectedStrings = expectedStrings
        self.expectedNumberOfBinary = expectedNumberOfBinary
        self.expectedBinary = expectedBinary
    }
    
    func didError(reason: AnyObject) {}
    
    func engineDidClose(reason: String) {}
    
    func parseSocketMessage(msg: String) {
        actualStrings.append(msg)
    }
    
    func parseBinaryData(data: NSData) {
        binary.append(data)
    }
    
    func isCorrectPackets() -> Bool {
        return expectedBinary ?? [] == binary && expectedStrings == actualStrings
    }
}