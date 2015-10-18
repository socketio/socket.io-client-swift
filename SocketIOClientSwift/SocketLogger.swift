//
//  SocketLogger.swift
//  Socket.IO-Client-Swift
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

var Logger: SocketLogger = DefaultSocketLogger()

public protocol SocketLogger: class {
    /// Whether to log or not
    var log: Bool {get set}
    
    /// Normal log messages
    func log(message: String, type: String, args: AnyObject...)
    
    /// Error Messages
    func error(message: String, type: String, args: AnyObject...)
}

public extension SocketLogger {
    func log(message: String, type: String, args: AnyObject...) {
        abstractLog("Log", message: message, type: type, args: args)
    }
    
    func error(message: String, type: String, args: AnyObject...) {
        abstractLog("ERROR", message: message, type: type, args: args)
    }
    
    private func abstractLog(logType: String, message: String, type: String, args: [AnyObject]) {
        guard log else { return }
        
        let newArgs = args.map {arg -> CVarArgType in String(arg)}
        let replaced = String(format: message, arguments: newArgs)
        
        NSLog("%@ %@: %@", logType, type, replaced)
    }
}

class DefaultSocketLogger: SocketLogger {
    var log = false
}
