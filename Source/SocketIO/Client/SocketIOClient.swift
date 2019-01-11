//
//  SocketIOClient.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 11/23/14.
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

/// Represents a socket.io-client.
///
/// Clients are created through a `SocketManager`, which owns the `SocketEngineSpec` that controls the connection to the server.
///
/// For example:
///
/// ```swift
/// // Create a socket for the /swift namespace
/// let socket = manager.socket(forNamespace: "/swift")
///
/// // Add some handlers and connect
/// ```
///
/// **NOTE**: The client is not thread/queue safe, all interaction with the socket should be done on the `manager.handleQueue`
///
open class SocketIOClient : NSObject, SocketIOClientSpec {
    // MARK: Properties

    /// The namespace that this socket is currently connected to.
    ///
    /// **Must** start with a `/`.
    @objc
    public let nsp: String

    /// The session id of this client.
    @objc
    public var sid: String {
        guard let engine = manager?.engine else { return "" }

        return nsp == "/" ? engine.sid : "\(nsp)#\(engine.sid)"
    }

    /// A handler that will be called on any event.
    public private(set) var anyHandler: ((SocketAnyEvent) -> ())?

    /// The array of handlers for this socket.
    public private(set) var handlers = [SocketEventHandler]()

    /// The manager for this socket.
    @objc
    public private(set) weak var manager: SocketManagerSpec?

    /// A view into this socket where emits do not check for binary data.
    ///
    /// Usage:
    ///
    /// ```swift
    /// socket.rawEmitView.emit("myEvent", myObject)
    /// ```
    ///
    /// **NOTE**: It is not safe to hold on to this view beyond the life of the socket.
    @objc
    public private(set) lazy var rawEmitView = SocketRawView(socket: self)

    /// The status of this client.
    @objc
    public private(set) var status = SocketIOStatus.notConnected {
        didSet {
            handleClientEvent(.statusChange, data: [status, status.rawValue])
        }
    }

    let ackHandlers = SocketAckManager()

    private(set) var currentAck = -1

    private lazy var logType = "SocketIOClient{\(nsp)}"

    // MARK: Initializers

    /// Type safe way to create a new SocketIOClient. `opts` can be omitted.
    ///
    /// - parameter manager: The manager for this socket.
    /// - parameter nsp: The namespace of the socket.
    @objc
    public init(manager: SocketManagerSpec, nsp: String) {
        self.manager = manager
        self.nsp = nsp

        super.init()
    }

    deinit {
        DefaultSocketLogger.Logger.log("Client is being released", type: logType)
    }

    // MARK: Methods

    /// Connect to the server. The same as calling `connect(timeoutAfter:withHandler:)` with a timeout of 0.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    @objc
    open func connect() {
        connect(timeoutAfter: 0, withHandler: nil)
    }

    /// Connect to the server. If we aren't connected after `timeoutAfter` seconds, then `withHandler` is called.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    ///
    /// - parameter timeoutAfter: The number of seconds after which if we are not connected we assume the connection
    ///                           has failed. Pass 0 to never timeout.
    /// - parameter handler: The handler to call when the client fails to connect.
    @objc
    open func connect(timeoutAfter: Double, withHandler handler: (() -> ())?) {
        assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

        guard let manager = self.manager, status != .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting on an already connected socket", type: logType)
            return
        }

        status = .connecting

        joinNamespace()

        if manager.status == .connected && nsp == "/" {
            // We might not get a connect event for the default nsp, fire immediately
            didConnect(toNamespace: nsp)

            return
        }

        guard timeoutAfter != 0 else { return }

        manager.handleQueue.asyncAfter(deadline: DispatchTime.now() + timeoutAfter) {[weak self] in
            guard let this = self, this.status == .connecting || this.status == .notConnected else { return }

            this.status = .disconnected
            this.leaveNamespace()

            handler?()
        }
    }

    func createOnAck(_ items: [Any], binary: Bool = true) -> OnAckCallback {
        currentAck += 1

        return OnAckCallback(ackNumber: currentAck, items: items, socket: self)
    }

    /// Called when the client connects to a namespace. If the client was created with a namespace upfront,
    /// then this is only called when the client connects to that namespace.
    ///
    /// - parameter toNamespace: The namespace that was connected to.
    open func didConnect(toNamespace namespace: String) {
        guard status != .connected else { return }

        DefaultSocketLogger.Logger.log("Socket connected", type: logType)

        status = .connected

        handleClientEvent(.connect, data: [namespace])
    }

    /// Called when the client has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        guard status != .disconnected else { return }

        DefaultSocketLogger.Logger.log("Disconnected: \(reason)", type: logType)

        status = .disconnected

        handleClientEvent(.disconnect, data: [reason])
    }

    /// Disconnects the socket.
    ///
    /// This will cause the socket to leave the namespace it is associated to, as well as remove itself from the
    /// `manager`.
    @objc
    open func disconnect() {
        DefaultSocketLogger.Logger.log("Closing socket", type: logType)

        leaveNamespace()
    }

    /// Send an event to the server, with optional data items and optional write completion handler.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    open func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil)  {
        do {
            try emit(event, with: items.map({ try $0.socketRepresentation() }), completion: completion)
        } catch {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, error])
        }
    }

    /// Same as emit, but meant for Objective-C
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. Send an empty array to send no data.
    @objc
    open func emit(_ event: String, with items: [Any]) {
        emit([event] + items)
    }

    /// Same as emit, but meant for Objective-C
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. Send an empty array to send no data.
    /// - parameter completion: Callback called on transport write completion.
    @objc
    open func emit(_ event: String, with items: [Any], completion: (() -> ())? = nil) {
        emit([event] + items, completion: completion)
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
        } catch {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, error])

            return OnAckCallback(ackNumber: -1, items: [], socket: self)
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
        return createOnAck([event] + items)
    }

    func emit(_ data: [Any],
              ack: Int? = nil,
              binary: Bool = true,
              isAck: Bool = false,
              completion: (() -> ())? = nil
    ) {
        // wrap the completion handler so it always runs async via handlerQueue
        let wrappedCompletion: (() -> ())? = (completion == nil) ? nil : {[weak self] in
            guard let this = self else { return }
            this.manager?.handleQueue.async {
                completion!()
            }
        }

        guard status == .connected else {
            wrappedCompletion?()
            handleClientEvent(.error, data: ["Tried emitting when not connected"])
            return
        }

        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: isAck, checkForBinary: binary)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting: \(str), Ack: \(isAck)", type: logType)

        manager?.engine?.send(str, withData: packet.binary, completion: wrappedCompletion)
    }

    /// Call when you wish to tell the server that you've received the event for `ack`.
    ///
    /// **You shouldn't need to call this directly.** Instead use an `SocketAckEmitter` that comes in an event callback.
    ///
    /// - parameter ack: The ack number.
    /// - parameter with: The data for this ack.
    open func emitAck(_ ack: Int, with items: [Any]) {
        emit(items, ack: ack, binary: true, isAck: true)
    }

    /// Called when socket.io has acked one of our emits. Causes the corresponding ack callback to be called.
    ///
    /// - parameter ack: The number for this ack.
    /// - parameter data: The data sent back with this ack.
    @objc
    open func handleAck(_ ack: Int, data: [Any]) {
        guard status == .connected else { return }

        DefaultSocketLogger.Logger.log("Handling ack: \(ack) with data: \(data)", type: logType)

        ackHandlers.executeAck(ack, with: data)
    }

    /// Called on socket.io specific events.
    ///
    /// - parameter event: The `SocketClientEvent`.
    /// - parameter data: The data for this event.
    open func handleClientEvent(_ event: SocketClientEvent, data: [Any]) {
        handleEvent(event.rawValue, data: data, isInternalMessage: true)
    }

    /// Called when we get an event from socket.io.
    ///
    /// - parameter event: The name of the event.
    /// - parameter data: The data that was sent with this event.
    /// - parameter isInternalMessage: Whether this event was sent internally. If `true` it is always sent to handlers.
    /// - parameter ack: If > 0 then this event expects to get an ack back from the client.
    @objc
    open func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int = -1) {
        guard status == .connected || isInternalMessage else { return }

        DefaultSocketLogger.Logger.log("Handling event: \(event) with data: \(data)", type: logType)

        anyHandler?(SocketAnyEvent(event: event, items: data))

        for handler in handlers where handler.event == event {
            handler.executeCallback(with: data, withAck: ack, withSocket: self)
        }
    }

    /// Causes a client to handle a socket.io packet. The namespace for the packet must match the namespace of the
    /// socket.
    ///
    /// - parameter packet: The packet to handle.
    open func handlePacket(_ packet: SocketPacket) {
        guard packet.nsp == nsp else { return }

        switch packet.type {
        case .event, .binaryEvent:
            handleEvent(packet.event, data: packet.args, isInternalMessage: false, withAck: packet.id)
        case .ack, .binaryAck:
            handleAck(packet.id, data: packet.data)
        case .connect:
            didConnect(toNamespace: nsp)
        case .disconnect:
            didDisconnect(reason: "Got Disconnect")
        case .error:
            handleEvent("error", data: packet.data, isInternalMessage: true, withAck: packet.id)
        }
    }

    /// Call when you wish to leave a namespace and disconnect this socket.
    @objc
    open func leaveNamespace() {
        manager?.disconnectSocket(self)
    }

    /// Joins `nsp`.
    @objc
    open func joinNamespace() {
        DefaultSocketLogger.Logger.log("Joining namespace \(nsp)", type: logType)

        manager?.connectSocket(self)
    }

    /// Removes handler(s) for a client event.
    ///
    /// If you wish to remove a client event handler, call the `off(id:)` with the UUID received from its `on` call.
    ///
    /// - parameter clientEvent: The event to remove handlers for.
    open func off(clientEvent event: SocketClientEvent) {
        off(event.rawValue)
    }

    /// Removes handler(s) based on an event name.
    ///
    /// If you wish to remove a specific event, call the `off(id:)` with the UUID received from its `on` call.
    ///
    /// - parameter event: The event to remove handlers for.
    @objc
    open func off(_ event: String) {
        DefaultSocketLogger.Logger.log("Removing handler for event: \(event)", type: logType)

        handlers = handlers.filter({ $0.event != event })
    }

    /// Removes a handler with the specified UUID gotten from an `on` or `once`
    ///
    /// If you want to remove all events for an event, call the off `off(_:)` method with the event name.
    ///
    /// - parameter id: The UUID of the handler you wish to remove.
    @objc
    open func off(id: UUID) {
        DefaultSocketLogger.Logger.log("Removing handler with id: \(id)", type: logType)

        handlers = handlers.filter({ $0.id != id })
    }

    /// Adds a handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @objc
    @discardableResult
    open func on(_ event: String, callback: @escaping NormalCallback) -> UUID {
        DefaultSocketLogger.Logger.log("Adding handler for event: \(event)", type: logType)

        let handler = SocketEventHandler(event: event, id: UUID(), callback: callback)
        handlers.append(handler)

        return handler.id
    }

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
    @discardableResult
    open func on(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID {
        return on(event.rawValue, callback: callback)
    }

    /// Adds a single-use handler for a client event.
    ///
    /// - parameter clientEvent: The event for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @discardableResult
    open func once(clientEvent event: SocketClientEvent, callback: @escaping NormalCallback) -> UUID {
        return once(event.rawValue, callback: callback)
    }

    /// Adds a single-use handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @objc
    @discardableResult
    open func once(_ event: String, callback: @escaping NormalCallback) -> UUID {
        DefaultSocketLogger.Logger.log("Adding once handler for event: \(event)", type: logType)

        let id = UUID()

        let handler = SocketEventHandler(event: event, id: id) {[weak self] data, ack in
            guard let this = self else { return }
            this.off(id: id)
            callback(data, ack)
        }

        handlers.append(handler)

        return handler.id
    }

    /// Adds a handler that will be called on every event.
    ///
    /// - parameter handler: The callback that will execute whenever an event is received.
    @objc
    open func onAny(_ handler: @escaping (SocketAnyEvent) -> ()) {
        anyHandler = handler
    }

    /// Tries to reconnect to the server.
    @objc
    @available(*, unavailable, message: "Call the manager's reconnect method")
    open func reconnect() { }

    /// Removes all handlers.
    ///
    /// Can be used after disconnecting to break any potential remaining retain cycles.
    @objc
    open func removeAllHandlers() {
        handlers.removeAll(keepingCapacity: false)
    }

    /// Puts the socket back into the connecting state.
    /// Called when the manager detects a broken connection, or when a manual reconnect is triggered.
    ///
    /// - parameter reason: The reason this socket is reconnecting.
    @objc
    open func setReconnecting(reason: String) {
        status = .connecting

        handleClientEvent(.reconnect, data: [reason])
    }

    // Test properties

    var testHandlers: [SocketEventHandler] {
        return handlers
    }

    func setTestable() {
        status = .connected
    }

    func setTestStatus(_ status: SocketIOStatus) {
        self.status = status
    }

    func emitTest(event: String, _ data: Any...) {
        emit([event] + data)
    }
}
