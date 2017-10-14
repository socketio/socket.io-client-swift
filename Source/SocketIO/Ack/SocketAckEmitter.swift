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

import Dispatch
import Foundation

/// A class that represents a waiting ack call.
///
/// **NOTE**: You should not store this beyond the life of the event handler.
public final class SocketAckEmitter : NSObject {
    let socket: SocketIOClient
    let ackNum: Int

    // MARK: Properties

    /// If true, this handler is expecting to be acked. Call `with(_: SocketData...)` to ack.
    public var expected: Bool {
        return ackNum != -1
    }

    // MARK: Initializers

    /// Creates a new `SocketAckEmitter`.
    ///
    /// - parameter socket: The socket for this emitter.
    /// - parameter ackNum: The ack number for this emitter.
    public init(socket: SocketIOClient, ackNum: Int) {
        self.socket = socket
        self.ackNum = ackNum
    }

    // MARK: Methods

    /// Call to ack receiving this event.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[ackNum, items, theError]`
    ///
    /// - parameter items: A variable number of items to send when acking.
    public func with(_ items: SocketData...) {
        guard ackNum != -1 else { return }

        do {
            socket.emitAck(ackNum, with: try items.map({ try $0.socketRepresentation() }))
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

        socket.emitAck(ackNum, with: items)
    }

}

/// A class that represents an emit that will request an ack that has not yet been sent.
/// Call `timingOut(after:callback:)` to complete the emit
/// Example:
///
/// ```swift
/// socket.emitWithAck("myEvent").timingOut(after: 1) {data in
///     ...
/// }
/// ```
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

    // MARK: Methods

    /// Completes an emitWithAck. If this isn't called, the emit never happens.
    ///
    /// - parameter after: The number of seconds before this emit times out if an ack hasn't been received.
    /// - parameter callback: The callback called when an ack is received, or when a timeout happens.
    ///                       To check for timeout, use `SocketAckStatus`'s `noAck` case.
    @objc
    public func timingOut(after seconds: Double, callback: @escaping AckCallback) {
        guard let socket = self.socket, ackNumber != -1 else { return }

        socket.ackHandlers.addAck(ackNumber, callback: callback)
        socket.emit(items, ack: ackNumber)

        guard seconds != 0 else { return }

        socket.manager?.handleQueue.asyncAfter(deadline: DispatchTime.now() + seconds) {[weak socket] in
            guard let socket = socket, let manager = socket.manager else { return }

            socket.ackHandlers.timeoutAck(self.ackNumber, onQueue: manager.handleQueue)
        }
    }

}
