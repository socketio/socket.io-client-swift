//
// Created by Erik Little on 3/30/18.
//

import Foundation

/// Class that gives a backwards compatible way to cause an emit not to recursively check for Data objects.
///
/// Usage:
///
/// ```swift
/// socket.rawEmitView.emit("myEvent", myObject)
/// ```
public final class SocketBinaryView : NSObject {
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
    open func emit(_ event: String, _ items: SocketData...) {
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
    open func emit(_ event: String, with items: [Any]) {
        guard socket.status == .connected else {
            socket.handleClientEvent(.error, data: ["Tried emitting \(event) when not connected"])
            return
        }

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
    open func emitWithAck(_ event: String, _ items: SocketData...) -> OnAckCallback {
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
    open func emitWithAck(_ event: String, with items: [Any]) -> OnAckCallback {
        return socket.createOnAck([event] + items, binary: false)
    }
}
