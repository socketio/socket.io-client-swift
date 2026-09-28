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
open class SocketManager: NSObject, SocketManagerSpec, SocketParsable, SocketDataBufferable, ConfigSettable {
    private static let logType = "SocketManager"

    // MARK: Properties

    /// The socket for the URL path namespace, or "/" when the URL has no path.
    /// Use `socket(forNamespace: "/")` to explicitly select the root namespace.
    public var defaultSocket: SocketIOClient {
        let path = URLComponents(url: socketURL, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? ""
        return socket(forNamespace: path.isEmpty ? "/" : path)
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

    /// The default ack timeout in seconds for `emit(_:_:ack:)` / `emit(_:with:ack:)`.
    /// `nil` (the default) means no default timeout — the ack callback is a plain
    /// ack that is never called with an error. Matches JS `ackTimeout: undefined`
    /// in `socket.io-client/lib/socket.ts`.
    public var ackTimeout: Double? = nil

    /// How many times an emit is re-sent when the server does not acknowledge it
    /// in time. `0` (the default) disables retries. Matches JS `retries: 0`
    /// (falsy → no retry queue) in `socket.io-client/lib/socket.ts`.
    public var retries = 0

    /// Whether the manager should automatically call `connect()` at the end of `init`.
    /// Default `false`. See `SocketIOClientOption.autoConnect` for full semantics.
    /// **Note:** when `true`, engine I/O begins before `init` returns. Attach
    /// listeners on `defaultSocket` via the configuration's `handleQueue` (which
    /// must process events asynchronously after `init`) — events emitted on
    /// `handleQueue` will fire after the caller has had a chance to attach
    /// listeners. JS-aligned (`socket.io-client/lib/manager.ts` constructor
    /// calls `this.open()` synchronously when `autoConnect: true`).
    public var autoConnect: Bool = false

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    ///
    /// **This should be a serial queue! Concurrent queues are not supported and might cause crashes and races**.
    private let handleQueueKey = DispatchSpecificKey<UInt8>()
    public var handleQueue = DispatchQueue.main {
        didSet {
            oldValue.setSpecific(key: handleQueueKey, value: nil)
            handleQueue.setSpecific(key: handleQueueKey, value: 1)
        }
    }

    /// Registration is synchronous when the caller obeys the handleQueue contract.
    /// This preserves emit(); disconnect() ordering without synchronous cross-queue hops.
    internal var isOnHandleQueue: Bool {
        DispatchQueue.getSpecific(key: handleQueueKey) != nil
            || (Thread.isMainThread && handleQueue === DispatchQueue.main)
    }

    /// The sockets in this manager indexed by namespace.
    public var nsps = [String: SocketIOClient]()

    // JS manager listeners run in subscription order, not dictionary order.
    // Namespace construction alone does not subscribe when autoConnect is off.
    private var subscriptionOrder = [String]()

    func updateSubscriptionOrder(for socket: SocketIOClient, active: Bool) {
        if let current = nsps[socket.nsp], current !== socket { return }
        subscriptionOrder.removeAll { $0 == socket.nsp }
        if active { subscriptionOrder.append(socket.nsp) }
    }

    private var orderedSockets: [SocketIOClient] {
        let subscribed = subscriptionOrder.compactMap { nsps[$0] }
        let names = Set(subscriptionOrder)
        return subscribed + nsps.values.filter { !names.contains($0.nsp) }
    }

    /// If `true`, this client will try and reconnect on any disconnects.
    public var reconnects = true

    /// The base delay in seconds before the first reconnect attempt; each further
    /// attempt doubles it. JS `reconnectionDelay` (1000 ms).
    public var reconnectWait = 1

    /// The maximum delay in seconds between reconnect attempts. JS
    /// `reconnectionDelayMax` (5000 ms).
    public var reconnectWaitMax = 5

    /// Seconds the engine.io handshake may take before the attempt is failed with `.connectError("timeout")`
    /// and the engine is closed; `.infinity` disables; `0` fails on the next queue turn (JS `timeout: 0`).
    public var connectTimeout: Double = 20

    /// The randomization factor for calculating reconnect jitter.
    public var randomizationFactor = 0.5

    /// The status of this manager.
    public private(set) var status: SocketIOStatus = .notConnected {
        didSet {
            switch status {
            case .connected:
                // JS `Manager.onreconnect()`: `backoff.reset(); _reconnecting = false`.
                cancelScheduledReconnect()
                reconnecting = false
                currentReconnectAttempt = 0
            default:
                break
            }
        }
    }


    /// Shared incoming packet and reconstruction limits. Set via `.parserOptions` before connecting.
    public private(set) var parserOptions = SocketParserOptions()
    private var parserFailed = false

    /// Pipeline-wide buffer/queue limits. Set via `.bufferLimits` before
    /// connecting; unlimited by default, which is the JavaScript behaviour.
    public private(set) var bufferLimits = SocketBufferLimits.unlimited

    /// Packets handed to `handleQueue` that have not finished parsing.
    ///
    /// The permit is taken on the engine queue before the dispatch and released
    /// on `handleQueue` after `_parseEngineMessage`/`_parseEngineBinaryData`
    /// returns, so a consumer that cannot keep up applies backpressure to the
    /// transport instead of letting the queue grow without bound. Written from
    /// both queues, hence the lock.
    private var unparsedPackets = 0
    private var unparsedBytes = 0
    private var receiveBacklogOverflowed = false
    private let receiveBacklogLock = NSLock()

    /// Fires when a half-reconstructed binary packet outlives
    /// `bufferLimits.binaryReconstructionTimeout`.
    private var binaryReconstructionTimer: DispatchWorkItem?

    /// A list of packets that are waiting for binary data.
    ///
    /// The way that socket.io works all data should be sent directly after each packet.
    /// So this should ideally be an array of one packet waiting for data.
    ///
    /// **This should not be modified directly.**
    public var waitingPackets = [SocketPacket]()

    private(set) var reconnectAttempts = -1

    private var _config: SocketIOClientConfiguration
    internal var currentReconnectAttempt = 0
    private var pendingConnectPayloads = [String: [String: Any]]()
    private var reconnecting = false
    /// The pending backoff timer of the reconnect loop (JS `Manager.reconnect()`'s
    /// `setTimeoutFn`). Cancelled by `disconnect()` and by a successful open.
    private var reconnectTimer: DispatchWorkItem?
    private var connectTimeoutTimer: DispatchWorkItem?
    private var connectAttemptTimedOut = false

    // MARK: Initializers

    /// Type safe way to create a new SocketIOClient. `opts` can be omitted.
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    public init(socketURL: URL, config: SocketIOClientConfiguration = []) {
        self._config = config
        self.socketURL = socketURL

        super.init()

        setConfigs(_config)
        handleQueue.setSpecific(key: handleQueueKey, value: 1)

        if autoConnect {
            _ = defaultSocket // socket(forNamespace:) subscribes and opens the engine.
        }
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

    /// :nodoc:
    deinit {
        handleQueue.setSpecific(key: handleQueueKey, value: nil)
        DefaultSocketLogger.Logger.log("Manager is being released", type: SocketManager.logType)

        engine?.disconnect(reason: "io client disconnect")
    }

    // MARK: Methods

    private func addEngine() {
        DefaultSocketLogger.Logger.log("Adding engine", type: SocketManager.logType)

        engine?.engineQueue.sync {
            self.engine?.client = nil

            // Close old engine so it will not leak because of URLSession if in polling mode
            self.engine?.disconnect(reason: "io client disconnect")
        }

        engine = SocketEngine(client: self, url: socketURL, config: config)
    }

    /// Connects the underlying transport and the default namespace socket.
    ///
    /// Override if you wish to attach a custom `SocketEngineSpec`.
    open func connect() {
        if status == .connected || (status == .connecting && currentReconnectAttempt == 0) {
            DefaultSocketLogger.Logger.log("Tried connecting an already active socket", type: SocketManager.logType)
            return
        }

        // A native parser failure retires the complete transport engine. Custom
        // SocketEngineSpec implementations retain control of their own lifecycle;
        // silently replacing one with the built-in engine would discard it.
        if engine == nil || forceNew || (parserFailed && engine is SocketEngine) {
            addEngine()
        }

        status = .connecting
        parserFailed = false
        waitingPackets.removeAll()
        cancelBinaryReconstructionTimer()
        resetReceiveBacklog()
        guard parserOptions.isValid else {
            status = .disconnected
            emitAll(clientEvent: .connectError, data: ["Invalid parser limits"])
            return
        }
        guard bufferLimits.isValid else {
            status = .disconnected
            emitAll(clientEvent: .connectError, data: ["Invalid buffer limits"])
            return
        }
        engine?.connect()

        cancelConnectTimeout()
        connectAttemptTimedOut = false
        if connectTimeout.isFinite {
            let timer = DispatchWorkItem { [weak self] in
                self?.connectDidTimeOut()
            }
            connectTimeoutTimer = timer
            handleQueue.socketAsyncAfter(deadline: .now() + connectTimeout, execute: timer)
        }
    }

    /// Fires when the engine.io handshake takes longer than `connectTimeout`.
    /// Emits `.connectError("timeout")` to every socket, then closes the
    /// engine; the resulting close enters the reconnect loop when reconnection
    /// is enabled. JS-aligned with the timeout callback in `Manager.open()`.
    private func connectDidTimeOut() {
        connectTimeoutTimer = nil

        guard status != .connected && status != .disconnected else { return }

        connectAttemptTimedOut = true

        DefaultSocketLogger.Logger.log("Connect attempt timed out after \(connectTimeout)s", type: SocketManager.logType)

        emitAll(clientEvent: .connectError, data: ["timeout"])

        engine?.disconnect(reason: "timeout")
    }

    private func cancelConnectTimeout() {
        connectTimeoutTimer?.cancel()
        connectTimeoutTimer = nil
    }

    /// Connects a socket through this manager's engine.
    ///
    /// - parameter socket: The socket who we should connect through this manager.
    /// - parameter withPayload: Optional payload to send on connect
    open func connectSocket(_ socket: SocketIOClient, withPayload payload: [String: Any]? = nil) {
        guard status == .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting socket when engine isn't open. Connecting",
                                           type: SocketManager.logType)

            if let payload = payload {
                pendingConnectPayloads[socket.nsp] = payload
            } else {
                pendingConnectPayloads.removeValue(forKey: socket.nsp)
            }
            connect()
            return
        }

        // Provider gating — resolve the payload (provider-or-explicit), then write
        // the raw CONNECT packet. The completion calls `writeConnectPacket`
        // directly (NOT this method) to avoid recursing through
        // `resolveConnectPayload` a second time.
        socket.resolveConnectPayload(explicit: payload) { [weak self, weak socket] resolved in
            guard let self = self, let socket = socket else { return }
            self.writeConnectPacket(socket, withPayload: resolved)
        }
    }

    /// Raw CONNECT-packet writer. Does NOT consult any auth provider — callers
    /// MUST have already resolved the payload via
    /// `SocketIOClient.resolveConnectPayload(explicit:completion:)`. Called from
    /// `connectSocket` (after resolution) and `_engineDidOpen` (after
    /// resolution). Must always run on `handleQueue`.
    private func writeConnectPacket(_ socket: SocketIOClient, withPayload payload: [String: Any]?) {
        var payloadStr = ""
        let effective = effectiveConnectPayload(for: socket, explicitPayload: payload)

        if let effective = effective {
            guard JSONSerialization.isValidJSONObject(effective) else {
                let message = "connect payload serialization failed: invalid JSON object"
                DefaultSocketLogger.Logger.error(
                    "Failed to serialize CONNECT payload: invalid JSON object",
                    type: SocketManager.logType
                )
                socket.handleClientEvent(.error, data: [message])
                socket.abortPendingConnect()
                return
            }

            do {
                // Sorted for the same reason `SocketPacket` sorts: a Swift
                // Dictionary has no insertion order, so a reproducible CONNECT
                // frame is the only alternative to an arbitrary one.
                let payloadData = try JSONSerialization.data(withJSONObject: effective,
                                                             options: [.fragmentsAllowed, .sortedKeys])
                if let jsonString = String(data: payloadData, encoding: .utf8) {
                    payloadStr = jsonString
                }
            } catch {
                DefaultSocketLogger.Logger.error(
                    "Failed to serialize CONNECT payload: \(error)",
                    type: SocketManager.logType
                )
                socket.handleClientEvent(
                    .error,
                    data: ["connect payload serialization failed: \(error.localizedDescription)"]
                )
                socket.abortPendingConnect()
                return
            }
        }

        engine?.send("0\(socket.nsp),\(payloadStr)", withData: [])
    }

    private func effectiveConnectPayload(for socket: SocketIOClient,
                                         explicitPayload payload: [String: Any]?) -> [String: Any]? {
        guard let payload = payload else { return socket.currentConnectPayload() }
        guard let pid = socket._pid else { return payload }

        var merged: [String: Any] = ["pid": pid]
        if let offset = socket._lastOffset {
            merged["offset"] = offset
        }

        if payload["pid"] != nil || payload["offset"] != nil {
            DefaultSocketLogger.Logger.log(
                "connect payload contains reserved key 'pid' or 'offset'; user value takes precedence",
                type: SocketManager.logType
            )
        }

        for (key, value) in payload {
            merged[key] = value
        }

        return merged
    }

    /// Called when the manager has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        forAll {socket in
            // JS `Manager.onclose` only reaches sockets that subscribed to the
            // manager, i.e. that called `connect()`. A socket that never did has
            // nothing to be disconnected from.
            guard socket.status != .notConnected else { return }

            socket.didDisconnect(reason: reason)
        }
    }

    /// Disconnects the manager and all associated sockets.
    open func disconnect() {
        DefaultSocketLogger.Logger.log("Manager closing", type: SocketManager.logType)

        cancelConnectTimeout()
        // JS `Manager._close()`: `skipReconnect = true; _reconnecting = false`.
        cancelScheduledReconnect()
        reconnecting = false
        currentReconnectAttempt = 0

        status = .disconnected

        engine?.disconnect(reason: "io client disconnect")
    }

    /// Disconnects the given socket.
    ///
    /// This will remove the socket for the manager's control, and make the socket instance useless and ready for
    /// releasing.
    ///
    /// - parameter socket: The socket to disconnect.
    open func disconnectSocket(_ socket: SocketIOClient) {
        disconnectSocket(socket, removeFromManager: true)
    }

    /// Client namespace cleanup preserves the JS-compatible cache. The active flag
    /// distinguishes explicit client disconnect from a reconnectable namespace timeout.
    internal func disconnectSocket(_ socket: SocketIOClient, removeFromManager: Bool) {
        if removeFromManager { subscriptionOrder.removeAll { $0 == socket.nsp } }
        if removeFromManager, nsps[socket.nsp] === socket {
            nsps.removeValue(forKey: socket.nsp)
        }
        pendingConnectPayloads.removeValue(forKey: socket.nsp)
        engine?.send("1\(socket.nsp),", withData: [])

        socket.didDisconnect(reason: "io client disconnect")

        // JS `Manager._destroy(socket)`: once no socket of this manager is
        // `active` any more, the manager closes (`_close()`), which also stops a
        // running reconnect loop. Without this, a loop kept running after the
        // last socket left (connection.ts "should stop reconnecting when force
        // closed").
        guard !nsps.values.contains(where: { $0.active }) else { return }

        DefaultSocketLogger.Logger.log("No active socket left; closing the manager", type: SocketManager.logType)
        disconnect()
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

    /// Delivers a manager-level JS event (`reconnect_attempt`, `reconnect_error`,
    /// `reconnect_failed`, `reconnect`) to the sockets subscribed to this manager.
    /// Swift has no manager event bus; JS sockets subscribe in `connect()` and
    /// unsubscribe in `disconnect()`, which is what `active` tracks.
    private func emitManagerEvent(_ event: SocketClientEvent, data: [Any]) {
        forAll {socket in
            guard socket.active else { return }

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

        forAll {socket in
            socket.emit([event] + emitData)
        }
    }

    /// Called when the engine closes.
    ///
    /// - parameter reason: The reason that the engine closed.
    open func engineDidClose(reason: String) {
        handleQueue.socketAsync {
            self._engineDidClose(reason: reason)
        }
    }

    open func engineDidClose(reason: String, error: SocketTransportError) {
        handleQueue.socketAsync { self._engineDidClose(reason: reason, error: error) }
    }

    private func _engineDidClose(reason: String, error: SocketTransportError? = nil) {
        cancelConnectTimeout()

        waitingPackets.removeAll()
        // Gate R1: the closed session retains nothing. The backlog permits and
        // the reconstruction deadline belong to the transport that just died.
        cancelBinaryReconstructionTimer()
        resetReceiveBacklog()

        if status != .disconnected {
            status = .notConnected
        }

        if status == .disconnected || !reconnects {
            if let error = error {
                forAll { socket in
                    guard socket.status != .notConnected else { return }
                    socket.handleTransportClose(reason: reason, error: error, reconnecting: false)
                }
            } else {
                didDisconnect(reason: reason)
            }
        } else if !reconnecting {
            reconnecting = true
            tryReconnect(reason: reason, error: error)
        } else if reconnectTimer != nil {
            // JS `reconnect()` returns early while `_reconnecting`: a close that
            // arrives during the backoff wait is not an attempt failure and
            // neither reschedules nor reports `reconnect_error`.
            DefaultSocketLogger.Logger.log("Ignoring close while a reconnect attempt is pending", type: SocketManager.logType)
        } else {
            // A close that arrives while an attempt is in flight is that
            // attempt failing. JS `Manager.reconnect()` passes it to the
            // `open(fn)` callback, which schedules the next attempt (with a
            // longer backoff) and then emits `reconnect_error`.
            scheduleReconnectAttempt()
            emitManagerEvent(.reconnectError, data: [reason])
        }
    }

    /// Called when the engine errors.
    ///
    /// - parameter reason: The reason the engine errored.
    open func engineDidError(reason: String) {
        handleQueue.socketAsync {
            self._engineDidError(reason: reason)
        }
    }

    open func engineDidError(reason: String, error: SocketTransportError) {
        handleQueue.socketAsync { self._engineDidError(reason: reason, error: error) }
    }

    private func _engineDidError(reason: String, error: SocketTransportError? = nil) {
        cancelConnectTimeout()

        DefaultSocketLogger.Logger.error("\(reason)", type: SocketManager.logType)

        // JS `socket.ts onerror`: an engine error while not connected is a
        // `connect_error`; an established connection reports `.error` instead
        // (a transport drop under a live connection is a runtime error). Only
        // sockets subscribed to the manager hear it — JS `Socket.subEvents()`
        // runs in `connect()` and a refused or disconnected socket has
        // destroyed its subscriptions, so it must not be told about the engine.
        forAll { socket in
            guard socket.active else { return }

            if socket.status == .connected {
                socket.handleClientEvent(.error, data: error.map { [reason, $0] } ?? [reason])
            } else {
                socket.handleClientEvent(.connectError, data: error.map { [reason, $0] } ?? [reason])
            }
        }
    }

    /// Called when the engine opens.
    ///
    /// - parameter reason: The reason the engine opened.
    open func engineDidOpen(reason: String) {
        handleQueue.socketAsync {
            self._engineDidOpen(reason: reason)
        }
    }

    private func _engineDidOpen(reason: String) {
        cancelConnectTimeout()

        // A handshake that completes after the timer fired is ignored, the way
        // JS destroys its "open" listener before closing the engine; the engine
        // we already asked to close will report its close and the loop goes on.
        if connectAttemptTimedOut {
            return
        }

        DefaultSocketLogger.Logger.log("Engine opened \(reason)", type: SocketManager.logType)

        // JS `Manager.onreconnect()`: the attempt count is read before the
        // backoff is reset. Setting `status` to `.connected` below resets
        // `currentReconnectAttempt`, so the number is captured first.
        let succeededAttempt = reconnecting ? currentReconnectAttempt : nil

        status = .connected

        // JS emits `reconnect` with the 1-based attempt that succeeded, before
        // the namespaces are re-joined and therefore always before the sockets'
        // `connect`.
        if let attempt = succeededAttempt {
            emitManagerEvent(.reconnect, data: [attempt])
        }


        // `active` is what decides whether a socket still wants this namespace.
        // A socket the server refused (CONNECT_ERROR) or that the user
        // disconnected clears it, and must not be rejoined on the next engine
        // open — JS `destroy()`s the socket in both cases, so the manager stops
        // driving it until an explicit `connect()`. Without this the client
        // re-CONNECTs a namespace the server already rejected, on every single
        // reconnect.
        for socket in orderedSockets where socket.status == .connecting && socket.active {


            // Resolve the auth payload, then call `writeConnectPacket` directly
            // (NOT `connectSocket`, which would re-enter `resolveConnectPayload`
            // and double-invoke the provider).
            let pending = consumePendingConnectPayload(for: socket) ?? socket.connectPayload
            socket.resolveConnectPayload(explicit: pending) { [weak self, weak socket] resolved in
                guard let self = self, let socket = socket else { return }
                self.writeConnectPacket(socket, withPayload: resolved)
            }
        }
    }

    /// Called when the engine receives a ping message.
    open func engineDidReceivePing() {
        handleQueue.socketAsync {
            self._engineDidReceivePing()
        }
    }

    private func _engineDidReceivePing() {
        emitAll(clientEvent: .ping, data: [])
    }

    /// Called when the engine receives a pong message.
    open func engineDidReceivePong() {
        handleQueue.socketAsync {
            self._engineDidReceivePong()
        }
    }

    private func _engineDidReceivePong() {
        emitAll(clientEvent: .pong, data: [])
    }

    /// Called when the sends a pong to the server.
    open func engineDidSendPong() {
        handleQueue.socketAsync {
            self._engineDidSendPong()
        }
    }

    private func _engineDidSendPong() {
        emitAll(clientEvent: .pong, data: [])
    }

    private func forAll(do: (SocketIOClient) throws -> ()) rethrows {
        for socket in orderedSockets {
            try `do`(socket)
        }
    }

    /// Called when when upgrading the http connection to a websocket connection.
    ///
    /// - parameter headers: The http headers.
    open func engineDidWebsocketUpgrade(headers: [String: String]) {
        handleQueue.socketAsync {
            self._engineDidWebsocketUpgrade(headers: headers)
        }
    }
     private func _engineDidWebsocketUpgrade(headers: [String: String]) {
        emitAll(clientEvent: .websocketUpgrade, data: [headers])
    }

    /// Called when the engine has a message that must be parsed.
    ///
    /// - parameter msg: The message that needs parsing.
    open func parseEngineMessage(_ msg: String) {
        let size = msg.utf8.count
        guard reserveReceivePermit(bytes: size) else { return }

        handleQueue.socketAsync {
            defer { self.releaseReceivePermit(bytes: size) }

            self._parseEngineMessage(msg)
        }
    }

    private func _parseEngineMessage(_ msg: String) {
        guard !parserFailed, status != .disconnected else { return }
        guard waitingPackets.isEmpty else {
            engineDidReceiveUndecodableData("Text received before binary reconstruction completed")
            return
        }
        guard let packet = parseSocketMessage(msg) else {
            // Engine.IO MESSAGE must carry a Socket.IO packet. Empty or invalid
            // data loses framing just like any other parser error.
            engineDidReceiveUndecodableData("Undecodable socket.io packet (\(msg.utf8.count) bytes)")

            return
        }
        guard !packet.type.isBinary else {
            waitingPackets.append(packet)
            startBinaryReconstructionTimerIfNeeded()

            return
        }

        nsps[packet.nsp]?.handlePacket(packet)
    }

    /// Called when the engine receives binary data.
    ///
    /// - parameter data: The data the engine received.
    open func parseEngineBinaryData(_ data: Data) {
        let size = data.count
        guard reserveReceivePermit(bytes: size) else { return }

        handleQueue.socketAsync {
            defer { self.releaseReceivePermit(bytes: size) }

            self._parseEngineBinaryData(data)
        }
    }

    private func _parseEngineBinaryData(_ data: Data) {
        guard !parserFailed, status != .disconnected else { return }
        guard let packet = parseBinaryData(data) else {
            // `parseBinaryData` returns nil both while a multi-attachment packet
            // is still incomplete (benign: more chunks are on the way) and when
            // binary arrives with no packet waiting for it (the stream is out of
            // step). Only the latter is fatal here.
            if waitingPackets.isEmpty {
                engineDidReceiveUndecodableData("Undecodable binary data (\(data.count) bytes) with no packet waiting for it")
            }

            return
        }

        cancelBinaryReconstructionTimer()
        nsps[packet.nsp]?.handlePacket(packet)
    }

    // MARK: Gate R1 — receive backpressure and reconstruction deadline

    /// Takes a permit for one packet the engine is about to hand to
    /// `handleQueue`. Runs on the engine queue. Returns `false` when the
    /// backlog is full, in which case the packet is not dispatched and the
    /// connection is closed — dispatching it anyway would be the unbounded
    /// growth this gate exists to prevent.
    private func reserveReceivePermit(bytes: Int) -> Bool {
        let limits = bufferLimits
        guard limits.boundsReceive else { return true }

        receiveBacklogLock.lock()
        if receiveBacklogOverflowed {
            receiveBacklogLock.unlock()

            return false
        }

        let packets = unparsedPackets + 1
        let total = unparsedBytes + bytes
        if packets > limits.maximumUnparsedPackets || total > limits.maximumUnparsedBytes {
            let measuringBytes = total > limits.maximumUnparsedBytes
            receiveBacklogOverflowed = true
            receiveBacklogLock.unlock()

            let error = SocketBufferLimitError(
                buffer: .receiveBacklog,
                limit: measuringBytes ? limits.maximumUnparsedBytes : limits.maximumUnparsedPackets,
                attempted: measuringBytes ? total : packets,
                measuringBytes: measuringBytes
            )
            DefaultSocketLogger.Logger.error(error.description, type: SocketManager.logType)
            // Closed straight from the engine queue: the consumer that cannot
            // keep up owns `handleQueue`, so a close dispatched there would sit
            // behind exactly the backlog it is meant to stop.
            engine?.disconnect(reason: "transport error")

            return false
        }

        unparsedPackets = packets
        unparsedBytes = total
        receiveBacklogLock.unlock()

        return true
    }

    /// Releases the permit after parsing has finished, not after the dispatch.
    private func releaseReceivePermit(bytes: Int) {
        guard bufferLimits.boundsReceive else { return }

        receiveBacklogLock.lock()
        unparsedPackets = max(0, unparsedPackets - 1)
        unparsedBytes = max(0, unparsedBytes - bytes)
        receiveBacklogLock.unlock()
    }

    private func resetReceiveBacklog() {
        receiveBacklogLock.lock()
        unparsedPackets = 0
        unparsedBytes = 0
        receiveBacklogOverflowed = false
        receiveBacklogLock.unlock()
    }

    /// Arms the deadline for a packet that is waiting for its attachments. JS
    /// waits forever; a peer that announces attachments and never sends them
    /// would otherwise pin the reconstruction buffer for the life of the
    /// session.
    private func startBinaryReconstructionTimerIfNeeded() {
        let timeout = bufferLimits.binaryReconstructionTimeout
        guard timeout.isFinite, binaryReconstructionTimer == nil else { return }

        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, !self.waitingPackets.isEmpty else { return }

            self.binaryReconstructionTimer = nil
            let error = SocketBufferLimitError(buffer: .binaryReconstruction,
                                               limit: Int(min(timeout * 1000, Double(Int.max))),
                                               attempted: Int(min(timeout * 1000, Double(Int.max))),
                                               measuringBytes: false)
            DefaultSocketLogger.Logger.error(
                "\(error.description) — a binary packet waited longer than \(timeout)s for its attachments",
                type: SocketManager.logType
            )
            // A partial packet is a decoder failure: JS `Decoder.destroy()`
            // drops it and the manager reports `parse error`. Nothing is
            // replayed from what did arrive.
            self.engineDidReceiveUndecodableData("Binary reconstruction deadline exceeded")
        }
        binaryReconstructionTimer = timer
        handleQueue.asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    private func cancelBinaryReconstructionTimer() {
        binaryReconstructionTimer?.cancel()
        binaryReconstructionTimer = nil
    }

    /// Closes the engine after undecodable data arrived, JS-aligned with
    /// `Manager.ondata`/`onclose("parse error")` in
    /// `socket.io-client/lib/manager.ts`: an undecodable packet means the
    /// stream is out of step, so the session cannot continue. Closing the
    /// engine is enough: `closeOutEngine` → `client?.engineDidClose(reason:)`
    /// → `_engineDidClose` tells the sockets and starts the reconnect loop
    /// when `reconnects` is on.
    private func engineDidReceiveUndecodableData(_ description: String) {
        guard status != .disconnected, !parserFailed else { return }
        parserFailed = true
        waitingPackets.removeAll()
        cancelBinaryReconstructionTimer()
        DefaultSocketLogger.Logger.error(description, type: SocketManager.logType)
        engine?.disconnect(reason: "parse error")
    }

    /// Tries to reconnect to the server.
    ///
    /// This closes the transport, so the sockets see `SocketClientEvent.disconnect`
    /// with the close reason, then a `SocketClientEvent.reconnectAttempt` per
    /// attempt and finally either `SocketClientEvent.reconnect` (success, with
    /// the attempt number) or `SocketClientEvent.reconnectFailed`.
    open func reconnect() {
        guard !reconnecting else { return }

        engine?.disconnect(reason: "transport close")
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
        pendingConnectPayloads.removeValue(forKey: socket.nsp)
        return nsps.removeValue(forKey: socket.nsp)
    }

    private func consumePendingConnectPayload(for socket: SocketIOClient) -> [String: Any]? {
        return pendingConnectPayloads.removeValue(forKey: socket.nsp)
    }

    private func tryReconnect(reason: String, error: SocketTransportError? = nil) {
        guard reconnecting else { return }

        DefaultSocketLogger.Logger.log("Starting reconnect", type: SocketManager.logType)

        // JS `Manager.onclose(reason)` tells every subscribed socket that the
        // connection dropped (`Socket.onclose` → `disconnect` with the real
        // reason) before `reconnect()` runs. Swift additionally parks the socket
        // in `.connecting`, which is what makes `_engineDidOpen` re-join it.
        forAll {socket in
            guard socket.status == .connected else { return }

            socket.handleTransportClose(reason: reason, error: error, reconnecting: true)
        }

        scheduleReconnectAttempt()
    }

    /// JS `Manager.reconnect()`: either the budget is exhausted (`reconnect_failed`)
    /// or the next attempt is scheduled after `backoff.duration()`. The attempt
    /// itself — `reconnect_attempt`, then `open()` — only runs when that timer
    /// fires, so a drop never triggers an immediate retry.
    private func scheduleReconnectAttempt() {
        guard reconnects && reconnecting && status != .disconnected else { return }

        if reconnectAttempts != -1 && currentReconnectAttempt >= reconnectAttempts {
            // JS `Manager.reconnect()` in socket.io-client/lib/manager.ts:
            // `backoff.reset(); emitReserved("reconnect_failed"); _reconnecting = false`.
            // The sockets already got their `disconnect` with the real reason
            // when the connection dropped, so there is no second one here.
            cancelScheduledReconnect()
            reconnecting = false
            currentReconnectAttempt = 0

            // Nothing will re-join these namespaces now; drop them out of the
            // `.connecting` parking state first, so a `.reconnectFailed`
            // handler that calls `connect()` is not undone by this loop. JS
            // keeps the socket subscribed (`active`) too, so an explicit
            // connect starts a fresh cycle.
            forAll {socket in
                guard socket.status == .connecting else { return }

                socket.abortPendingConnect()
            }

            emitManagerEvent(.reconnectFailed, data: [])

            return
        }

        // JS `backoff.duration()` computes the delay from the attempts made so
        // far and then increments `attempts`, which is the 1-based number the
        // upcoming `reconnect_attempt` carries.
        let interval = reconnectInterval(attempts: currentReconnectAttempt)
        currentReconnectAttempt += 1
        let attempt = currentReconnectAttempt

        DefaultSocketLogger.Logger.log("Scheduling reconnect attempt \(attempt) in \(interval)s",
                                       type: SocketManager.logType)

        cancelScheduledReconnect()
        let timer = DispatchWorkItem { [weak self] in
            self?.runReconnectAttempt(attempt)
        }
        reconnectTimer = timer
        handleQueue.socketAsyncAfter(deadline: .now() + interval, execute: timer)
    }

    /// The body of JS `Manager.reconnect()`'s timer: `reconnect_attempt`, then
    /// `open()`, each guarded by `skipReconnect` (here: a manager `disconnect()`).
    private func runReconnectAttempt(_ attempt: Int) {
        reconnectTimer = nil
        guard reconnects && reconnecting && status != .disconnected else { return }

        DefaultSocketLogger.Logger.log("Trying to reconnect (attempt \(attempt))", type: SocketManager.logType)

        // A manager-level event: every subscribed socket of this manager hears
        // it, whatever its connection state.
        emitManagerEvent(.reconnectAttempt, data: [attempt])

        // JS: "check again for the case socket closed in above events".
        guard reconnects && reconnecting && status != .disconnected else { return }
        // JS `open()` is a no-op while an open is already in flight.
        guard status != .connecting else { return }

        connect()
    }

    private func cancelScheduledReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    /// JS `backo2` `Backoff.duration()` as socket.io-client configures it:
    /// `min * factor^attempts`, jittered by up to `randomizationFactor` in either
    /// direction, capped at `max`. The factor is 2, like JS. Seconds instead of
    /// milliseconds; the jitter is not truncated so it stays meaningful at 1 s.
    func reconnectInterval(attempts: Int) -> Double {
        let base = Double(reconnectWait)
        let maximum = Double(reconnectWaitMax)
        let exponent = Double(min(max(attempts, 0), 60))
        var interval = base * pow(2, exponent)
        guard interval.isFinite else { return maximum }
        if randomizationFactor > 0 {
            let rand = Double.random(in: 0 ..< 1)
            let deviation = rand * randomizationFactor * interval
            interval = (Int(rand * 10) & 1) == 0 ? interval - deviation : interval + deviation
        }
        return min(interval, maximum)
    }

    /// Sets manager specific configs.
    ///
    /// parameter config: The configs that should be set.
    open func setConfigs(_ config: SocketIOClientConfiguration) {
        for option in config {
            switch option {
            case let .parserOptions(options):
                parserOptions = options
            case let .bufferLimits(limits):
                bufferLimits = limits
            case let .ackTimeout(value):
                ackTimeout = max(0, value)
            case let .retries(count):
                retries = max(0, count)
            case let .forceNew(new):
                forceNew = new
            case let .autoConnect(value):
                autoConnect = value
            case let .handleQueue(queue):
                handleQueue = queue
            case let .reconnects(reconnects):
                self.reconnects = reconnects
            case let .reconnectAttempts(attempts):
                reconnectAttempts = attempts
            case let .reconnectWait(wait):
                reconnectWait = abs(wait)
            case let .reconnectWaitMax(wait):
                reconnectWaitMax = abs(wait)
            case let .randomizationFactor(factor):
                randomizationFactor = factor
            case let .connectTimeout(value):
                connectTimeout = max(0, value)
            case let .log(log):
                DefaultSocketLogger.Logger.log = log
            case let .logger(logger):
                DefaultSocketLogger.Logger = logger
            case _:
                continue
            }
        }

        _config = config

        if socketURL.absoluteString.hasPrefix("https://") {
            _config.insert(.secure(true))
        }

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
            // JS-aligned with `Manager.socket()` in `socket.io-client/lib/manager.ts`.
            if autoConnect && !socket.active {
                socket.connect()
            }
            return socket
        }

        let client = SocketIOClient(manager: self, nsp: nsp)

        nsps[nsp] = client
        if autoConnect { client.connect() }

        return client
    }

    // Test properties

    func setTestStatus(_ status: SocketIOStatus) {
        self.status = status
    }

    /// Packets dispatched to `handleQueue` that have not finished parsing, and
    /// their accumulated bytes. Proves the permits are released again.
    var testReceiveBacklog: (packets: Int, bytes: Int) {
        receiveBacklogLock.lock()
        defer { receiveBacklogLock.unlock() }

        return (unparsedPackets, unparsedBytes)
    }

    var testHasBinaryReconstructionTimer: Bool { binaryReconstructionTimer != nil }
}
