//
//  SocketLogger.swift
//  SocketIO-Swift
//
//  Created by Erik Little on 4/11/15.
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

protocol SocketLogClient {
    var log:Bool {get set}
    var logType:String {get}
}

final class SocketLogger {
    private static let printQueue = dispatch_queue_create("printQueue", DISPATCH_QUEUE_SERIAL)
    
    static func log(message:String, client:SocketLogClient, altType:String? = nil) {
        if !client.log {
            return
        }
        
        dispatch_async(printQueue) {
            NSLog("%@: %@", altType ?? client.logType, message)
        }
    }
    
    static func err(message:String, client:SocketLogClient, altType:String? = nil) {
        if !client.log {
            return
        }
        
        dispatch_async(printQueue) {
            NSLog("ERROR %@: %@", altType ?? client.logType, message)
        }
    }
}
