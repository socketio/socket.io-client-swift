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


public class SocketAckEmitter: NSObject {
    unowned let socket: SocketIOClient
    var ackNum: Int
    
    public subscript(items: AnyObject...) -> Bool {
        socket.emitAck(ackNum, withItems: items)
        
        return true
    }
    
    public subscript(items: [AnyObject]) -> NSString {
        socket.emitAck(ackNum, withItems: items)
        
        return "Done"
    }
    
    init(socket: SocketIOClient, ackNum: Int) {
        self.socket = socket
        self.ackNum = ackNum
    }
}