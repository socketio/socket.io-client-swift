//
// Created by Erik Little on 10/14/17.
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

///
/// A manager for a socket.io connection.
///
/// A `SocketManager` is responsible for multiplexing multiple namespaces through a single `SocketEngineSpec`.
///
/// Example:
///
/// ```swift
/// let manager = SocketManager(socketURL: URL(string:"http://localhost:8080/")!)
/// let defaultNamespaceSocket = manager.defaultSocket
/// let swiftSocket = manager.socket(forNamespace: "/swift")
///
/// // defaultNamespaceSocket and swiftSocket both share a single connection to the server
/// ```
///
/// Sockets created through the manager are retained by the manager. So at the very least, a single strong reference
/// to the manager must be maintained to keep sockets alive.
///
/// To disconnect a socket and remove it from the manager, either call `SocketIOClient.disconnect()` on the socket,
/// or call one of the `disconnectSocket` methods on this class.
///
/// **NOTE**: The manager is not thread/queue safe, all interaction with the manager should be done on the `handleQueue`
///
open class SocketManager : NSObject, SocketManagerSpec, SocketParsable, SocketDataBufferable, ConfigSettable {
    private static let logType = "SocketManager"

    // MARK: Properties

    /// The socket associated with the default namespace ("/").
    public var defaultSocket: SocketIOClient {
        return socket(forNamespace: "/")
    }

    /// The URL of the socket.io server.
    ///
    /// If changed after calling `init`, `forceNew` must be set to `true`, or it will only connect to the url set in the
    /// init.
    public let socketURL: URL

    /// The configuration for this client.
    ///
    /// **Some configs will not take affect until after a reconnect if set after calling a connect method**.
    public var config: SocketIOClientConfiguration {
        get {
            return _config
        }

        set {
            if status.active {
                DefaultSocketLogger.Logger.log("Setting configs on active manager. Some configs may not be applied until reconnect",
                                               type: SocketManager.logType)
            }

            setConfigs(newValue)
        }
    }

    /// The engine for this manager.
    public var engine: SocketEngineSpec?

    /// If `true` then every time `connect` is called, a new engine will be created.
    public var forceNew = false

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    ///
    /// **This should be a serial queue! Concurrent queues are not supported and might cause crashes and races**.
    public var handleQueue = DispatchQueue.main

    /// The sockets in this manager indexed by namespace.
    public var nsps = [String: SocketIOClient]()

    /// If `true`, this client will try and reconnect on any disconnects.
    public var reconnects = true

    /// The number of seconds to wait before attempting to reconnect.
    public var reconnectWait = 10

    /// The status of this manager.
    public private(set) var status: SocketIOStatus = .notConnected {
        didSet {
            switch status {
            case .connected:
                reconnecting = false
                currentReconnectAttempt = 0
            default:
                break
            }
        }
    }

    /// A list of packets that are waiting for binary data.
    ///
    /// The way that socket.io works all data should be sent directly after each packet.
    /// So this should ideally be an array of one packet waiting for data.
    ///
    /// **This should not be modified directly.**
    public var waitingPackets = [SocketPacket]()

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

        super.init()

        setConfigs(_config)
    }

    /// Not so type safe way to create a SocketIOClient, meant for Objective-C compatiblity.
    /// If using Swift it's recommended to use `init(socketURL: NSURL, options: Set<SocketIOClientOption>)`
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    @objc
    public convenience init(socketURL: URL, config: [String: Any]?) {
        self.init(socketURL: socketURL, config: config?.toSocketConfiguration() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Manager is being released", type: SocketManager.logType)

        engine?.disconnect(reason: "Manager Deinit")
    }

    // MARK: Methods

    private func addEngine() {
        DefaultSocketLogger.Logger.log("Adding engine", type: SocketManager.logType)

        engine?.engineQueue.sync {
            self.engine?.client = nil

            // Close old engine so it will not leak because of URLSession if in polling mode
            self.engine?.disconnect(reason: "Adding new engine")
        }

        engine = SocketEngine(client: self, url: socketURL, config: config)
    }

    /// Connects the underlying transport and the default namespace socket.
    ///
    /// Override if you wish to attach a custom `SocketEngineSpec`.
    open func connect() {
        guard !status.active else {
            DefaultSocketLogger.Logger.log("Tried connecting an already active socket", type: SocketManager.logType)

            return
        }

        if engine == nil || forceNew {
            addEngine()
        }

        status = .connecting

        engine?.connect()
    }

    /// Connects a socket through this manager's engine.
    ///
    /// - parameter socket: The socket who we should connect through this manager.
    open func connectSocket(_ socket: SocketIOClient) {
        guard status == .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting socket when engine isn't open. Connecting",
                                           type: SocketManager.logType)

            connect()
            return
        }

        engine?.send("0\(socket.nsp),", withData: [])
    }

    /// Called when the manager has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        forAll {socket in
            socket.didDisconnect(reason: reason)
        }
    }

    /// Disconnects the manager and all associated sockets.
    open func disconnect() {
        DefaultSocketLogger.Logger.log("Manager closing", type: SocketManager.logType)

        status = .disconnected

        engine?.disconnect(reason: "Disconnect")
    }

    /// Disconnects the given socket.
    ///
    /// This will remove the socket for the manager's control, and make the socket instance useless and ready for
    /// releasing.
    ///
    /// - parameter socket: The socket to disconnect.
    open func disconnectSocket(_ socket: SocketIOClient) {
        engine?.send("1\(socket.nsp),", withData: [])

        socket.didDisconnect(reason: "Namespace leave")
    }

    /// Disconnects the socket associated with `forNamespace`.
    ///
    /// This will remove the socket for the manager's control, and make the socket instance useless and ready for
    /// releasing.
    ///
    /// - parameter nsp: The namespace to disconnect from.
    open func disconnectSocket(forNamespace nsp: String) {
        guard let socket = nsps.removeValue(forKey: nsp) else {
            DefaultSocketLogger.Logger.log("Could not find socket for \(nsp) to disconnect",
                                           type: SocketManager.logType)

            return
        }

        disconnectSocket(socket)
    }

    /// Sends a client event to all sockets in `nsps`
    ///
    /// - parameter clientEvent: The event to emit.
    open func emitAll(clientEvent event: SocketClientEvent, data: [Any]) {
        forAll {socket in
            socket.handleClientEvent(event, data: data)
        }
    }

    /// Sends an event to the server on all namespaces in this manager.
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The data to send with this event.
    open func emitAll(_ event: String, _ items: SocketData...) {
        guard let emitData = try? items.map({ try $0.socketRepresentation() }) else {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: SocketManager.logType)

            return
        }

        emitAll(event, withItems: emitData)
    }

    /// Sends an event to the server on all namespaces in this manager.
    ///
    /// Same as `emitAll(_:_:)`, but meant for Objective-C.
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The data to send with this event.
    open func emitAll(_ event: String, withItems items: [Any]) {
        forAll {socket in
            socket.emit(event, with: items)
        }
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
        DefaultSocketLogger.Logger.error("\(reason)", type: SocketManager.logType)

        emitAll(clientEvent: .error, data: [reason])
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
        DefaultSocketLogger.Logger.log("Engine opened \(reason)", type: SocketManager.logType)

        status = .connected
        nsps["/"]?.didConnect(toNamespace: "/")

        for (nsp, socket) in nsps where nsp != "/" && socket.status == .connecting {
            connectSocket(socket)
        }
    }

    /// Called when the engine receives a pong message.
    open func engineDidReceivePong() {
        handleQueue.async {
            self._engineDidReceivePong()
        }
    }

    private func _engineDidReceivePong() {
        emitAll(clientEvent: .pong, data: [])
    }

    /// Called when the sends a ping to the server.
    open func engineDidSendPing() {
        handleQueue.async {
            self._engineDidSendPing()
        }
    }

    private func _engineDidSendPing() {
        emitAll(clientEvent: .ping, data: [])
    }

    private func forAll(do: (SocketIOClient) throws -> ()) rethrows {
        for (_, socket) in nsps {
            try `do`(socket)
        }
    }

    /// Called when the engine has a message that must be parsed.
    ///
    /// - parameter msg: The message that needs parsing.
    open func parseEngineMessage(_ msg: String) {
        handleQueue.async {
            self._parseEngineMessage(msg)
        }
    }

    private func _parseEngineMessage(_ msg: String) {
        guard let packet = parseSocketMessage(msg) else { return }
        guard !packet.type.isBinary else {
            waitingPackets.append(packet)

            return
        }

        nsps[packet.nsp]?.handlePacket(packet)
    }

    /// Called when the engine receives binary data.
    ///
    /// - parameter data: The data the engine received.
    open func parseEngineBinaryData(_ data: Data) {
        handleQueue.async {
            self._parseEngineBinaryData(data)
        }
    }

    private func _parseEngineBinaryData(_ data: Data) {
        guard let packet = parseBinaryData(data) else { return }

        nsps[packet.nsp]?.handlePacket(packet)
    }

    /// Tries to reconnect to the server.
    ///
    /// This will cause a `SocketClientEvent.reconnect` event to be emitted, as well as
    /// `SocketClientEvent.reconnectAttempt` events.
    open func reconnect() {
        guard !reconnecting else { return }

        engine?.disconnect(reason: "manual reconnect")
    }

    /// Removes the socket from the manager's control. One of the disconnect methods should be called before calling this
    /// method.
    ///
    /// After calling this method the socket should no longer be considered usable.
    ///
    /// - parameter socket: The socket to remove.
    /// - returns: The socket removed, if it was owned by the manager.
    @discardableResult
    open func removeSocket(_ socket: SocketIOClient) -> SocketIOClient? {
        return nsps.removeValue(forKey: socket.nsp)
    }

    private func tryReconnect(reason: String) {
        guard reconnecting else { return }

        DefaultSocketLogger.Logger.log("Starting reconnect", type: SocketManager.logType)

        // Set status to connecting and emit reconnect for all sockets
        forAll {socket in
            guard socket.status == .connected else { return }

            socket.setReconnecting(reason: reason)
        }

        _tryReconnect()
    }

    private func _tryReconnect() {
        guard reconnects && reconnecting && status != .disconnected else { return }

        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts {
            return didDisconnect(reason: "Reconnect Failed")
        }

        DefaultSocketLogger.Logger.log("Trying to reconnect", type: SocketManager.logType)
        emitAll(clientEvent: .reconnectAttempt, data: [(reconnectAttempts - currentReconnectAttempt)])

        currentReconnectAttempt += 1
        connect()

        handleQueue.asyncAfter(deadline: DispatchTime.now() + Double(reconnectWait), execute: _tryReconnect)
    }

    /// Sets manager specific configs.
    ///
    /// parameter config: The configs that should be set.
    open func setConfigs(_ config: SocketIOClientConfiguration) {
        for option in config {
            switch option {
            case let .forceNew(new):
                self.forceNew = new
            case let .handleQueue(queue):
                self.handleQueue = queue
            case let .reconnects(reconnects):
                self.reconnects = reconnects
            case let .reconnectAttempts(attempts):
                self.reconnectAttempts = attempts
            case let .reconnectWait(wait):
                reconnectWait = abs(wait)
            case let .log(log):
                DefaultSocketLogger.Logger.log = log
            case let .logger(logger):
                DefaultSocketLogger.Logger = logger
            default:
                continue
            }
        }

        _config = config
        _config.insert(.path("/socket.io/"), replacing: false)

        // If `ConfigSettable` & `SocketEngineSpec`, update its configs.
        if var settableEngine = engine as? ConfigSettable & SocketEngineSpec {
            settableEngine.engineQueue.sync {
                settableEngine.setConfigs(self._config)
            }

            engine = settableEngine
        }
    }

    /// Returns a `SocketIOClient` for the given namespace. This socket shares a transport with the manager.
    ///
    /// Calling multiple times returns the same socket.
    ///
    /// Sockets created from this method are retained by the manager.
    /// Call one of the `disconnectSocket` methods on this class to remove the socket from manager control.
    /// Or call `SocketIOClient.disconnect()` on the client.
    ///
    /// - parameter nsp: The namespace for the socket.
    /// - returns: A `SocketIOClient` for the given namespace.
    open func socket(forNamespace nsp: String) -> SocketIOClient {
        assert(nsp.hasPrefix("/"), "forNamespace must have a leading /")

        if let socket = nsps[nsp] {
            return socket
        }

        let client = SocketIOClient(manager: self, nsp: nsp)

        nsps[nsp] = client

        return client
    }

    // Test properties

    func setTestStatus(_ status: SocketIOStatus) {
        self.status = status
    }
}
