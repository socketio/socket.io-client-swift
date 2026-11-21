//
//  SocketIOClientSpec.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/3/16.
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

/// Defines the interface for a SocketIOClient.
public protocol SocketIOClientSpec : AnyObject {
    // MARK: Properties

    /// A handler that will be called on any event.
    var anyHandler: ((SocketAnyEvent) -> ())? { get }

    /// The array of handlers for this socket.
    var handlers: [SocketEventHandler] { get }

    /// The manager for this socket.
    var manager: SocketManagerSpec? { get }

    /// The namespace that this socket is currently connected to.
    ///
    /// **Must** start with a `/`.
    var nsp: String { get }

    /// A view into this socket where emits do not check for binary data.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.rawEmitView.emit("myEvent", myObject)
    /// ```
    ///
    /// **NOTE**: It is not safe to hold on to this view beyond the life of the socket.
    var rawEmitView: SocketRawView { get }

    /// The id of this socket.io connect. This is different from the sid of the engine.io connection.
    var sid: String? { get }

    /// The status of this client.
    var status: SocketIOStatus { get }

    /// Whether the connection state was recovered after a temporary disconnection (Socket.IO 4.6+).
    /// `false` before a successful recovery CONNECT acknowledgement.
    var recovered: Bool { get }

    // MARK: Methods

    /// Connect to the server. The same as calling `connect(timeoutAfter:withHandler:)` with a timeout of 0.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    ///
    /// - parameter payload: An optional payload sent on connect
    func connect(withPayload payload: [String: Any]?)

    /// Connect to the server. If we aren't connected after `timeoutAfter` seconds, then `withHandler` is called.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    ///
    /// - parameter withPayload: An optional payload sent on connect
    /// - parameter timeoutAfter: The number of seconds after which if we are not connected we assume the connection
    ///                           has failed. Pass 0 to never timeout.
    /// - parameter handler: The handler to call when the client fails to connect.
    func connect(withPayload payload: [String: Any]?, timeoutAfter: Double, withHandler handler: (() -> ())?)

    /// Called when the client connects to a namespace. If the client was created with a namespace upfront,
    /// then this is only called when the client connects to that namespace.
    ///
    /// - parameter toNamespace: The namespace that was connected to.
    func didConnect(toNamespace namespace: String, payload: [String: Any]?)

    /// Called when the client has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    func didDisconnect(reason: String)

    /// Called when the client encounters an error.
    ///
    /// - parameter reason: The reason for the disconnection.
    func didError(reason: String)

    /// Disconnects the socket.
    func disconnect()

    /// Send an event to the server, with optional data items and optional write completion handler.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    func emit(_ event: String, _ items: SocketData..., completion: (() -> ())?)
    
    /// Send an event to the server, with optional data items and optional write completion handler.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    func emit(_ event: String, with items: [SocketData], completion: (() -> ())?)

    /// Call when you wish to tell the server that you've received the event for `ack`.
    ///
    /// - parameter ack: The ack number.
    /// - parameter with: The data for this ack.
    func emitAck(_ ack: Int, with items: [Any])

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
    func emitWithAck(_ event: String, _ items: SocketData...) -> OnAckCallback
    
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
    func emitWithAck(_ event: String, with items: [SocketData]) -> OnAckCallback

    /// JS-aligned `socket.send(...)` shortcut. Default impl delegates to
    /// `emit("message", ...)`.
    ///
    /// - parameter items: The items to send with the `"message"` event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    func send(_ items: SocketData..., completion: (() -> ())?)

    /// Array form of `send`.
    ///
    /// - parameter items: The items to send with the `"message"` event.
    /// - parameter completion: Callback called on transport write completion.
    func send(with items: [SocketData], completion: (() -> ())?)

    /// JS-aligned `socket.send(...)` returning an ack callback. Default impl
    /// delegates to `emitWithAck("message", ...)`.
    ///
    /// - parameter items: The items to send with the `"message"` event. May be left out.
    /// - returns: An `OnAckCallback`. You must call `timingOut(after:)` before the event will be sent.
    func sendWithAck(_ items: SocketData...) -> OnAckCallback

    /// Array form of `sendWithAck`.
    ///
    /// - parameter items: The items to send with the `"message"` event.
    /// - returns: An `OnAckCallback`. You must call `timingOut(after:)` before the event will be sent.
    func sendWithAck(with items: [SocketData]) -> OnAckCallback

    /// Called when socket.io has acked one of our emits. Causes the corresponding ack callback to be called.
    ///
    /// - parameter ack: The number for this ack.
    /// - parameter data: The data sent back with this ack.
    func handleAck(_ ack: Int, data: [Any])

    /// Called on socket.io specific events.
    ///
    /// - parameter event: The `SocketClientEvent`.
    /// - parameter data: The data for this event.
    func handleClientEvent(_ event: SocketClientEvent, data: [Any])

    /// Called when we get an event from socket.io.
    ///
    /// - parameter event: The name of the event.
    /// - parameter data: The data that was sent with this event.
    /// - parameter isInternalMessage: Whether this event was sent internally. If `true` it is always sent to handlers.
    /// - parameter ack: If > 0 then this event expects to get an ack back from the client.
    func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int)

    /// Causes a client to handle a socket.io packet. The namespace for the packet must match the namespace of the
    /// socket.
    ///
    /// - parameter packet: The packet to handle.
    func handlePacket(_ packet: SocketPacket)

    /// Call when you wish to leave a namespace and disconnect this socket.
    func leaveNamespace()

    /// Joins `nsp`. You shouldn't need to call this directly, instead call `connect`.
    ///
    /// - Parameter withPayload: The payload to connect when joining this namespace
    func joinNamespace(withPayload payload: [String: Any]?)

    /// Removes handler(s) for a client event.
    ///
    /// If you wish to remove a client event handler, call the `off(id:)` with the UUID received from its `on` call.
    ///
    /// - parameter clientEvent: The event to remove handlers for.
    func off(clientEvent event: SocketClientEvent)

    /// Removes handler(s) based on an event name.
    ///
    /// If you wish to remove a specific event, call the `off(id:)` with the UUID received from its `on` call.
    ///
    /// - parameter event: The event to remove handlers for.
    func off(_ event: String)

    /// Removes a handler with the specified UUID gotten from an `on` or `once`
    ///
    /// If you want to remove all events for an event, call the off `off(_:)` method with the event name.
    ///
    /// - parameter id: The UUID of the handler you wish to remove.
    func off(id: UUID)

    /// Adds a handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    func on(_ event: String, callback: @escaping NormalCallback) -> UUID

    /// Adds a handler for a client event.
    ///
    /// Example:
    ///
    /// ```swift
    /// socket.on(clientEvent: .connect) {data, ack in
    ///     ...
    /// }
    /// ```
    ///
    /// - parameter event: The event for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    func on(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID

    /// Adds a single-use handler for a client event.
    ///
    /// - parameter clientEvent: The event for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    func once(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID

    /// Adds a single-use handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    func once(_ event: String, callback: @escaping NormalCallback) -> UUID

    /// Adds a handler that will be called on every event.
    ///
    /// - parameter handler: The callback that will execute whenever an event is received.
    func onAny(_ handler: @escaping (SocketAnyEvent) -> ())

    /// Removes all handlers.
    ///
    /// Can be used after disconnecting to break any potential remaining retain cycles.
    func removeAllHandlers()

    /// Puts the socket back into the connecting state and tells it why the
    /// connection dropped. Called when the manager detects a broken connection,
    /// or when a manual reconnect is triggered.
    ///
    /// JS-aligned with `Socket.onclose` in `socket.io-client/lib/socket.ts`: the
    /// socket stops being connected and emits `disconnect` with the real reason,
    /// while staying subscribed to its manager so the namespace is re-joined.
    ///
    /// parameter reason: The reason this socket is going reconnecting.
    func setReconnecting(reason: String)
}

public extension SocketIOClientSpec {
    /// Default implementation.
    func didError(reason: String) {
        DefaultSocketLogger.Logger.error("\(reason)", type: "SocketIOClient")

        handleClientEvent(.error, data: [reason])
    }

    /// Default implementation. Concrete `SocketIOClient` overrides with real state.
    var recovered: Bool { false }

    /// Default implementation. Sugar for `emit("message", ...)`.
    func send(_ items: SocketData..., completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    /// Default implementation. Sugar for `emit("message", ...)`.
    func send(with items: [SocketData], completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    /// Default implementation. Sugar for `emitWithAck("message", ...)`.
    func sendWithAck(_ items: SocketData...) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }

    /// Default implementation. Sugar for `emitWithAck("message", ...)`.
    func sendWithAck(with items: [SocketData]) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }
}

/// The set of events that are generated by the client.
public enum SocketClientEvent : String {
    // MARK: Cases

    /// Emitted when the client connects. This is also called on a successful reconnection.
    ///
    /// The first data item is always the namespace that was connected to. A second
    /// data item may be present with the CONNECT payload from the server, including `recovered` when Connection State
    /// Recovery is enabled.
    ///
    /// ```swift
    /// socket.on(clientEvent: .connect) {data, ack in
    ///     guard let nsp = data[0] as? String else { return }
    ///     let payload = data.dropFirst().first as? [String: Any]
    ///     let recovered = payload?["recovered"] as? Bool
    ///     // Some logic using the nsp / recovered
    /// }
    /// ```
    case connect

    /// Emitted for each socket close, including closes the manager will retry.
    /// `reconnectFailed` reports that the reconnection attempt budget is exhausted.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .disconnect) {data, ack in
    ///     // Some cleanup logic
    /// }
    /// ```
    case disconnect

    /// Emitted when an error occurs.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .error) {data, ack in
    ///     // Some logging
    /// }
    /// ```
    case error

    /// Emitted when the connection or namespace join fails, JS-aligned with `connect_error` in
    /// `socket.io-client/lib/socket.ts` (`onerror`, `onpacket`).
    ///
    /// Fires instead of `.error` for: a server CONNECT_ERROR refusal (namespace middleware rejection),
    /// a CONNECT packet without `sid` from an incompatible server, an engine/transport error
    /// while not connected, and the connection timeout. For a middleware refusal the first data item
    /// is the packet payload dictionary with `"message"` and optional `"data"`; for the other cases
    /// the first data item is a String message (`"timeout"` for the connection timeout).
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .connectError) {data, ack in
    ///     // Some connection-failure handling
    /// }
    /// ```
    case connectError = "connect_error"

    /// Emitted whenever the engine sends a ping.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .ping) {_, _ in
    ///   // Maybe keep track of latency?
    /// }
    /// ```
    case ping

    /// Emitted whenever the engine gets a pong.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .pong) {_, _ in
    ///   // Maybe keep track of latency?
    /// }
    /// ```
    case pong

    /// Emitted when a reconnection **succeeded**, JS-aligned with `reconnect` in
    /// `socket.io-client/lib/manager.ts` (`onreconnect`).
    ///
    /// The first data item is the 1-based number of the attempt that succeeded
    /// (`Int`). Fires once the transport is open again, before the namespaces
    /// are re-joined, so it always precedes the `.connect` that follows the
    /// server's CONNECT ack.
    ///
    /// **Changed in 17.0.0**: this used to fire when reconnection *started* and
    /// carried the disconnect reason. The reason now arrives with `.disconnect`,
    /// exactly as it does in JS.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .reconnect) {data, ack in
    ///     let attempt = data.first as? Int
    ///     // Some reconnect-success logic
    /// }
    /// ```
    case reconnect

    /// Emitted each time the client tries to reconnect to the server, JS-aligned
    /// with `reconnect_attempt` in `socket.io-client/lib/manager.ts`.
    ///
    /// The first data item is the 1-based attempt number (`Int`): `1` for the
    /// first attempt of a reconnection loop, `2` for the second, and so on.
    ///
    /// **Changed in 17.0.0**: the payload used to be the number of attempts
    /// *remaining*.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .reconnectAttempt) {data, ack in
    ///     let attempt = data.first as? Int
    ///     // Some reconnect attempt logging
    /// }
    /// ```
    case reconnectAttempt

    /// Emitted when a single reconnection attempt failed, JS-aligned with
    /// `reconnect_error` in `socket.io-client/lib/manager.ts`.
    ///
    /// The first data item is the reason the attempt failed (`String`), e.g.
    /// `"timeout"` for a connection that did not finish its handshake in time.
    /// The next attempt — if the budget allows one — is already scheduled when
    /// this fires.
    ///
    /// **New in 17.0.0.**
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .reconnectError) {data, ack in
    ///     // Some per-attempt failure logging
    /// }
    /// ```
    case reconnectError = "reconnect_error"

    /// Emitted when the reconnection budget (`.reconnectAttempts`) is exhausted,
    /// JS-aligned with `reconnect_failed` in `socket.io-client/lib/manager.ts`.
    /// Carries no data.
    ///
    /// The sockets already received their `.disconnect` with the real reason
    /// when the connection dropped, so no further `.disconnect` is emitted here.
    ///
    /// **New in 17.0.0**: replaces the Swift-only `.disconnect("Reconnect Failed")`.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .reconnectFailed) {_, _ in
    ///     // Give up, or start a new cycle with socket.connect()
    /// }
    /// ```
    case reconnectFailed = "reconnect_failed"

    /// Emitted every time there is a change in the client's status.
    ///
    /// The payload for data is [SocketIOClientStatus, Int]. Where the second item is the raw value. Use the second one
    /// if you are working in Objective-C.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .statusChange) {data, ack in
    ///     // Some status changing logging
    /// }
    /// ```
    case statusChange

    /// Emitted when when upgrading the http connection to a websocket connection.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.on(clientEvent: .websocketUpgrade) {data, ack in
    ///     let headers = (data as [Any])[0]
    ///     // Some header logic
    /// }
    /// ```
    case websocketUpgrade
}
