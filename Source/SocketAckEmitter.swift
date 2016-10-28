//
//  SocketAckEmitter.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 9/16/15.
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

import Foundation

public final class SocketAckEmitter : NSObject {
    let socket: SocketIOClient
    let ackNum: Int

    public var expected: Bool {
        return ackNum != -1
    }
    
    init(socket: SocketIOClient, ackNum: Int) {
        self.socket = socket
        self.ackNum = ackNum
    }
    
    public func with(_ items: SocketData...) {
        guard ackNum != -1 else { return }
        
        socket.emitAck(ackNum, with: items)
    }
    
    public func with(_ items: [Any]) {
        guard ackNum != -1 else { return }
        
        socket.emitAck(ackNum, with: items)
    }
        
}

public final class OnAckCallback : NSObject {
    private let ackNumber: Int
    private let items: [Any]
    private weak var socket: SocketIOClient?
    
    init(ackNumber: Int, items: [Any], socket: SocketIOClient) {
        self.ackNumber = ackNumber
        self.items = items
        self.socket = socket
    }
    
    deinit {
        DefaultSocketLogger.Logger.log("OnAckCallback for \(ackNumber) being released", type: "OnAckCallback")
    }
    
    public func timingOut(after seconds: Int, callback: @escaping AckCallback) {
        guard let socket = self.socket else { return }
        
        socket.ackQueue.sync() {
            socket.ackHandlers.addAck(ackNumber, callback: callback)
        }
        
        socket._emit(items, ack: ackNumber)
        
        guard seconds != 0 else { return }
        
        let time = DispatchTime.now() + Double(UInt64(seconds) * NSEC_PER_SEC) / Double(NSEC_PER_SEC)
        
        socket.handleQueue.asyncAfter(deadline: time) {
            socket.ackHandlers.timeoutAck(self.ackNumber, onQueue: socket.handleQueue)
        }
    }
    
}
