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

/// Represents a class will log client events.
public protocol SocketLogger : class {
    // MARK: Properties

    /// Whether to log or not
    var log: Bool { get set }

    // MARK: Methods

    /// Normal log messages
    ///
    /// - parameter message: The message being logged. Can include `%@` that will be replaced with `args`
    /// - parameter type: The type of entity that called for logging.
    /// - parameter args: Any args that should be inserted into the message. May be left out.
    func log(_ message: @autoclosure () -> String, type: String)

    /// Error Messages
    ///
    /// - parameter message: The message being logged. Can include `%@` that will be replaced with `args`
    /// - parameter type: The type of entity that called for logging.
    /// - parameter args: Any args that should be inserted into the message. May be left out.
    func error(_ message: @autoclosure () -> String, type: String)
}

public extension SocketLogger {
    /// Default implementation.
    func log(_ message: @autoclosure () -> String, type: String) {
        abstractLog("LOG", message: message, type: type)
    }

    /// Default implementation.
    func error(_ message: @autoclosure () -> String, type: String) {
        abstractLog("ERROR", message: message, type: type)
    }

    private func abstractLog(_ logType: String, message: @autoclosure () -> String, type: String) {
        guard log else { return }

        NSLog("\(logType) \(type): %@", message())
    }
}

class DefaultSocketLogger : SocketLogger {
    static var Logger: SocketLogger = DefaultSocketLogger()

    var log = false
}
