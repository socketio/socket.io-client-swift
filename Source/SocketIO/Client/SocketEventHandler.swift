//
//  EventHandler.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/18/15.
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

/// A wrapper around a handler.
public struct SocketEventHandler {
    // MARK: Properties

    /// The event for this handler.
    public let event: String

    /// A unique identifier for this handler.
    public let id: UUID

    /// The actual handler function.
    public let callback: NormalCallback

    // MARK: Methods

    /// Causes this handler to be executed.
    ///
    /// - parameter with: The data that this handler should be called with.
    /// - parameter withAck: The ack number that this event expects. Pass -1 to say this event doesn't expect an ack.
    /// - parameter withSocket: The socket that is calling this event.
    public func executeCallback(with items: [Any], withAck ack: Int, withSocket socket: SocketIOClient) {
        callback(items, SocketAckEmitter(socket: socket, ackNum: ack))
    }
}
