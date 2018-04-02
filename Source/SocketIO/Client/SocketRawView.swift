//
//  SocketRawView.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/30/18.
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

/// Class that gives a backwards compatible way to cause an emit not to recursively check for Data objects.
///
/// Usage:
///
/// ```swift
/// socket.rawEmitView.emit("myEvent", myObject)
/// ```
public final class SocketRawView : NSObject {
    private unowned let socket: SocketIOClient

    init(socket: SocketIOClient) {
        self.socket = socket
    }

    /// Send an event to the server, with optional data items.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    public func emit(_ event: String, _ items: SocketData...) {
        do {
            try emit(event, with: items.map({ try $0.socketRepresentation() }))
        } catch let err {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: "SocketIOClient")

            socket.handleClientEvent(.error, data: [event, items, err])
        }
    }

    /// Same as emit, but meant for Objective-C
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. Send an empty array to send no data.
    @objc
    public func emit(_ event: String, with items: [Any]) {
        socket.emit([event] + items, binary: false)
    }

    /// Sends a message to the server, requesting an ack.
    ///
    /// **NOTE**: It is up to the server send an ack back, just calling this method does not mean the server will ack.
    /// Check that your server's api will ack the event being sent.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// Example:
    ///
    /// ```swift
    /// socket.emitWithAck("myEvent", 1).timingOut(after: 1) {data in
    ///     ...
    /// }
    /// ```
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - returns: An `OnAckCallback`. You must call the `timingOut(after:)` method before the event will be sent.
    public func emitWithAck(_ event: String, _ items: SocketData...) -> OnAckCallback {
        do {
            return emitWithAck(event, with: try items.map({ try $0.socketRepresentation() }))
        } catch let err {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: "SocketIOClient")

            socket.handleClientEvent(.error, data: [event, items, err])

            return OnAckCallback(ackNumber: -1, items: [], socket: socket)
        }
    }

    /// Same as emitWithAck, but for Objective-C
    ///
    /// **NOTE**: It is up to the server send an ack back, just calling this method does not mean the server will ack.
    /// Check that your server's api will ack the event being sent.
    ///
    /// Example:
    ///
    /// ```swift
    /// socket.emitWithAck("myEvent", with: [1]).timingOut(after: 1) {data in
    ///     ...
    /// }
    /// ```
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. Use `[]` to send nothing.
    /// - returns: An `OnAckCallback`. You must call the `timingOut(after:)` method before the event will be sent.
    @objc
    public func emitWithAck(_ event: String, with items: [Any]) -> OnAckCallback {
        return socket.createOnAck([event] + items, binary: false)
    }
}

/// Class that gives a backwards compatible way to cause an emit not to recursively check for Data objects.
///
/// Usage:
///
/// ```swift
/// ack.rawEmitView.with(myObject)
/// ```
public final class SocketRawAckView : NSObject {
    private unowned let socket: SocketIOClient
    private let ackNum: Int

    init(socket: SocketIOClient, ackNum: Int) {
        self.socket = socket
        self.ackNum = ackNum
    }

    /// Call to ack receiving this event.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[ackNum, items, theError]`
    ///
    /// - parameter items: A variable number of items to send when acking.
    public func with(_ items: SocketData...) {
        guard ackNum != -1 else { return }

        do {
            socket.emit(try items.map({ try $0.socketRepresentation() }), ack: ackNum, binary: false, isAck: true)
        } catch let err {
            socket.handleClientEvent(.error, data: [ackNum, items, err])
        }
    }

    /// Call to ack receiving this event.
    ///
    /// - parameter items: An array of items to send when acking. Use `[]` to send nothing.
    @objc
    public func with(_ items: [Any]) {
        guard ackNum != -1 else { return }

        socket.emit(items, ack: ackNum, binary: false, isAck: true)
    }
}
