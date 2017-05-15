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
/// Represents a socket.io-client. Most interaction with socket.io will be through this class.
open class SocketIOClient : NSObject, SocketIOClientSpec, SocketEngineClient, SocketParsable {
    // MARK: Properties

    /// The URL of the socket.io server. This is set in the initializer.
    public let socketURL: URL

    /// The engine for this client.
    public private(set) var engine: SocketEngineSpec?

    /// The status of this client.
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

    /// If `true` then every time `connect` is called, a new engine will be created.
    public var forceNew = false

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    public var handleQueue = DispatchQueue.main

    /// The namespace for this client.
    public var nsp = "/"

    /// The configuration for this client.
    public var config: SocketIOClientConfiguration

    /// If `true`, this client will try and reconnect on any disconnects.
    public var reconnects = true

    /// The number of seconds to wait before attempting to reconnect.
    public var reconnectWait = 10

    /// The session id of this client.
    public var sid: String? {
        return engine?.sid
    }

    private let logType = "SocketIOClient"

    private var anyHandler: ((SocketAnyEvent) -> Void)?
    private var currentReconnectAttempt = 0
    private var handlers = [SocketEventHandler]()
    private var reconnecting = false

    private(set) var currentAck = -1
    private(set) var reconnectAttempts = -1

    var ackHandlers = SocketAckManager()
    var waitingPackets = [SocketPacket]()

    // MARK: Initializers

    /// Type safe way to create a new SocketIOClient. `opts` can be omitted.
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    public init(socketURL: URL, config: SocketIOClientConfiguration = []) {
        self.config = config
        self.socketURL = socketURL

        if socketURL.absoluteString.hasPrefix("https://") {
            self.config.insert(.secure(true))
        }

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

        self.config.insert(.path("/socket.io/"), replacing: false)

        super.init()
    }

    /// Not so type safe way to create a SocketIOClient, meant for Objective-C compatiblity.
    /// If using Swift it's recommended to use `init(socketURL: NSURL, options: Set<SocketIOClientOption>)`
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    public convenience init(socketURL: NSURL, config: NSDictionary?) {
        self.init(socketURL: socketURL as URL, config: config?.toSocketConfiguration() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Client is being released", type: logType)
        engine?.disconnect(reason: "Client Deinit")
    }

    // MARK: Methods

    private func addEngine() -> SocketEngineSpec {
        DefaultSocketLogger.Logger.log("Adding engine", type: logType, args: "")

        engine?.client = nil
        engine = SocketEngine(client: self, url: socketURL, config: config)

        return engine!
    }

    /// Connect to the server.
    open func connect() {
        connect(timeoutAfter: 0, withHandler: nil)
    }

    /// Connect to the server. If we aren't connected after `timeoutAfter` seconds, then `withHandler` is called.
    ///
    /// - parameter timeoutAfter: The number of seconds after which if we are not connected we assume the connection
    ///                           has failed. Pass 0 to never timeout.
    /// - parameter withHandler: The handler to call when the client fails to connect.
    open func connect(timeoutAfter: Int, withHandler handler: (() -> Void)?) {
        assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

        guard status != .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting on an already connected socket", type: logType)
            return
        }

        status = .connecting

        if engine == nil || forceNew {
            addEngine().connect()
        } else {
            engine?.connect()
        }

        guard timeoutAfter != 0 else { return }

        handleQueue.asyncAfter(deadline: DispatchTime.now() + Double(timeoutAfter)) {[weak self] in
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

    func didConnect() {
        DefaultSocketLogger.Logger.log("Socket connected", type: logType)

        status = .connected

        handleClientEvent(.connect, data: [])
    }

    func didDisconnect(reason: String) {
        guard status != .disconnected else { return }

        DefaultSocketLogger.Logger.log("Disconnected: %@", type: logType, args: reason)

        reconnecting = false
        status = .disconnected

        // Make sure the engine is actually dead.
        engine?.disconnect(reason: reason)
        handleClientEvent(.disconnect, data: [reason])
    }

    /// Disconnects the socket.
    open func disconnect() {
        DefaultSocketLogger.Logger.log("Closing socket", type: logType)

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
            emit(event, with: try items.map({ try $0.socketRepresentation() }))
        } catch let err {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, err])
        }
    }

    /// Same as emit, but meant for Objective-C
    ///
    /// - parameter event: The event to send.
    /// - parameter with: The items to send with this event. May be left out.
    open func emit(_ event: String, with items: [Any]) {
        guard status == .connected else {
            handleClientEvent(.error, data: ["Tried emitting \(event) when not connected"])
            return
        }

        _emit([event] + items)
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
                                             type: logType)

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
    open func emitWithAck(_ event: String, with items: [Any]) -> OnAckCallback {
        return createOnAck([event] + items)
    }

    func _emit(_ data: [Any], ack: Int? = nil) {
        guard status == .connected else {
            handleClientEvent(.error, data: ["Tried emitting when not connected"])
            return
        }

        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: false)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting: %@", type: logType, args: str)

        engine?.send(str, withData: packet.binary)
    }

    // If the server wants to know that the client received data
    func emitAck(_ ack: Int, with items: [Any]) {
        guard status == .connected else { return }

        let packet = SocketPacket.packetFromEmit(items, id: ack, nsp: nsp, ack: true)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting Ack: %@", type: logType, args: str)

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
        DefaultSocketLogger.Logger.error("%@", type: logType, args: reason)

        handleClientEvent(.error, data: [reason])
    }

    /// Called when the engine opens.
    ///
    /// - parameter reason: The reason the engine opened.
    open func engineDidOpen(reason: String) {
        DefaultSocketLogger.Logger.log(reason, type: "SocketEngineClient")
    }

    // Called when the socket gets an ack for something it sent
    func handleAck(_ ack: Int, data: [Any]) {
        guard status == .connected else { return }

        DefaultSocketLogger.Logger.log("Handling ack: %@ with data: %@", type: logType, args: ack, data)

        ackHandlers.executeAck(ack, with: data, onQueue: handleQueue)
    }

    /// Causes an event to be handled, and any event handlers for that event to be called.
    ///
    /// - parameter event: The event that is to be handled.
    /// - parameter data: the data associated with this event.
    /// - parameter isInternalMessage: If `true` event handlers for this event will be called regardless of status.
    /// - parameter withAck: The ack number for this event. May be left out.
    open func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int = -1) {
        guard status == .connected || isInternalMessage else { return }

        DefaultSocketLogger.Logger.log("Handling event: %@ with data: %@", type: logType, args: event, data)

        anyHandler?(SocketAnyEvent(event: event, items: data))

        for handler in handlers where handler.event == event {
            handler.executeCallback(with: data, withAck: ack, withSocket: self)
        }
    }

    func handleClientEvent(_ event: SocketClientEvent, data: [Any]) {
        handleEvent(event.rawValue, data: data, isInternalMessage: true)
    }

    /// Leaves nsp and goes back to the default namespace.
    open func leaveNamespace() {
        if nsp != "/" {
            engine?.send("1\(nsp)", withData: [])
            nsp = "/"
        }
    }

    /// Joins `namespace`.
    ///
    /// **Do not use this to join the default namespace.** Instead call `leaveNamespace`.
    ///
    /// - parameter namespace: The namespace to join.
    open func joinNamespace(_ namespace: String) {
        nsp = namespace

        if nsp != "/" {
            DefaultSocketLogger.Logger.log("Joining namespace", type: logType)
            engine?.send("0\(nsp)", withData: [])
        }
    }

    /// Removes handler(s) based on an event name.
    ///
    /// If you wish to remove a specific event, call the `off(id:)` with the UUID received from its `on` call.
    ///
    /// - parameter event: The event to remove handlers for.
    open func off(_ event: String) {
        DefaultSocketLogger.Logger.log("Removing handler for event: %@", type: logType, args: event)

        handlers = handlers.filter({ $0.event != event })
    }

    /// Removes a handler with the specified UUID gotten from an `on` or `once`
    ///
    /// If you want to remove all events for an event, call the off `off(_:)` method with the event name.
    ///
    /// - parameter id: The UUID of the handler you wish to remove.
    open func off(id: UUID) {
        DefaultSocketLogger.Logger.log("Removing handler with id: %@", type: logType, args: id)

        handlers = handlers.filter({ $0.id != id })
    }

    /// Adds a handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @discardableResult
    open func on(_ event: String, callback: @escaping NormalCallback) -> UUID {
        DefaultSocketLogger.Logger.log("Adding handler for event: %@", type: logType, args: event)

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
        DefaultSocketLogger.Logger.log("Adding handler for event: %@", type: logType, args: event)

        let handler = SocketEventHandler(event: event.rawValue, id: UUID(), callback: callback)
        handlers.append(handler)

        return handler.id
    }


    /// Adds a single-use handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
    @discardableResult
    open func once(_ event: String, callback: @escaping NormalCallback) -> UUID {
        DefaultSocketLogger.Logger.log("Adding once handler for event: %@", type: logType, args: event)

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
    open func onAny(_ handler: @escaping (SocketAnyEvent) -> Void) {
        anyHandler = handler
    }

    /// Called when the engine has a message that must be parsed.
    ///
    /// - parameter msg: The message that needs parsing.
    public func parseEngineMessage(_ msg: String) {
        DefaultSocketLogger.Logger.log("Should parse message: %@", type: "SocketIOClient", args: msg)

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
    open func reconnect() {
        guard !reconnecting else { return }

        engine?.disconnect(reason: "manual reconnect")
    }

    /// Removes all handlers.
    /// Can be used after disconnecting to break any potential remaining retain cycles.
    open func removeAllHandlers() {
        handlers.removeAll(keepingCapacity: false)
    }

    private func tryReconnect(reason: String) {
        guard reconnecting else { return }

        DefaultSocketLogger.Logger.log("Starting reconnect", type: logType)
        handleClientEvent(.reconnect, data: [reason])

        _tryReconnect()
    }

    private func _tryReconnect() {
        guard reconnects && reconnecting && status != .disconnected else { return }

        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts {
            return didDisconnect(reason: "Reconnect Failed")
        }

        DefaultSocketLogger.Logger.log("Trying to reconnect", type: logType)
        handleClientEvent(.reconnectAttempt, data: [(reconnectAttempts - currentReconnectAttempt)])

        currentReconnectAttempt += 1
        connect()

        handleQueue.asyncAfter(deadline: DispatchTime.now() + Double(reconnectWait), execute: _tryReconnect)
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
        _emit([event] + data)
    }
}
