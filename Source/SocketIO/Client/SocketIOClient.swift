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

/// The main class for SocketIOClientSwift.
///
/// **NOTE**: The client is not thread/queue safe, all interaction with the socket should be done on the `handleQueue`
///
/// Represents a socket.io-client. Most interaction with socket.io will be through this class.
open class SocketIOClient : NSObject, SocketIOClientSpec, SocketEngineClient, SocketParsable {
    // MARK: Properties

    private static let logType = "SocketIOClient"

    /// If `true` then every time `connect` is called, a new engine will be created.
    @objc
    public var forceNew = false

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    @objc
    public var handleQueue = DispatchQueue.main

    /// The namespace that this socket is currently connected to.
    ///
    /// **Must** start with a `/`.
    @objc
    public var nsp = "/"

    /// The configuration for this client.
    ///
    /// **This cannot be set after calling one of the connect methods**.
    public var config: SocketIOClientConfiguration {
        get {
            return _config
        }

        set {
            guard status == .notConnected else {
                DefaultSocketLogger.Logger.error("Tried setting config after calling connect",
                                                 type: SocketIOClient.logType)
                return
            }

            _config = newValue

            if socketURL.absoluteString.hasPrefix("https://") {
                _config.insert(.secure(true))
            }

            _config.insert(.path("/socket.io/"), replacing: false)
            setConfigs()
        }
    }

    /// If `true`, this client will try and reconnect on any disconnects.
    @objc
    public var reconnects = true

    /// The number of seconds to wait before attempting to reconnect.
    @objc
    public var reconnectWait = 10

    /// The session id of this client.
    @objc
    public var sid: String? {
        return engine?.sid
    }

    /// The URL of the socket.io server.
    ///
    /// If changed after calling `init`, `forceNew` must be set to `true`, or it will only connect to the url set in the
    /// init.
    @objc
    public var socketURL: URL

    /// A list of packets that are waiting for binary data.
    ///
    /// The way that socket.io works all data should be sent directly after each packet.
    /// So this should ideally be an array of one packet waiting for data.
    ///
    /// **This should not be modified directly.**
    public var waitingPackets = [SocketPacket]()

    /// A handler that will be called on any event.
    public private(set) var anyHandler: ((SocketAnyEvent) -> ())?

    /// The engine for this client.
    @objc
    public internal(set) var engine: SocketEngineSpec?

    /// The array of handlers for this socket.
    public private(set) var handlers = [SocketEventHandler]()

    /// The status of this client.
    @objc
    public private(set) var status = SocketIOClientStatus.notConnected {
        didSet {
            switch status {
            case .connected:
                reconnecting = false
                currentReconnectAttempt = 0
            default:
                break
            }

            handleClientEvent(.statusChange, data: [status])
        }
    }

    var ackHandlers = SocketAckManager()

    private(set) var currentAck = -1
    private(set) var reconnectAttempts = -1

    private var _config: SocketIOClientConfiguration
    private var currentReconnectAttempt = 0
    private var reconnecting = false

    // MARK: Initializers

    /// Type safe way to create a new SocketIOClient. `opts` can be omitted.
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    public init(socketURL: URL, config: SocketIOClientConfiguration = []) {
        self._config = config
        self.socketURL = socketURL

        if socketURL.absoluteString.hasPrefix("https://") {
            self._config.insert(.secure(true))
        }

        self._config.insert(.path("/socket.io/"), replacing: false)

        super.init()

        setConfigs()
    }

    /// Not so type safe way to create a SocketIOClient, meant for Objective-C compatiblity.
    /// If using Swift it's recommended to use `init(socketURL: NSURL, options: Set<SocketIOClientOption>)`
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    @objc
    public convenience init(socketURL: NSURL, config: NSDictionary?) {
        self.init(socketURL: socketURL as URL, config: config?.toSocketConfiguration() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Client is being released", type: SocketIOClient.logType)
        engine?.disconnect(reason: "Client Deinit")
    }

    // MARK: Methods

    private func addEngine() {
        DefaultSocketLogger.Logger.log("Adding engine", type: SocketIOClient.logType)

        engine?.engineQueue.sync {
            self.engine?.client = nil
        }

        engine = SocketEngine(client: self, url: socketURL, config: config)
    }

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
    /// - parameter withHandler: The handler to call when the client fails to connect.
    @objc
    open func connect(timeoutAfter: Double, withHandler handler: (() -> ())?) {
        assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

        guard status != .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting on an already connected socket",
                                           type: SocketIOClient.logType)
            return
        }

        status = .connecting

        if engine == nil || forceNew {
            addEngine()
        }

        engine?.connect()

        guard timeoutAfter != 0 else { return }

        handleQueue.asyncAfter(deadline: DispatchTime.now() + timeoutAfter) {[weak self] in
            guard let this = self, this.status == .connecting || this.status == .notConnected else { return }

            this.status = .disconnected
            this.engine?.disconnect(reason: "Connect timeout")

            handler?()
        }
    }

    private func createOnAck(_ items: [Any]) -> OnAckCallback {
        currentAck += 1

        return OnAckCallback(ackNumber: currentAck, items: items, socket: self)
    }

    /// Called when the client connects to a namespace. If the client was created with a namespace upfront,
    /// then this is only called when the client connects to that namespace.
    ///
    /// - parameter toNamespace: The namespace that was connected to.
    open func didConnect(toNamespace namespace: String) {
        guard status != .connected else { return }

        DefaultSocketLogger.Logger.log("Socket connected", type: SocketIOClient.logType)

        status = .connected

        handleClientEvent(.connect, data: [namespace])
    }

    /// Called when the client has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        guard status != .disconnected else { return }

        DefaultSocketLogger.Logger.log("Disconnected: \(reason)", type: SocketIOClient.logType)

        reconnecting = false
        status = .disconnected

        // Make sure the engine is actually dead.
        engine?.disconnect(reason: reason)
        handleClientEvent(.disconnect, data: [reason])
    }

    /// Disconnects the socket.
    @objc
    open func disconnect() {
        DefaultSocketLogger.Logger.log("Closing socket", type: SocketIOClient.logType)

        didDisconnect(reason: "Disconnect")
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
                                             type: SocketIOClient.logType)

            handleClientEvent(.error, data: [event, items, err])
        }
    }

    /// Same as emit, but meant for Objective-C
    ///
    /// - parameter event: The event to send.
    /// - parameter with: The items to send with this event. Send an empty array to send no data.
    @objc
    open func emit(_ event: String, with items: [Any]) {
        guard status == .connected else {
            handleClientEvent(.error, data: ["Tried emitting \(event) when not connected"])
            return
        }

        emit([event] + items)
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
                                             type: SocketIOClient.logType)

            handleClientEvent(.error, data: [event, items, err])

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
    /// - parameter with: The items to send with this event. Use `[]` to send nothing.
    /// - returns: An `OnAckCallback`. You must call the `timingOut(after:)` method before the event will be sent.
    @objc
    open func emitWithAck(_ event: String, with items: [Any]) -> OnAckCallback {
        return createOnAck([event] + items)
    }

    func emit(_ data: [Any], ack: Int? = nil) {
        guard status == .connected else {
            handleClientEvent(.error, data: ["Tried emitting when not connected"])
            return
        }

        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: false)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting: \(str)", type: SocketIOClient.logType)

        engine?.send(str, withData: packet.binary)
    }

    /// Call when you wish to tell the server that you've received the event for `ack`.
    ///
    /// **You shouldn't need to call this directly.** Instead use an `SocketAckEmitter` that comes in an event callback.
    ///
    /// - parameter ack: The ack number.
    /// - parameter with: The data for this ack.
    open func emitAck(_ ack: Int, with items: [Any]) {
        guard status == .connected else { return }

        let packet = SocketPacket.packetFromEmit(items, id: ack, nsp: nsp, ack: true)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting Ack: \(str)", type: SocketIOClient.logType)

        engine?.send(str, withData: packet.binary)
    }

    /// Called when the engine closes.
    ///
    /// - parameter reason: The reason that the engine closed.
    open func engineDidClose(reason: String) {
        handleQueue.async {
            self._engineDidClose(reason: reason)
        }
    }

    private func _engineDidClose(reason: String) {
        waitingPackets.removeAll()

        if status != .disconnected {
            status = .notConnected
        }

        if status == .disconnected || !reconnects {
            didDisconnect(reason: reason)
        } else if !reconnecting {
            reconnecting = true
            tryReconnect(reason: reason)
        }
    }

    /// Called when the engine errors.
    ///
    /// - parameter reason: The reason the engine errored.
    open func engineDidError(reason: String) {
        handleQueue.async {
            self._engineDidError(reason: reason)
        }
    }

    private func _engineDidError(reason: String) {
        DefaultSocketLogger.Logger.error("\(reason)", type: SocketIOClient.logType)

        handleClientEvent(.error, data: [reason])
    }

    /// Called when the engine opens.
    ///
    /// - parameter reason: The reason the engine opened.
    open func engineDidOpen(reason: String) {
        handleQueue.async {
            self._engineDidOpen(reason: reason)
        }
    }

    private func _engineDidOpen(reason: String) {
        DefaultSocketLogger.Logger.log("Engine opened \(reason)", type: SocketIOClient.logType)

        guard nsp != "/" else {
            didConnect(toNamespace: "/")

            return
        }

        joinNamespace(nsp)
    }

    /// Called when socket.io has acked one of our emits. Causes the corresponding ack callback to be called.
    ///
    /// - parameter ack: The number for this ack.
    /// - parameter data: The data sent back with this ack.
    @objc
    open func handleAck(_ ack: Int, data: [Any]) {
        guard status == .connected else { return }

        DefaultSocketLogger.Logger.log("Handling ack: \(ack) with data: \(data)", type: SocketIOClient.logType)

        ackHandlers.executeAck(ack, with: data, onQueue: handleQueue)
    }

    /// Called when we get an event from socket.io.
    ///
    /// - parameter event: The name of the event.
    /// - parameter data: The data that was sent with this event.
    /// - parameter isInternalMessage: Whether this event was sent internally. If `true` it is always sent to handlers.
    /// - parameter withAck: If > 0 then this event expects to get an ack back from the client.
    @objc
    open func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int = -1) {
        guard status == .connected || isInternalMessage else { return }

        DefaultSocketLogger.Logger.log("Handling event: \(event) with data: \(data)", type: SocketIOClient.logType)

        anyHandler?(SocketAnyEvent(event: event, items: data))

        for handler in handlers where handler.event == event {
            handler.executeCallback(with: data, withAck: ack, withSocket: self)
        }
    }

    /// Called on socket.io specific events.
    ///
    /// - parameter event: The `SocketClientEvent`.
    /// - parameter data: The data for this event.
    open func handleClientEvent(_ event: SocketClientEvent, data: [Any]) {
        handleEvent(event.rawValue, data: data, isInternalMessage: true)
    }

    /// Call when you wish to leave a namespace and return to the default namespace.
    @objc
    open func leaveNamespace() {
        guard nsp != "/" else { return }

        engine?.send("1\(nsp)", withData: [])
        nsp = "/"
    }

    /// Joins `namespace`.
    ///
    /// **Do not use this to join the default namespace.** Instead call `leaveNamespace`.
    ///
    /// - parameter namespace: The namespace to join.
    @objc
    open func joinNamespace(_ namespace: String) {
        guard namespace != "/" else { return }

        DefaultSocketLogger.Logger.log("Joining namespace \(namespace)", type: SocketIOClient.logType)

        nsp = namespace
        engine?.send("0\(nsp)", withData: [])
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
        DefaultSocketLogger.Logger.log("Removing handler for event: \(event)", type: SocketIOClient.logType)

        handlers = handlers.filter({ $0.event != event })
    }

    /// Removes a handler with the specified UUID gotten from an `on` or `once`
    ///
    /// If you want to remove all events for an event, call the off `off(_:)` method with the event name.
    ///
    /// - parameter id: The UUID of the handler you wish to remove.
    @objc
    open func off(id: UUID) {
        DefaultSocketLogger.Logger.log("Removing handler with id: \(id)", type: SocketIOClient.logType)

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
        DefaultSocketLogger.Logger.log("Adding handler for event: \(event)", type: SocketIOClient.logType)

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
        DefaultSocketLogger.Logger.log("Adding handler for event: \(event)", type: SocketIOClient.logType)

        let handler = SocketEventHandler(event: event.rawValue, id: UUID(), callback: callback)
        handlers.append(handler)

        return handler.id
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
        DefaultSocketLogger.Logger.log("Adding once handler for event: \(event)", type: SocketIOClient.logType)

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

    /// Called when the engine has a message that must be parsed.
    ///
    /// - parameter msg: The message that needs parsing.
    public func parseEngineMessage(_ msg: String) {
        DefaultSocketLogger.Logger.log("Should parse message: \(msg)", type: SocketIOClient.logType)

        handleQueue.async { self.parseSocketMessage(msg) }
    }

    /// Called when the engine receives binary data.
    ///
    /// - parameter data: The data the engine received.
    public func parseEngineBinaryData(_ data: Data) {
        handleQueue.async { self.parseBinaryData(data) }
    }

    /// Tries to reconnect to the server.
    ///
    /// This will cause a `disconnect` event to be emitted, as well as an `reconnectAttempt` event.
    @objc
    open func reconnect() {
        guard !reconnecting else { return }

        engine?.disconnect(reason: "manual reconnect")
    }

    /// Removes all handlers.
    ///
    /// Can be used after disconnecting to break any potential remaining retain cycles.
    @objc
    open func removeAllHandlers() {
        handlers.removeAll(keepingCapacity: false)
    }

    private func tryReconnect(reason: String) {
        guard reconnecting else { return }

        DefaultSocketLogger.Logger.log("Starting reconnect", type: SocketIOClient.logType)
        handleClientEvent(.reconnect, data: [reason])

        _tryReconnect()
    }

    private func _tryReconnect() {
        guard reconnects && reconnecting && status != .disconnected else { return }

        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts {
            return didDisconnect(reason: "Reconnect Failed")
        }

        DefaultSocketLogger.Logger.log("Trying to reconnect", type: SocketIOClient.logType)
        handleClientEvent(.reconnectAttempt, data: [(reconnectAttempts - currentReconnectAttempt)])

        currentReconnectAttempt += 1
        connect()

        handleQueue.asyncAfter(deadline: DispatchTime.now() + Double(reconnectWait), execute: _tryReconnect)
    }

    private func setConfigs() {
        for option in config {
            switch option {
            case let .reconnects(reconnects):
                self.reconnects = reconnects
            case let .reconnectAttempts(attempts):
                reconnectAttempts = attempts
            case let .reconnectWait(wait):
                reconnectWait = abs(wait)
            case let .nsp(nsp):
                self.nsp = nsp
            case let .log(log):
                DefaultSocketLogger.Logger.log = log
            case let .logger(logger):
                DefaultSocketLogger.Logger = logger
            case let .handleQueue(queue):
                handleQueue = queue
            case let .forceNew(force):
                forceNew = force
            default:
                continue
            }
        }
    }

    // Test properties

    var testHandlers: [SocketEventHandler] {
        return handlers
    }

    func setTestable() {
        status = .connected
    }

    func setTestStatus(_ status: SocketIOClientStatus) {
        self.status = status
    }

    func setTestEngine(_ engine: SocketEngineSpec?) {
        self.engine = engine
    }

    func emitTest(event: String, _ data: Any...) {
        emit([event] + data)
    }
}
