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

/// Callback used by an auth provider to deliver its resolved payload (or `nil`)
/// back to the client for the upcoming CONNECT packet.
public typealias SocketAuthCallback = ([String: Any]?) -> Void

/// Auth provider type. Invoked on `manager.handleQueue` for every CONNECT
/// (initial + every reconnect). Mirrors the JS callback-form `auth(cb)`.
public typealias SocketAuthProvider = (@escaping SocketAuthCallback) -> Void

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
open class SocketIOClient: NSObject, SocketIOClientSpec {
    // MARK: Properties

    /// The namespace that this socket is currently connected to.
    ///
    /// **Must** start with a `/`.
    public let nsp: String

    /// A handler that will be called on any event.
    public private(set) var anyHandler: ((SocketAnyEvent) -> ())?

    /// Storage for the multi-listener `onAny` family. UUID-keyed because Swift
    /// closures lack identity. Mutators run inline when already on `handleQueue`.
    private var anyListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []

    /// Storage for the `onAnyOutgoing` family. UUID-keyed because closures lack
    /// identity. Mutators run inline when already on `handleQueue`.
    private var anyOutgoingListeners: [(id: UUID, handler: (SocketAnyEvent) -> ())] = []

    /// The array of handlers for this socket.
    public private(set) var handlers = [SocketEventHandler]()

    /// The manager for this socket.
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
    public private(set) lazy var rawEmitView = SocketRawView(socket: self)

    /// The status of this client.
    public private(set) var status = SocketIOStatus.notConnected {
        didSet {
            handleClientEvent(.statusChange, data: [status, status.rawValue])
        }
    }

    /// Whether the socket is currently subscribed to its manager. Mirrors JS
    /// `socket.io-client/lib/socket.ts` `get active() { return !!this.subs }`.
    /// Flipped `true` at the start of `connect()`, and `false` on the three
    /// JS `destroy()` paths: user `disconnect()`, server-initiated DISCONNECT
    /// packet, and CONNECT_ERROR packet receipt. Survives engine-close +
    /// reconnect cycles — `didDisconnect(reason:)` itself does NOT clear it,
    /// because the manager will auto-reconnect and re-issue CONNECT. Distinct
    /// from `socket.status.active` which reports whether the current status
    /// enum is a live state.
    public private(set) var active: Bool = false {
        didSet {
            guard active != oldValue else { return }
            (manager as? SocketManager)?.updateSubscriptionOrder(for: self, active: active)
        }
    }

    /// The id of this socket.io connect. This is different from the sid of the engine.io connection.
    public private(set) var sid: String?

    // MARK: Connection State Recovery (Socket.IO 4.6+)

    /// Maximum accepted length (UTF-8 bytes) for a server-provided offset string.
    /// See design spec §3.3 / §6.1 D1.
    public static let socketStateRecoveryMaxOffsetBytes = 256

    /// Fired as `.connectError` when a CONNECT packet without a `sid` arrives on a
    /// client: the server speaks an incompatible protocol.
    static let v2ServerConnectErrorMessage = "Incompatible Socket.IO server: CONNECT acknowledgement is missing sid. This client requires Socket.IO 4.x (Engine.IO 4)."

    /// Whether the last successful CONNECT ack recovered a prior session.
    /// Matches the `recovered` property on `socket.io-client` JS.
    public private(set) var recovered: Bool = false

    /// Private session id assigned by the server. `nil` until the first CONNECT ack.
    /// Written only after the server advertises a recovery pid.
    var _pid: String?

    /// Last observed event offset (server-controlled last-arg string).
    /// Bounded by `socketStateRecoveryMaxOffsetBytes`.
    var _lastOffset: String?

    let ackHandlers = SocketAckManager()
    var connectPayload: [String: Any]?

    private(set) var currentAck = -1
    /// Guards the `currentAck` allocator; see `allocateAckId()`.
    private let ackIdLock = NSLock()

    private lazy var logType = "SocketIOClient{\(nsp)}"
    private var receiveBuffer = [(event: String, data: [Any], ack: Int)]()

    // MARK: Send buffer

    private struct BufferedEmit {
        let data: [Any]
        let ack: Int?
        let binary: Bool
        let completion: (() -> ())?
    }

    /// A queued packet awaiting acknowledgement, retried until the budget is
    /// exhausted. JS `_queue` entries in `socket.io-client/lib/socket.ts`.
    private struct RetriableEmit {
        let queueId: Int
        let data: [Any]
        let userAck: ((Error?, [Any]) -> Void)?
        /// Per-attempt ack timeout. `nil` means wait indefinitely for the ack
        /// (the attempt can still be interrupted by a disconnect).
        let attemptTimeout: Double?
        let writeCompletion: (() -> Void)?
        let cancellation: SocketAsyncAckState?
        let binary: Bool
        var tryCount = 0
        var pending = false
        var ackID: Int?
    }

    /// Emits made while `retries` is active, in the order they were made.
    ///
    /// JS `socket._queue` (`_addToQueue`/`_drainQueue` in
    /// `socket.io-client/lib/socket.ts`): only the head packet is in flight;
    /// an attempt that is not acknowledged within the attempt timeout is
    /// re-sent until `retries` is exhausted, then discarded with an error.
    /// The queue survives a disconnect and drains (force) on the next CONNECT.
    ///
    /// Guarded by a lock for the same reason as `sendBuffer`.
    private var retryQueue = [RetriableEmit]()
    private let retryQueueLock = NSLock()
    private var retryQueueSeq = 0

    /// Emits made while the socket was not connected, in the order they were made.
    ///
    /// JS `socket.sendBuffer`. It deliberately survives a disconnect: the whole
    /// point is that these packets go out once the socket is connected again.
    /// Like JS it has no upper bound, so a socket that never connects keeps
    /// accumulating.
    ///
    /// Guarded by a lock rather than a queue because `emit` runs on the caller's
    /// thread while the flush runs on `handleQueue`.
    private var sendBuffer = [BufferedEmit]()
    private let sendBufferLock = NSLock()
    /// Accumulated estimated payload bytes of `sendBuffer`, maintained with it
    /// so the limit check does not re-walk every buffered payload.
    private var sendBufferBytes = 0
    /// Same accounting for `retryQueue`, guarded by `retryQueueLock`.
    private var retryQueueBytes = 0
    /// Same accounting for `receiveBuffer`, `handleQueue`-confined
    /// like the buffer itself.
    private var receiveBufferBytes = 0

    /// The pipeline-wide resource policy. Unlimited unless `.bufferLimits` was
    /// configured, which keeps the default behaviour JavaScript-equal.
    var bufferLimits: SocketBufferLimits {
        (manager as? SocketManager)?.bufferLimits ?? .unlimited
    }

    /// Per-namespace acknowledgement timeout in seconds. `nil` inherits the
    /// manager default; infinity disables the deadline. Mutate on handleQueue.
    public var ackTimeout: Double? {
        get { ackTimeoutOverride ?? (manager as? SocketManager)?.ackTimeout }
        set { ackTimeoutOverride = newValue.map { max(0, $0) } }
    }
    private var ackTimeoutOverride: Double?

    /// Per-namespace retry budget, initially inherited from the manager.
    /// Setting zero disables retries for this namespace. Mutate on handleQueue.
    public var retries: Int {
        get { retriesOverride ?? (manager as? SocketManager)?.retries ?? 0 }
        set { retriesOverride = max(0, newValue) }
    }
    private var retriesOverride: Int?

    /// Restores manager defaults for this namespace's delivery policy.
    public func resetDeliveryOptions() {
        ackTimeoutOverride = nil
        retriesOverride = nil
    }

    // MARK: Auth provider state

    /// Installed auth provider (callback-form, or async-form wrapped to callback).
    /// Invoked on `manager.handleQueue` for every CONNECT.
    private var authProvider: SocketAuthProvider?

    /// Type-erased cancel handle for the in-flight async auth `Task`. Capturing
    /// `task.cancel` here confines the `Task` reference to the async overload of
    /// `setAuth(_:)`.
    private var pendingAuthTask: (() -> Void)?

    /// Monotonic generation token bumped on `connect`, `setAuth`, and `clearAuth`.
    /// Async auth results captured under one generation are discarded if the
    /// generation has moved on by the time they hop back to `handleQueue`.
    private var authGeneration: UInt64 = 0

    // MARK: Initializers

    /// Type safe way to create a new SocketIOClient. `opts` can be omitted.
    ///
    /// - parameter manager: The manager for this socket.
    /// - parameter nsp: The namespace of the socket.
    public init(manager: SocketManagerSpec, nsp: String) {
        self.manager = manager
        self.nsp = nsp

        super.init()
    }

    /// :nodoc:
    deinit {
        connectTimeoutWork?.cancel()
        DefaultSocketLogger.Logger.log("Client is being released", type: logType)
    }

    // MARK: Methods

    /// Connect to the server. The same as calling `connect(timeoutAfter:withHandler:)` with a timeout of 0.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    ///
    /// - parameter withPayload: An optional payload sent on connect
    open func connect(withPayload payload: [String: Any]? = nil) {
        self.active = true
        connect(withPayload: payload, timeoutAfter: 0, withHandler: nil)
    }

    /// Connect to the server. If we aren't connected after `timeoutAfter` seconds, then `withHandler` is called.
    ///
    /// Only call after adding your event listeners, unless you know what you're doing.
    ///
    /// - parameter withPayload: An optional payload sent on connect
    /// - parameter timeoutAfter: The number of seconds after which if we are not connected we assume the connection
    ///                           has failed. Pass 0 to never timeout.
    /// - parameter handler: The handler to call when the client fails to connect.
    open func connect(withPayload payload: [String: Any]? = nil, timeoutAfter: Double, withHandler handler: (() -> ())?) {
        self.active = true
        assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

        guard let manager = self.manager, status != .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting on an already connected socket", type: logType)
            return
        }

        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        self.authGeneration &+= 1
        let authAttempt = authGeneration
        connectGeneration &+= 1
        let attempt = connectGeneration

        // Install before status callbacks or joining: either can connect synchronously.
        if timeoutAfter != 0 {
            let timeout = DispatchWorkItem { [weak self] in
                guard let this = self, this.connectGeneration == attempt,
                      this.status == .connecting || this.status == .notConnected else { return }
                this.connectTimeoutWork = nil
                if this.status == .connecting {
                    DefaultSocketLogger.Logger.log("Timeout: Socket not connected, so setting to disconnected", type: this.logType)

                    // didDisconnect owns the state transition, notification and
                    // ack cleanup. Leave before it invokes reentrant listeners.
                    this.leaveNamespace()
                } else {
                    DefaultSocketLogger.Logger.log("Timeout: Socket already reset before connect completed", type: this.logType)
                }

                // A status/disconnect listener may have started a new attempt
                // while this work item was running; cancel() cannot stop it now.
                guard this.connectGeneration == attempt, this.status != .connected else { return }
                handler?()
            }
            connectTimeoutWork = timeout
            manager.handleQueue.asyncAfter(deadline: .now() + timeoutAfter, execute: timeout)
        }
        status = .connecting
        guard authGeneration == authAttempt, active, status == .connecting else { return }
        joinNamespace(withPayload: payload)
    }

    /// Returns the CONNECT payload to send to the server, merging `pid`/`offset` into
    /// a fresh dict if recovery state is present. The user's `connectPayload` wins on
    /// key collisions (matches JS `Object.assign({pid, offset}, data)`).
    /// Returns `connectPayload` unchanged when no pid is stored.
    func currentConnectPayload() -> [String: Any]? {
        guard let pid = _pid else { return connectPayload }
        var out: [String: Any] = ["pid": pid]
        if let offset = _lastOffset { out["offset"] = offset }
        if let user = connectPayload {
            if user["pid"] != nil || user["offset"] != nil {
                DefaultSocketLogger.Logger.log(
                    "connectPayload contains reserved key 'pid' or 'offset'; user value takes precedence",
                    type: logType
                )
            }
            for (k, v) in user { out[k] = v }
        }
        return out
    }

    /// Clears the in-memory state used for Connection State Recovery: `_pid`,
    /// `_lastOffset`, `recovered`, and any buffered replay packets from a prior
    /// session that have not yet been flushed by `didConnect()`. Also fails any
    /// outstanding Phase 9 timed-ack callbacks with `SocketAckError.disconnected`.
    ///
    /// Call this when the authenticated identity on this socket changes, to
    /// prevent a subsequent reconnect from resuming the prior session's stream.
    ///
    /// **Scope of protection.** This clears *in-memory* state only. It does NOT
    /// fence packets that have already been dispatched to app handlers, nor
    /// packets that the server will deliver for the still-live transport after
    /// this call returns but before the next CONNECT ack. For a clean identity
    /// boundary, callers should also `disconnect()` and reconnect (or create a
    /// fresh socket) rather than relying on `clearRecoveryState()` alone.
    ///
    /// **Timed-ack side effect (Swift-only, no JS counterpart).** Outstanding
    /// `timeout(after:).emit(...)` callbacks are fired with
    /// `SocketAckError.disconnected`. The user's intent on `clearRecoveryState()`
    /// — drop session-bound state — is operationally equivalent to disconnect
    /// for any callback waiting on a session-specific ack id: the id allocator
    /// is per-socket and a successor session would never deliver an ack for an
    /// id issued by the prior session. Dispatched on `handleQueue` so the clear
    /// runs serialized with add/execute/cancel (the entry's `fired` flag is
    /// queue-protected, not lock-protected).
    ///
    /// Subclass ordering: if a subclass overrides `disconnect()` and wants to
    /// auto-clear, call `clearRecoveryState()` BEFORE `super.disconnect()`. The
    /// `.disconnect` client event fires synchronously from super, and any observer
    /// that reconnects would otherwise send stale pid/offset.
    open func clearRecoveryState() {
        _pid = nil
        _lastOffset = nil
        recovered = false
        clearReceiveBuffer()

        // Phase 9: fail any in-flight timed acks with .disconnected. See
        // `didDisconnect` for the matching post-disconnect drain; this call
        // mirrors that behavior for the identity-swap path so a session-bound
        // ack id issued before the swap cannot dangle waiting on a successor
        // session that would never reuse it.
        // Unlike `didDisconnect`, buffered emits are dropped rather than kept:
        // this is the identity-swap path, and delivering the previous user's
        // queued events into the successor session would leak them across
        // identities. Their acks are therefore failed like any other.
        let retiringAckIDs = ackHandlers.pendingTimedAckIDs
        clearSendBuffer()
        // The retry queue follows the same rule: the previous identity's
        // unacknowledged emits must not be delivered (or retried) under the
        // successor's session. Each entry's ack callback is failed with
        // `.disconnected` — JS has no identity-swap concept; this follows the
        // Swift `clearRecoveryState` contract for the send buffer.
        clearRetriableQueue()

        manager?.handleQueue.socketAsync { [weak self] in
            self?.ackHandlers.clearTimedAcks(reason: .disconnected, only: retiringAckIDs)
        }
    }

    /// Records the last arg as `_lastOffset` if this is a socket with a known pid
    /// and the last arg is a String not exceeding the byte cap.
    private func captureOffsetIfNeeded(from args: [Any]) {
        guard _pid != nil else { return }
        guard let last = args.last as? String else { return }
        guard last.utf8.count <= SocketIOClient.socketStateRecoveryMaxOffsetBytes else {
            DefaultSocketLogger.Logger.log(
                "Dropping oversized offset string (\(last.utf8.count) bytes > \(SocketIOClient.socketStateRecoveryMaxOffsetBytes))",
                type: logType
            )
            return
        }
        _lastOffset = last
    }

    private func dispatchEvent(_ event: String, data: [Any], withAck ack: Int, isInternalMessage: Bool) {
        DefaultSocketLogger.Logger.log("Handling event: \(event) with \(data.count) data item(s)", type: logType)

        anyHandler?(SocketAnyEvent(event: event, items: data))

        // Snapshot the list so a listener's self-removal during dispatch doesn't
        // mutate the iteration. Snapshot is cheap (array of tuples).
        if !isInternalMessage {
            let snapshot = anyListeners
            for entry in snapshot {
                entry.handler(SocketAnyEvent(event: event, items: data))
            }
        }

        for handler in handlers where handler.event == event {
            handler.executeCallback(with: data, withAck: ack, withSocket: self)
        }
    }

    private func bufferReceivedEvent(_ packet: SocketPacket) {
        // Gate R1: these are peer-controlled packets replayed into a buffer the
        // application has not drained yet, so a flood is the one overflow with
        // no caller to report to. It closes the connection instead, the way
        // engine.io-client's `_onError` → `_onClose("transport error")` does.
        let limits = bufferLimits
        if !limits.isUnlimited {
            let bytes = SocketBufferLimits.retainedBytes(of: packet.args)
            let packets = receiveBuffer.count + 1
            let total = receiveBufferBytes + bytes
            if packets > limits.maximumRecoveryReplayPackets || total > limits.maximumRecoveryReplayBytes {
                let measuringBytes = total > limits.maximumRecoveryReplayBytes
                let error = SocketBufferLimitError(
                    buffer: .recoveryReplay,
                    limit: measuringBytes ? limits.maximumRecoveryReplayBytes : limits.maximumRecoveryReplayPackets,
                    attempted: measuringBytes ? total : packets,
                    measuringBytes: measuringBytes
                )
                DefaultSocketLogger.Logger.error(error.description, type: logType)
                clearReceiveBuffer()
                handleClientEvent(.error, data: [error])
                manager?.engine?.disconnect(reason: "transport error")

                return
            }
            receiveBufferBytes = total
        }
        receiveBuffer.append((event: packet.event, data: packet.args, ack: packet.id))
    }

    private func flushReceiveBuffer() {
        guard !receiveBuffer.isEmpty else { return }

        let bufferedEvents = receiveBuffer
        receiveBuffer.removeAll(keepingCapacity: false)
        receiveBufferBytes = 0

        for event in bufferedEvents {
            guard status == .connected else { break }
            handleEvent(event.event, data: event.data, isInternalMessage: false, withAck: event.ack)
            captureOffsetIfNeeded(from: event.data)
        }
    }

    private func clearReceiveBuffer() {
        receiveBuffer.removeAll(keepingCapacity: false)
        receiveBufferBytes = 0
    }

    func createOnAck(_ items: [Any], binary: Bool = true) -> OnAckCallback {
        guard !failIfReserved(items) else {
            return OnAckCallback(ackNumber: -1, items: [], socket: self, binary: binary)
        }
        do {
            let safe = try SocketPacket.jsonSafeEmitData(items, allowBinary: binary)
            return OnAckCallback(ackNumber: allocateAckId(), items: safe, socket: self, binary: binary)
        } catch {
            handleClientEvent(.error, data: [error])
            return OnAckCallback(ackNumber: -1, items: [], socket: self, binary: binary)
        }
    }

    /// Called when the client connects to a namespace. If the client was created with a namespace upfront,
    /// then this is only called when the client connects to that namespace.
    ///
    /// - parameter toNamespace: The namespace that was connected to.
    open func didConnect(toNamespace namespace: String, payload: [String: Any]?) {
        guard status != .connected else { return }

        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        DefaultSocketLogger.Logger.log("Socket connected", type: logType)
        sid = payload?["sid"] as? String

        let incomingPid = payload?["pid"] as? String
        recovered = (incomingPid != nil && _pid != nil && _pid == incomingPid)
        _pid = incomingPid

        let connectData: [Any]
        if var payload = payload {
            payload["recovered"] = recovered
            connectData = [namespace, payload]
        } else {
            connectData = [namespace, ["recovered": recovered]]
        }

        status = .connected
        flushReceiveBuffer()
        guard status == .connected else { return }
        // JS `onconnect()`: buffered packets go out before the `connect` event,
        // so a handler that emits does not overtake what was queued before it.
        flushSendBuffer()
        // JS `onconnect()` also drains the retry queue (force) here — a packet
        // whose ack was lost with the previous session is resent, and an emit
        // from a connect handler queues behind the drain instead of racing it.
        drainRetriableQueueOnConnect()
        handleClientEvent(.connect, data: connectData)
    }

    private var connectTimeoutWork: DispatchWorkItem?
    /// Connection identity is independent of provider changes: setAuth/clearAuth
    /// invalidate auth results, but must not silently disable the connect deadline.
    private var connectGeneration: UInt64 = 0

    private var pendingTransportCloseError: SocketTransportError?

    /// Preserves existing public close overrides while attaching detail only to
    /// this notification. Consume it before callbacks, so reentrancy cannot leak it.
    internal func handleTransportClose(reason: String, error: SocketTransportError?, reconnecting: Bool) {
        pendingTransportCloseError = error
        defer { pendingTransportCloseError = nil }
        if reconnecting { setReconnecting(reason: reason) }
        else { didDisconnect(reason: reason) }
    }

    /// Called when the client has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        guard status != .disconnected else { return }

        DefaultSocketLogger.Logger.log("Disconnected: \(reason)", type: logType)

        notifyDisconnectAndClearAcks(reason: reason) {
            clearReceiveBuffer()
            sid = ""
            status = .disconnected
        }
    }

    /// Close notification precedes ack failures, as in JS Socket.onclose().
    /// Snapshot IDs before status and disconnect listeners so this close cannot
    /// sweep a registration created by a listener for a replacement connection.
    private func notifyDisconnectAndClearAcks(reason: String, updatingState: () -> Void) {
        let retiringAckIDs = ackHandlers.pendingTimedAckIDs
        let stillBuffered = bufferedAckIds
        let error = pendingTransportCloseError
        pendingTransportCloseError = nil
        updatingState()
        handleClientEvent(.disconnect, data: error.map { [reason, $0] } ?? [reason])
        performOnHandleQueue { [weak self] in
            self?.ackHandlers.clearTimedAcks(reason: .disconnected,
                                             keeping: stillBuffered, only: retiringAckIDs)
        }
    }

    /// Clears a failed in-flight connect attempt without sending namespace leave packets.
    func abortPendingConnect() {
        guard status == .connecting else { return }

        clearReceiveBuffer()
        status = .notConnected
    }

    /// Disconnects the socket.
    ///
    /// Leaves this namespace and deactivates automatic reconnection. The manager keeps
    /// the cached socket so a later connect() can reuse this instance. Use the manager
    /// disconnectSocket(_:) API when the namespace must also be removed from its cache.
    open func disconnect() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        self.active = false
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
        emit(event, with: items, completion: completion)
    }
    
    /// Send an event to the server, with optional data items and optional write completion handler.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    open func emit(_ event: String, with items: [SocketData], completion: (() -> ())?) {

        do {
            // JS-aligned: `JSON.stringify` runs on the payload and throws for
            // anything it cannot represent, so the failure happens here —
            // before the retry queue or the send buffer take ownership.
            let mapped = try SocketPacket.jsonSafeEmitData(
                [event] + (try items.map({ try $0.socketRepresentation() })), allowBinary: true
            )

            // JS `emit()`: with `retries` set, EVERY emit goes through the
            // queue (`_addToQueue`), ack or not.
            if enqueueRetriableIfActive(mapped, userAck: nil, completion: completion) { return }

            emit(mapped, completion: completion)
        } catch {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event): \(error)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, error])
        }
    }

    /// Send an event to the server, requesting an ack with an err-first callback.
    ///
    /// JS-aligned with `socket.emit("ev", ..., (err, ...args) => {})` and
    /// `_registerAckCallback` in `socket.io-client/lib/socket.ts` with
    /// `flags.timeout` unset:
    /// - when `SocketManager.ackTimeout` is set, behaves exactly like
    ///   `timeout(after: ackTimeout).emit(...)` — the callback fires with
    ///   `SocketAckError.timeout` on timeout (and the packet is dropped from
    ///   the send buffer) or `SocketAckError.disconnected` on disconnect.
    /// - when it is `nil`, the callback is a plain ack registered with no
    ///   timer: it fires as `ack(nil, data)` on the server ack and is never
    ///   called with an error — not on disconnect either.
    ///
    /// If an error occurs trying to transform `items` into their socket representation, a `SocketClientEvent.error`
    /// will be emitted. The structure of the error data is `[eventName, items, theError]`
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter ack: The err-first ack callback.
    open func emit(_ event: String, _ items: SocketData..., ack: @escaping (Error?, [Any]) -> Void) {
        emit(event, with: items, ack: ack)
    }

    /// Array form of `emit(_:_:ack:)`. See above for the exact semantics of
    /// each branch.
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - parameter ack: The err-first ack callback.
    open func emit(_ event: String, with items: [SocketData], ack: @escaping (Error?, [Any]) -> Void) {
        do {
            let mapped = try SocketPacket.jsonSafeEmitData(
                [event] + (try items.map({ try $0.socketRepresentation() })), allowBinary: true
            )

            // JS `emit()`: with `retries` set, the queue takes over and the
            // per-attempt timeout is `flags.timeout ?? ackTimeout` — which is
            // exactly what `enqueueRetriableIfActive` defaults to. The
            // `flags.timeout` variant arrives through `emitTimed` below.
            if enqueueRetriableIfActive(mapped, userAck: ack) { return }

            if let defaultTimeout = ackTimeout {
                emitTimed(event: event, items: [], timeout: defaultTimeout, mappedItems: mapped, ack: ack)

                return
            }

            // Modern no-timeout acks are removed silently on disconnect, unlike
            // the deliberately retained legacy OnAckCallback API. A missing
            // manager or a released socket can never deliver the ack, so report
            // it as `emitTimed` does instead of dropping the callback.
            guard let queue = manager?.handleQueue else {
                ack(SocketAckError.disconnected, [])
                return
            }
            performOnHandleQueue { [weak self] in
                guard let self = self else {
                    ack(SocketAckError.disconnected, [])
                    return
                }
                guard !self.failIfReserved(mapped) else {
                    ack(NSError(domain: "SocketIO.Emit", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Reserved event name: " + event]), [])
                    return
                }
                let id = self.allocateAckId()
                self.ackHandlers.addTimedAck(id, on: queue, callback: ack,
                                            timeout: .infinity, notifyOnDisconnect: false)
                self.emit(mapped, ack: id)
            }
        } catch {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event): \(error)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, error])
            // The caller asked for an acknowledgement; a packet that never
            // leaves has to settle it exactly once, with the encoding error.
            ack(error, [])
        }
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
        emitWithAck(event, with: items)
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
    open func emitWithAck(_ event: String, with items: [SocketData]) -> OnAckCallback {

        do {
            return createOnAck(try SocketPacket.jsonSafeEmitData(
                [event] + (try items.map({ try $0.socketRepresentation() })), allowBinary: true
            ))
        } catch {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event): \(error)",
                                             type: logType)

            handleClientEvent(.error, data: [event, items, error])

            return OnAckCallback(ackNumber: -1, items: [], socket: self)
        }
    }

    /// JS-aligned `socket.send(...)` — sugar for `emit("message", ...)`.
    /// Server-side receives via `socket.on("message", ...)`.
    ///
    /// - parameter items: The items to send with the `"message"` event. May be left out.
    /// - parameter completion: Callback called on transport write completion.
    open func send(_ items: SocketData..., completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    /// Array form of `send`.
    ///
    /// - parameter items: The items to send with the `"message"` event.
    /// - parameter completion: Callback called on transport write completion.
    open func send(with items: [SocketData], completion: (() -> ())? = nil) {
        emit("message", with: items, completion: completion)
    }

    /// JS-aligned `socket.send(...)` returning an ack callback. Sugar for
    /// `emitWithAck("message", ...)`.
    ///
    /// **NOTE**: The returned `OnAckCallback.timingOut(after:)` chain still uses
    /// the magic-string `SocketAckStatus.noAck` for timeouts and is not cleared
    /// on disconnect (see Phase 9 spec section). Users wanting typed errors and
    /// disconnect-clearing should use Phase 9's
    /// `socket.timeout(after:).emit("message", ack:)` instead (when available).
    ///
    /// - parameter items: The items to send with the `"message"` event. May be left out.
    /// - returns: An `OnAckCallback`. You must call `timingOut(after:)` before the event will be sent.
    open func sendWithAck(_ items: SocketData...) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }

    /// Array form of `sendWithAck`.
    ///
    /// - parameter items: The items to send with the `"message"` event.
    /// - returns: An `OnAckCallback`. You must call `timingOut(after:)` before the event will be sent.
    open func sendWithAck(with items: [SocketData]) -> OnAckCallback {
        return emitWithAck("message", with: items)
    }

    /// Volatile-emit chain. Packets are dropped if the engine transport is not
    /// writable (no `.error`, no outgoing listener, no buffer). See
    /// `SocketVolatileEmitter` for full semantics.
    public var volatile: SocketVolatileEmitter {
        return SocketVolatileEmitter(socket: self)
    }

    /// Internal entry — routes through the funnel with `volatile: true`. Marked
    /// `internal` so users go through the chain.
    internal func emitVolatile(_ data: [Any], completion: (() -> ())? = nil) {
        emit(data, ack: nil, binary: true, isAck: false, volatile: true, completion: completion)
    }

    internal func emitVolatile(event: String, items: [SocketData],
                               ack: @escaping (Error?, [Any]) -> Void) {
        performOnHandleQueue { [weak self] in
            guard let self = self, let manager = self.manager else { return }
            guard !self.failIfReserved([event]) else {
                ack(NSError(domain: "SocketIO.Emit", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Reserved event name: " + event]), [])
                return
            }
            let writable = manager.engine?.writable ?? false
            let timeout = self.ackTimeout ?? .infinity
            // JS registers before deciding to drop. Keep its observable timeout,
            // but do not retain an untimed callback for a packet never sent.
            guard writable || timeout.isFinite else { return }
            do {
                let mapped = writable ? try SocketPacket.jsonSafeEmitData(
                    [event] + items.map { try $0.socketRepresentation() }, allowBinary: true
                ) : []
                let id = self.allocateAckId()
                self.ackHandlers.addTimedAck(id, on: manager.handleQueue, callback: { [weak self] error, data in
                    if error != nil { self?.dropBufferedEmit(ack: id) }
                    ack(error, data)
                }, timeout: timeout, notifyOnDisconnect: timeout.isFinite)
                // Use the writability decision above. No retry queue, nor a second
                // drop decision after registering an untimed acknowledgement.
                if writable { self.emit(mapped, ack: id) }
            } catch {
                self.handleClientEvent(.error, data: [event, items, error])
                ack(error, [])
            }
        }
    }

    func emit(_ unsafeData: [Any],
              ack: Int? = nil,
              binary: Bool = true,
              isAck: Bool = false,
              volatile: Bool = false,
              completion: (() -> ())? = nil
    ) {
        // wrap the completion handler so it always runs async via handlerQueue
        let wrappedCompletion: (() -> ())? = (completion == nil) ? nil : {[weak self] in
            guard let this = self else { return }
            this.manager?.handleQueue.socketAsync {
                completion!()
            }
        }

        // Reserved-event guard — fires BEFORE the connected-state check, matching JS
        // where `emit()` throws regardless of connection state. isAck=true frames
        // (ack response packets) bypass the guard because their first item is the
        // ack id, not an event name.
        if !isAck, failIfReserved(unsafeData) {
            wrappedCompletion?()
            return
        }

        // Phase 7: volatile gate — JS-aligned per `socket.io-client/lib/socket.ts`
        // `emit()` body which sets `discardPacket = volatile && !transport.writable`.
        // Drop is silent: no .error, no outgoing listener fire, no buffering.
        // It runs before the encoder for the same reason it does in JS: a
        // discarded packet is never encoded, so it cannot report an encoding
        // error either.
        if volatile, !(manager?.engine?.writable ?? false) {
            DefaultSocketLogger.Logger.log(
                "volatile packet dropped (transport not writable)",
                type: logType
            )
            wrappedCompletion?()
            return
        }

        // Last-resort encoder gate. The public entry points already validated
        // (and normalized) their payload so their acks can carry the error;
        // this covers the paths that build `[Any]` directly — `rawEmitView`,
        // the Objective-C ack views — and guarantees nothing unencodable is
        // ever buffered or written. Re-validating an already-normalized array
        // is a no-op.
        let data: [Any]
        do {
            data = try SocketPacket.jsonSafeEmitData(unsafeData, allowBinary: binary)
        } catch {
            DefaultSocketLogger.Logger.error("Error encoding emit: \(error)", type: logType)

            wrappedCompletion?()
            handleClientEvent(.error, data: [error])

            return
        }

        // JS buffers an emit made while disconnected and sends it on the next
        // CONNECT (`sendBuffer` in `socket.io-client/lib/socket.ts` `emit()`)
        // instead of dropping it.
        //
        // Ack *responses* are left alone: JS does not buffer them either, and
        // this fork deliberately reports them as an error rather than dropping
        // them silently. Replaying an ack for an event the server handled in a
        // session that no longer exists would be meaningless anyway.
        guard status == .connected, manager?.engine?.hasPingExpired != true else {
            guard !isAck else {
                wrappedCompletion?()
                handleClientEvent(.error, data: ["Tried emitting when not connected"])
                return
            }

            DefaultSocketLogger.Logger.log("Buffering emit until connected: \(data)", type: logType)

            // Gate R1: the *new* emit is what fails when the buffer is full.
            // Evicting an already-buffered packet would silently drop an emit
            // the caller believes is on its way.
            if let error = appendToSendBuffer(BufferedEmit(data: data, ack: ack,
                                                           binary: binary, completion: wrappedCompletion)) {
                failOverflowingEmit(error, ack: ack, completion: wrappedCompletion)
            }

            return
        }

        sendPacket(data, ack: ack, binary: binary, isAck: isAck, completion: wrappedCompletion)
    }

    /// Writes a packet that is cleared to go out now.
    ///
    /// Split out of `emit` so a buffered packet takes exactly the same path when
    /// it is eventually flushed, down to when the outgoing listeners fire.
    private func sendPacket(_ data: [Any],
                            ack: Int?,
                            binary: Bool,
                            isAck: Bool,
                            completion: (() -> ())?
    ) {
        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: isAck, checkForBinary: binary)
        let str: String
        do {
            str = try packet.encodedPacketString()
        } catch {
            // Unreachable from the emit entry points, which validate the
            // payload before anything is buffered, queued or written. Kept so a
            // future caller cannot reintroduce the silent empty-payload packet.
            DefaultSocketLogger.Logger.error("Refusing to send an unencodable packet: \(error)", type: logType)

            completion?()
            handleClientEvent(.error, data: [error])

            return
        }

        DefaultSocketLogger.Logger.log("Emitting: \(str), Ack: \(isAck)", type: logType)

        // Fire any-outgoing listeners — JS-aligned per `socket.io-client/lib/socket.ts`
        // `emit()` body (~`:443-454`): fires ONLY on actual send. For a buffered
        // packet that is at flush time, which is where JS fires them too
        // (`emitBuffered()`). Ack response frames bypass: their first item is the
        // ack id, not an event name.
        if !isAck, let event = data.first as? String {
            let snapshot = anyOutgoingListeners
            let items = Array(data.dropFirst())
            for entry in snapshot {
                entry.handler(SocketAnyEvent(event: event, items: items))
            }
        }

        manager?.engine?.send(str, withData: packet.binary, completion: completion)
    }

    /// Sends everything that was emitted while the socket was not connected, in
    /// the order it was emitted. JS `emitBuffered()`.
    private func flushSendBuffer() {
        sendBufferLock.lock()
        let buffered = sendBuffer
        sendBuffer.removeAll(keepingCapacity: false)
        sendBufferBytes = 0
        sendBufferLock.unlock()

        guard !buffered.isEmpty else { return }

        DefaultSocketLogger.Logger.log("Flushing \(buffered.count) buffered emit(s)", type: logType)

        for entry in buffered {
            sendPacket(entry.data,
                       ack: entry.ack,
                       binary: entry.binary,
                       isAck: false,
                       completion: entry.completion)
        }
    }

    /// The ack ids of the packets still sitting in the send buffer.
    private var bufferedAckIds: Set<Int> {
        sendBufferLock.lock()
        defer { sendBufferLock.unlock() }

        return Set(sendBuffer.compactMap({ $0.ack }))
    }

    /// Drops a buffered packet whose ack will never be waited on again.
    ///
    /// JS does this inside the ack timeout (`_registerAckCallback`), so an emit
    /// that already timed out is not delivered later by a reconnect.
    /// Discards everything waiting in the send buffer.
    private func clearSendBuffer() {
        sendBufferLock.lock()
        defer { sendBufferLock.unlock() }

        sendBuffer.removeAll(keepingCapacity: false)
        sendBufferBytes = 0
    }

    func dropBufferedEmit(ack: Int) {
        sendBufferLock.lock()
        defer { sendBufferLock.unlock() }

        for entry in sendBuffer where entry.ack == ack {
            sendBufferBytes = max(0, sendBufferBytes - SocketBufferLimits.retainedBytes(of: entry.data))
        }
        sendBuffer.removeAll(where: { $0.ack == ack })
    }

    // MARK: - Gate R1 — bounded application buffers

    /// Appends under the configured bound, returning the error when the buffer
    /// is full. Nothing is ever evicted to make room.
    private func appendToSendBuffer(_ entry: BufferedEmit) -> SocketBufferLimitError? {
        let limits = bufferLimits
        let bytes = limits.isUnlimited ? 0 : SocketBufferLimits.retainedBytes(of: entry.data)

        sendBufferLock.lock()
        if !limits.isUnlimited {
            let packets = sendBuffer.count + 1
            let total = sendBufferBytes + bytes
            if packets > limits.maximumSendBufferPackets || total > limits.maximumSendBufferBytes {
                sendBufferLock.unlock()
                let measuringBytes = total > limits.maximumSendBufferBytes

                return SocketBufferLimitError(
                    buffer: .sendBuffer,
                    limit: measuringBytes ? limits.maximumSendBufferBytes : limits.maximumSendBufferPackets,
                    attempted: measuringBytes ? total : packets,
                    measuringBytes: measuringBytes
                )
            }
            sendBufferBytes = total
        }
        sendBuffer.append(entry)
        sendBufferLock.unlock()

        return nil
    }

    /// Settles a rejected emit exactly once: the local write completion runs,
    /// the acknowledgement (if the caller asked for one) settles with the typed
    /// error, and the `.error` client event carries the same error. No packet
    /// is buffered, queued or written.
    private func failOverflowingEmit(_ error: SocketBufferLimitError,
                                     ack: Int?,
                                     completion: (() -> ())?) {
        DefaultSocketLogger.Logger.error(error.description, type: logType)

        completion?()
        if let ack = ack {
            // `cancelTimedAck(fireWith:)` is the one-shot fire site the timeout
            // and disconnect paths use, so the caller cannot be notified twice.
            // Every acknowledgement-carrying emit reaches this funnel from
            // inside `performOnHandleQueue`, i.e. already on the owning
            // `handleQueue`; the hop is only for a caller that built its own id.
            performOnHandleQueue { [weak self] in
                self?.ackHandlers.cancelTimedAck(ack, fireWith: error)
            }
        }
        handleClientEvent(.error, data: [error])
    }

    // MARK: - Retry queue (JS `retries` option)

    /// JS `this._opts.retries` — falsy disables the retry queue entirely.
    private var activeRetries: Int {
        retries
    }

    /// JS `_opts.retries && !flags.fromQueue && !flags.volatile`. Enqueues the
    /// emit instead of sending it and returns `true` if the queue took over.
    ///
    /// Called from the public emit wrappers BEFORE any ack registration, since
    /// each retry attempt re-registers a fresh ack — the caller's ack is stored
    /// on the queue entry and fired once on final success or discard.
    func enqueueRetriableIfActive(_ data: [Any], userAck: ((Error?, [Any]) -> Void)?,
                                  attemptTimeout: Double? = nil,
                                  completion: (() -> Void)? = nil,
                                  cancellation: SocketAsyncAckState? = nil,
                                  binary: Bool = true) -> Bool {
        guard activeRetries > 0, !data.isEmpty else { return false }
        if failIfReserved(data) {
            if let completion = completion { manager?.handleQueue.socketAsync(execute: completion) }
            userAck?(NSError(domain: "SocketIO.Emit", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "Reserved event name"]), [])
            return true
        }
        let timeout = attemptTimeout ?? ackTimeout
        // Implicit acknowledgements need a finite deadline: without a server ack,
        // an unlimited wait would block every subsequent retry-queue entry.
        // Explicit acknowledgement APIs retain their existing no-timeout contract.
        if userAck == nil {
            guard let timeout = timeout, timeout.isFinite, timeout >= 0 else {
                let error = NSError(domain: "SocketIO.Emit", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Retried emits without an acknowledgement callback require a finite, non-negative ackTimeout"
                ])
                DefaultSocketLogger.Logger.error(error.localizedDescription, type: logType)
                if let completion = completion { manager?.handleQueue.socketAsync(execute: completion) }
                handleClientEvent(.error, data: [data[0], Array(data.dropFirst()), error])
                // Consume the rejected emit so the caller cannot buffer or send it.
                return true
            }
        }
        let writeCompletion: (() -> Void)? = completion.map { callback in
            let queue = manager?.handleQueue
            let once = SocketOnce<Void> { _ in queue?.socketAsync(execute: callback) }
            return { once.call(()) }
        }
        DefaultSocketLogger.Logger.log("Queueing retriable emit: \(data)", type: logType)

        // Gate R1: a never-acknowledged head blocks the queue, so without a
        // bound the entries behind it accumulate forever. The *new* emit is
        // what fails; the head keeps its place and its retry budget.
        let limits = bufferLimits
        let bytes = limits.isUnlimited ? 0 : SocketBufferLimits.retainedBytes(of: data)

        retryQueueLock.lock()
        if !limits.isUnlimited {
            let packets = retryQueue.count + 1
            let total = retryQueueBytes + bytes
            if packets > limits.maximumRetryQueuePackets || total > limits.maximumRetryQueueBytes {
                retryQueueLock.unlock()
                let measuringBytes = total > limits.maximumRetryQueueBytes
                let error = SocketBufferLimitError(
                    buffer: .retryQueue,
                    limit: measuringBytes ? limits.maximumRetryQueueBytes : limits.maximumRetryQueuePackets,
                    attempted: measuringBytes ? total : packets,
                    measuringBytes: measuringBytes
                )
                DefaultSocketLogger.Logger.error(error.description, type: logType)
                if let completion = completion { manager?.handleQueue.socketAsync(execute: completion) }
                userAck?(error, [])
                handleClientEvent(.error, data: [error])

                // Consume the rejected emit so the caller cannot buffer or send it.
                return true
            }
            retryQueueBytes = total
        }
        retryQueueSeq += 1
        let queueId = retryQueueSeq
        retryQueue.append(RetriableEmit(queueId: queueId, data: data, userAck: userAck,
                                        attemptTimeout: timeout, writeCompletion: writeCompletion,
                                        cancellation: cancellation, binary: binary))
        cancellation?.registerQueue(queueId)
        retryQueueLock.unlock()

        // JS `_addToQueue` ends with `_drainQueue()`; the drain itself gates on
        // `connected`, so queueing while disconnected simply parks the packet
        // here (JS retry.ts "should not drain the queue while the socket is
        // disconnected").
        performOnHandleQueue { [weak self] in
            self?.drainRetriableQueue(force: false)
        }

        return true
    }

    /// JS `_drainQueue(force)` — sends the head packet, and only the head,
    /// when the socket is connected. A pending (unacknowledged) head is
    /// skipped unless `force` is set, which is what a CONNECT uses to resend
    /// a packet whose ack may have been lost with the previous session.
    private func drainRetriableQueue(force: Bool) {
        guard status == .connected else { return }

        retryQueueLock.lock()
        guard !retryQueue.isEmpty else {
            retryQueueLock.unlock()
            return
        }

        var head = retryQueue[0]
        if head.cancellation?.isCancelled == true {
            retryQueueLock.unlock()
            cancelRetriableEmit(queueId: head.queueId)
            return
        }
        if head.pending && !force {
            retryQueueLock.unlock()
            return
        }

        let supersededAckID = head.ackID
        let id = allocateAckId()
        head.pending = true
        head.tryCount += 1
        head.ackID = id
        retryQueue[0] = head
        retryQueueLock.unlock()
        if let oldID = supersededAckID { ackHandlers.cancelTimedAck(oldID) }

        // Each attempt is a fresh packet with a fresh ack id, exactly like the
        // JS re-emit through `emit()` with the `fromQueue` flag: the id is
        // allocated per attempt, the ack callback fires once (timeout / server
        // ack / disconnect), and a late ack for a superseded attempt is a
        // no-op because its entry is gone.
        DefaultSocketLogger.Logger.log(
            "Sending retriable emit [\(head.queueId)] (try #\(head.tryCount))", type: logType
        )

        let queueId = head.queueId
        let internalAck: (Error?, [Any]) -> Void = { [weak self] err, data in
            self?.handleQueueAck(queueId: queueId, ackId: id, error: err, data: data)
        }
        if let manager = manager {
            // An absent timeout (`nil`) registers an ack timer that never
            // fires. A disconnect removes that plain registration silently;
            // reconnect force-drains the retained queue head with a new ID.
            ackHandlers.addTimedAck(id, on: manager.handleQueue, callback: internalAck,
                                    timeout: head.attemptTimeout ?? .infinity,
                                    notifyOnDisconnect: head.attemptTimeout?.isFinite == true)
        }
        sendPacket(head.data, ack: id, binary: head.binary, isAck: false, completion: head.writeCompletion)
    }

    /// The queue's internal ack — JS `_addToQueue`'s appended callback.
    /// Only the head packet is in flight, so an ack for anything else is stale.
    private func handleQueueAck(queueId: Int, ackId: Int, error: Error?, data: [Any]) {
        retryQueueLock.lock()
        guard let head = retryQueue.first, head.queueId == queueId, head.ackID == ackId else {
            retryQueueLock.unlock()
            DefaultSocketLogger.Logger.log("Retriable emit [\(queueId)] already acknowledged", type: logType)
            return
        }

        if head.cancellation?.isCancelled == true {
            retryQueueLock.unlock()
            cancelRetriableEmit(queueId: queueId)
            return
        }
        if let err = error {
            // JS: `packet.tryCount > this._opts.retries` — the first attempt
            // counts as one, so a total of `retries + 1` sends happen.
            guard head.tryCount > activeRetries else {
                var retried = head
                retried.pending = false
                retried.ackID = nil
                retryQueue[0] = retried
                retryQueueLock.unlock()
                drainRetriableQueue(force: false)
                return
            }

            DefaultSocketLogger.Logger.log(
                "Retriable emit [\(queueId)] discarded after \(head.tryCount) tries", type: logType
            )
            removeRetryQueueHeadLocked()
            let userAck = head.userAck
            retryQueueLock.unlock()

            userAck?(err, [])
        } else {
            removeRetryQueueHeadLocked()
            let userAck = head.userAck
            retryQueueLock.unlock()

            userAck?(nil, data)
        }

        drainRetriableQueue(force: false)
    }

    /// Cancels either a waiting queue entry or its active attempt on handleQueue.
    /// Removing before invoking user code makes late ACKs and reentrant emits safe.
    private func cancelRetriableEmit(queueId: Int) {
        retryQueueLock.lock()
        guard let index = retryQueue.firstIndex(where: { $0.queueId == queueId }) else {
            retryQueueLock.unlock()
            return
        }
        let entry = retryQueue.remove(at: index)
        if !bufferLimits.isUnlimited {
            retryQueueBytes = max(0, retryQueueBytes - SocketBufferLimits.retainedBytes(of: entry.data))
        }
        retryQueueLock.unlock()
        if let id = entry.ackID {
            ackHandlers.cancelTimedAck(id)
            dropBufferedEmit(ack: id)
        }
        entry.writeCompletion?()
        entry.userAck?(CancellationError(), [])
        drainRetriableQueue(force: false)
    }

    /// Task cancellation has no JS Promise counterpart; it retires the same
    /// queue/ack registration used by the shared delivery path.
    func cancelAsyncEmit(_ state: SocketAsyncAckState) {
        if let queueID = state.registeredQueueID {
            cancelRetriableEmit(queueId: queueID)
        } else if let id = state.registeredID {
            ackHandlers.cancelTimedAck(id, fireWith: CancellationError())
        }
    }

    /// JS `onconnect()`: `emitBuffered(); _drainQueue(true); emitReserved("connect")`
    /// — the retry queue drains between the send-buffer flush and the
    /// `connect` event, so an emit from inside a connect handler queues
    /// behind the drain instead of racing it (JS retry.ts "should not emit a
    /// packet twice in the 'connect' handler").
    private func drainRetriableQueueOnConnect() {
        // The drain must stay synchronous: deferring it would resend a packet
        // emitted from the new connect handler (JS `onconnect` drains before
        // `connect`). didConnect is already confined to handleQueue.
        drainRetriableQueue(force: true)
    }

    /// Drops every queued retriable emit, failing its user ack with
    /// `.disconnected`. Identity-swap path only — a session-bound queued
    /// packet must not reach the successor session.
    private func clearRetriableQueue() {
        retryQueueLock.lock()
        let dropped = retryQueue
        retryQueue.removeAll(keepingCapacity: false)
        retryQueueBytes = 0
        retryQueueLock.unlock()

        // `cancelTimedAck` must run on the owning handleQueue; the public
        // `clearRecoveryState()` reaches here without that precondition. Order
        // it before the `clearTimedAcks` dispatch that follows in the callers.
        let cancelIDs = dropped.compactMap { $0.ackID }
        if !cancelIDs.isEmpty {
            manager?.handleQueue.socketAsync { [weak self] in
                for id in cancelIDs { self?.ackHandlers.cancelTimedAck(id) }
            }
        }
        for entry in dropped {
            entry.writeCompletion?()
            entry.userAck?(SocketAckError.disconnected, [])
        }
    }

    /// Removes the head and its byte accounting. Caller holds `retryQueueLock`.
    private func removeRetryQueueHeadLocked() {
        guard !retryQueue.isEmpty else { return }

        if !bufferLimits.isUnlimited {
            retryQueueBytes = max(0, retryQueueBytes - SocketBufferLimits.retainedBytes(of: retryQueue[0].data))
        }
        retryQueue.removeFirst()
    }

    /// Returns `true` if the first element of `data` is a reserved event name.
    /// On hit: assertionFailure (DEBUG, non-XCTest) + handleClientEvent(.error)
    /// for user-visible signal. Wire behavior matches JS `emit()` throw —
    /// caller must early-return so no packet is written.
    private func failIfReserved(_ data: [Any]) -> Bool {
        guard let event = data.first as? String,
              SocketReservedEvent.names.contains(event) else {
            return false
        }
        let message = "\"\(event)\" is a reserved event name"
        #if DEBUG
        if NSClassFromString("XCTest") == nil {
            assertionFailure(message)
        }
        #endif
        handleClientEvent(.error, data: [message])
        return true
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
    open func handleAck(_ ack: Int, data: [Any]) {
        guard status == .connected else { return }

        DefaultSocketLogger.Logger.log("Handling ack: \(ack) with data: \(data)", type: logType)

        // Phase 9: try the timed-ack path first; both are no-ops on a missing
        // id, so the double-call is safe. Ack ids are unique across both stores
        // because both legacy emitWithAck and timed emit use the same
        // `currentAck += 1` allocator.
        ackHandlers.executeTimedAck(ack, with: data)
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
    open func handleEvent(_ event: String, data: [Any], isInternalMessage: Bool, withAck ack: Int = -1) {
        guard status == .connected || isInternalMessage else { return }
        dispatchEvent(event, data: data, withAck: ack, isInternalMessage: isInternalMessage)
    }

    /// Causes a client to handle a socket.io packet. The namespace for the packet must match the namespace of the
    /// socket.
    ///
    /// - parameter packet: The packet to handle.
    open func handlePacket(_ packet: SocketPacket) {
        guard packet.nsp == nsp else { return }

        switch packet.type {
        case .event, .binaryEvent:
            if status != .connected {
                bufferReceivedEvent(packet)
            } else {
                guard status == .connected else { return }
                handleEvent(packet.event, data: packet.args, isInternalMessage: false, withAck: packet.id)
                captureOffsetIfNeeded(from: packet.args)
            }
        case .ack, .binaryAck:
            handleAck(packet.id, data: packet.data)
        case .connect:
            // JS-aligned with `socket.io-client/lib/socket.ts` `onpacket`: a
            // CONNECT without a `sid` means an incompatible server, so
            // fire `connect_error` instead of connecting.
            if (packet.data.isEmpty || (packet.data[0] as? [String: Any])?["sid"] as? String == nil) {
                abortPendingConnect()
                handleClientEvent(.connectError, data: [SocketIOClient.v2ServerConnectErrorMessage])
            } else {
                didConnect(toNamespace: nsp, payload: packet.data.isEmpty ? nil : packet.data[0] as? [String: Any])
            }
        case .disconnect:
            // JS-aligned: server-initiated DISCONNECT calls `destroy()` which
            // clears `subs` (and therefore `active`) before emitting the
            // disconnect event — see `socket.io-client/lib/socket.ts`
            // `onserverdisconnect` ("io server disconnect").
            active = false
            didDisconnect(reason: "io server disconnect")
        case .error:
            // JS-aligned: receipt of CONNECT_ERROR calls `destroy()` before
            // emitting `connect_error`. The server has refused the namespace
            // connect; the manager will not auto-rejoin without explicit
            // `socket.connect()`, so `active` must reflect that.
            active = false
            abortPendingConnect()
            handleClientEvent(.connectError, data: packet.data)
        }
    }

    /// Call when you wish to leave a namespace and disconnect this socket.
    open func leaveNamespace() {
        if let manager = manager as? SocketManager {
            // JS keeps its namespace cache across a client disconnect so connect()
            // can reuse the same instance. Explicit manager removal is a separate API.
            // The active flag still determines whether the engine must stay alive.
            manager.disconnectSocket(self, removeFromManager: false)
        } else {
            manager?.disconnectSocket(self)
        }
    }

    /// Joins `nsp`. You shouldn't need to call this directly, instead call `connect`.
    ///
    /// - parameter withPayload: An optional payload sent on connect
    open func joinNamespace(withPayload payload: [String: Any]? = nil) {
        DefaultSocketLogger.Logger.log("Joining namespace \(nsp)", type: logType)

        connectPayload = payload

        manager?.connectSocket(self, withPayload: connectPayload)
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
    open func off(_ event: String) {
        DefaultSocketLogger.Logger.log("Removing handler for event: \(event)", type: logType)

        handlers = handlers.filter({ $0.event != event })
    }

    /// Removes a handler with the specified UUID gotten from an `on` or `once`
    ///
    /// If you want to remove all events for an event, call the off `off(_:)` method with the event name.
    ///
    /// - parameter id: The UUID of the handler you wish to remove.
    open func off(id: UUID) {
        DefaultSocketLogger.Logger.log("Removing handler with id: \(id)", type: logType)

        handlers = handlers.filter({ $0.id != id })
    }

    /// Adds a handler for an event.
    ///
    /// - parameter event: The event name for this handler.
    /// - parameter callback: The callback that will execute when this event is received.
    /// - returns: A unique id for the handler that can be used to remove it.
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
    open func onAny(_ handler: @escaping (SocketAnyEvent) -> ()) {
        anyHandler = handler
    }

    /// Append a catch-all listener. Returns a `UUID` handle for removal.
    /// Mirrors JS `socket.onAny(handler)`. Mutates immediately on `handleQueue`,
    /// asynchronously from other queues.
    @discardableResult
    open func addAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        performOnHandleQueue { [weak self] in
            self?.anyListeners.append((id: id, handler: handler))
        }
        return id
    }

    /// Prepend a catch-all listener (fires before existing listeners). Returns
    /// a `UUID` handle. Mirrors JS `socket.prependAny(handler)`. Mutator
    /// mutates immediately on `handleQueue`, asynchronously from other queues.
    @discardableResult
    open func prependAnyListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        performOnHandleQueue { [weak self] in
            self?.anyListeners.insert((id: id, handler: handler), at: 0)
        }
        return id
    }

    /// Remove a listener by its `UUID` handle. Unknown id is a silent no-op
    /// (matches JS `offAny`). Mutates immediately on `handleQueue`,
    /// asynchronously from other queues.
    open func removeAnyListener(id: UUID) {
        performOnHandleQueue { [weak self] in
            self?.anyListeners.removeAll { $0.id == id }
        }
    }

    /// Remove every listener registered via `addAnyListener` / `prependAnyListener`.
    /// Does NOT clear the legacy single `anyHandler`. Mutates immediately on
    /// `handleQueue`, asynchronously from other queues.
    open func removeAllAnyListeners() {
        performOnHandleQueue { [weak self] in
            self?.anyListeners.removeAll(keepingCapacity: false)
        }
    }

    /// Count of currently-registered any-listeners. Excludes the legacy single
    /// `anyHandler`. JS counterpart `socket.listenersAny()` returns the handler
    /// array; Swift returns count because closures lack identity.
    public var anyListenerCount: Int {
        return anyListeners.count
    }

    /// Append an outgoing-side catch-all listener. Fires after the
    /// `status == .connected` guard, immediately before `engine.send`.
    /// Mirrors JS `socket.onAnyOutgoing(handler)`.
    @discardableResult
    open func addAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        performOnHandleQueue { [weak self] in
            self?.anyOutgoingListeners.append((id: id, handler: handler))
        }
        return id
    }

    /// Prepend an outgoing-side catch-all listener.
    @discardableResult
    open func prependAnyOutgoingListener(_ handler: @escaping (SocketAnyEvent) -> ()) -> UUID {
        let id = UUID()
        performOnHandleQueue { [weak self] in
            self?.anyOutgoingListeners.insert((id: id, handler: handler), at: 0)
        }
        return id
    }

    /// Remove an outgoing-side listener by its `UUID`. Unknown id is a silent no-op.
    open func removeAnyOutgoingListener(id: UUID) {
        performOnHandleQueue { [weak self] in
            self?.anyOutgoingListeners.removeAll { $0.id == id }
        }
    }

    /// Remove every registered outgoing-side listener.
    open func removeAllAnyOutgoingListeners() {
        performOnHandleQueue { [weak self] in
            self?.anyOutgoingListeners.removeAll(keepingCapacity: false)
        }
    }

    /// Count of currently-registered any-outgoing-listeners. JS counterpart
    /// `socket.listenersAnyOutgoing()` returns the handler array; Swift returns count.
    public var anyOutgoingListenerCount: Int {
        return anyOutgoingListeners.count
    }

    /// Tries to reconnect to the server.
    @available(*, unavailable, message: "Call the manager's reconnect method")
    open func reconnect() { }

    /// Removes all handlers.
    ///
    /// Can be used after disconnecting to break any potential remaining retain cycles.
    open func removeAllHandlers() {
        handlers.removeAll(keepingCapacity: false)
    }

    /// Puts the socket back into the connecting state and reports the drop.
    /// Called when the manager detects a broken connection, or when a manual
    /// reconnect is triggered.
    ///
    /// JS-aligned with `Socket.onclose` in `socket.io-client/lib/socket.ts`
    /// (`connected = false; delete this.id; emitReserved("disconnect", reason)`).
    /// The socket keeps `active`, and Swift parks it in `.connecting` rather
    /// than `.disconnected` because that is what makes `SocketManager`
    /// re-join the namespace once the transport is back.
    ///
    /// **Changed in 17.0.0**: this used to emit `.reconnect` with the reason.
    /// `.reconnect` now means a *successful* reconnection and carries the
    /// attempt number, exactly as in JS.
    ///
    /// **Changed in 17.0.0**: acknowledgements are cleared here too. JS
    /// `Socket.onclose` ends with `_clearAcks()` on *every* close, including one
    /// that will be retried, so a pending ack cannot survive a reconnect and
    /// later match an id the new session re-issues.
    ///
    /// - parameter reason: The reason this socket is reconnecting.
    open func setReconnecting(reason: String) {
        // JS `Socket.onclose` → `_clearAcks()`. The same three rules apply as on
        // the terminal path: an ack whose packet is still in the send buffer is
        // kept (that packet has not reached the server and goes out on the next
        // CONNECT), a `withError` registration is settled with the disconnect
        // error, and a plain callback is dropped silently
        // (`notifyOnDisconnect == false`).
        //
        // The retry queue's per-attempt ack is one of these registrations. JS
        // re-registers a fresh one per attempt from `_drainQueue`, and the
        // appended `_addToQueue` callback decides what the disconnect means for
        // the entry: the head stays queued unless its budget is already spent,
        // and `drainRetriableQueueOnConnect` re-sends it under a new id.
        notifyDisconnectAndClearAcks(reason: reason) {
            clearReceiveBuffer()
            sid = ""
            status = .connecting
        }
    }

    // Test properties

    var testHandlers: [SocketEventHandler] {
        return handlers
    }

    func setTestable() {
        status = .connected
    }

    /// The number of packets currently sitting in the retry queue
    /// (JS `socket._queue.length`). Test accessor only.
    var testRetryQueueCount: Int {
        retryQueueLock.lock()
        defer { retryQueueLock.unlock() }
        return retryQueue.count
    }

    /// What the bounded buffers currently retain. Test accessor only: gate R1
    /// requires proof that the counts and bytes go back to zero after a reset
    /// or a disconnect, not only that the limits hold while they fill.
    var testRetainedBuffers: (sendPackets: Int, sendBytes: Int,
                              retryPackets: Int, retryBytes: Int,
                              replayPackets: Int, replayBytes: Int) {
        sendBufferLock.lock()
        let sendPackets = sendBuffer.count
        let sendBytes = sendBufferBytes
        sendBufferLock.unlock()

        retryQueueLock.lock()
        let retryPackets = retryQueue.count
        let retryBytes = retryQueueBytes
        retryQueueLock.unlock()

        return (sendPackets, sendBytes, retryPackets, retryBytes,
                receiveBuffer.count, receiveBufferBytes)
    }

    func setTestStatus(_ status: SocketIOStatus) {
        self.status = status
    }

    /// `connect()` sets `active` before moving the status, so a test that drives
    /// the status directly has to say whether the socket still wants its
    /// namespace — the manager only rejoins active ones.
    func setTestActive(_ value: Bool) {
        active = value
    }

    func setTestRecovered(_ value: Bool) {
        recovered = value
    }

}

// MARK: - Auth provider

public extension SocketIOClient {
    /// Install a callback-form auth provider. Invoked on `handleQueue` for every
    /// CONNECT (initial + every reconnect). JS-aligned: multi-callback sends
    /// multiple CONNECT packets (mirrors `socket.io-client/lib/socket.ts`
    /// `onopen()` calling `this.auth(cb)` without dedup).
    func setAuth(_ provider: @escaping SocketAuthProvider) {
        manager?.handleQueue.socketAsync { [weak self] in
            guard let self = self else { return }
            self.pendingAuthTask?()
            self.pendingAuthTask = nil
            self.authProvider = provider
            self.authGeneration &+= 1

        }
    }

    /// Remove the installed provider; cancels any in-flight async `Task`.
    func clearAuth() {
        manager?.handleQueue.socketAsync { [weak self] in
            guard let self = self else { return }
            self.pendingAuthTask?()
            self.pendingAuthTask = nil
            self.authProvider = nil
            self.authGeneration &+= 1
        }
    }
}

/// Internal `@unchecked Sendable` box used to ferry the non-Sendable
/// `SocketIOClient` reference through the `@Sendable` `Task { }` boundary
/// in `setAuth(_:)`'s async overload. Safe because the boxed reference is
/// only dereferenced on `handleQueue` after an `async` hop.
private struct WeakClientBox: @unchecked Sendable {
    weak var ref: SocketIOClient?
}

public extension SocketIOClient {
    /// Async/throws variant of `setAuth(_:)`. The async closure is invoked on
    /// every CONNECT (initial + reconnect) and its return value is used as the
    /// CONNECT payload. If the closure throws, a `.error` client event fires
    /// with the localized error description, the CONNECT packet is NOT sent,
    /// and the pending connect is aborted (fail-closed). Pure Swift addition —
    /// JS callback-form has no thrown-error analog.
    func setAuth(_ provider: @escaping @Sendable () async throws -> sending [String: Any]?) {
        let wrapped: SocketAuthProvider = { [weak self] cb in
            guard let self = self else { cb(nil); return }
            // Caller is on `handleQueue` (resolveConnectPayload contract). Snapshot
            // the generation now so a late async result can be discarded if the
            // socket has reconnected / re-auth'd in the meantime.
            let generation = self.authGeneration
            let box = WeakClientBox(ref: self)
            guard let queue = self.manager?.handleQueue else { cb(nil); return }
            let callback = SocketUncheckedSendableBox(cb)
            let task = Task {
                do {
                    let payload = try await provider()
                    queue.socketAsync {
                        guard let client = box.ref else { return }
                        guard client.authGeneration == generation,
                              client.status == .connecting else {
                            DefaultSocketLogger.Logger.log(
                                "auth result discarded; generation mismatch or socket no longer .connecting",
                                type: "SocketIOClient{\(client.nsp)}"
                            )
                            return
                        }
                        callback.value(payload)
                    }
                } catch {
                    queue.socketAsync {
                        guard let client = box.ref else { return }
                        guard client.authGeneration == generation else { return }
                        client.handleClientEvent(.error, data: [
                            "auth provider failed: \(error.localizedDescription)"
                        ])
                        // Fail-closed: CONNECT is not sent, so settle the
                        // in-flight attempt instead of leaving `.connecting`.
                        client.abortPendingConnect()
                    }
                }
            }
            self.pendingAuthTask = { task.cancel() }
        }
        setAuth(wrapped)
    }
}

// MARK: - Auth provider resolution

extension SocketIOClient {
    /// Invokes the installed provider (callback or async-wrapped) and forwards
    /// the result to `completion` on `handleQueue`. If no provider is installed,
    /// invokes `completion` with `explicit` synchronously. Caller MUST be on
    /// `handleQueue`.
    ///
    func resolveConnectPayload(explicit: [String: Any]?,
                               completion: @escaping ([String: Any]?) -> Void) {
        guard let provider = authProvider else {
            completion(explicit)
            return
        }


        guard let queue = manager?.handleQueue else { return }
        provider { resolved in
            // Always async-hop back. NEVER sync — callers like _engineDidOpen
            // are already on `handleQueue` and a sync re-entry would deadlock
            // on `handleQueue.sync` (and at minimum re-enter the dispatch chain
            // mid-iteration).
            queue.socketAsync {
                completion(resolved ?? explicit)
            }
        }
    }
}

// MARK: Phase 9 — timed-emit per-emit ack with typed SocketAckError

public extension SocketIOClient {
    /// Emits an event and awaits the server's acknowledgement, JS-aligned with
    /// `socket.emitWithAck(ev, ...args)` in `socket.io-client/lib/socket.ts`.
    ///
    /// The wait is bounded by the socket's effective `ackTimeout` when configured
    /// — exactly the `flags.timeout ?? _opts.ackTimeout` rule JS applies.
    ///
    /// Without retries, disconnect rejects with `SocketAckError.disconnected`,
    /// matching JS Promise acknowledgements. With retries, this uses the same
    /// ordered queue and per-attempt timeout as the callback API.
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event. May be left out.
    /// - returns: The acknowledgement arguments sent back by the server.
    nonisolated(nonsending) func emitWithAck(_ event: String, _ items: SocketData...) async throws -> sending [Any] {
        return try await emitWithAck(event, with: items)
    }

    /// Array form of the async `emitWithAck`.
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The items to send with this event.
    /// - returns: The acknowledgement arguments sent back by the server.
    nonisolated(nonsending) func emitWithAck(_ event: String, with items: [SocketData]) async throws -> sending [Any] {
        let ackTimeout = self.ackTimeout ?? .infinity

        return try await timeout(after: ackTimeout).emitWithAck(event, with: items)
    }

    /// Returns a chainable `SocketTimedEmitter` that emits with a typed-error
    /// per-emit ack. Mirrors `socket.timeout(ms).emit(ev, ..., (err, data) =>)`
    /// from the JS client.
    ///
    /// Pass `.infinity` to disable the timeout (the ack will still fail with
    /// `.disconnected` if the socket disconnects before the server acks).
    /// Pass a non-positive value to fire `.timeout` on the next handle-queue
    /// tick (matches `setTimeout(fn, <=0)` JS behavior).
    ///
    /// - parameter seconds: Maximum seconds to wait for the server ack.
    func timeout(after seconds: Double) -> SocketTimedEmitter {
        return SocketTimedEmitter(socket: self, timeout: seconds)
    }
}

extension SocketIOClient {
    // Queue-confined mutations must be visible to the next operation in the
    // same callback. Never sync-dispatch: callers already on the owning queue
    // run inline; off-queue callers retain the existing asynchronous behavior.
    private func performOnHandleQueue(_ work: @escaping () -> Void) {
        guard let manager = manager else { return }
        if (manager as? SocketManager)?.isOnHandleQueue == true { work() }
        else { manager.handleQueue.socketAsync(execute: work) }
    }

    /// Internal — called from `SocketTimedEmitter`. Allocates an ack id,
    /// registers the timed ack BEFORE running the emit funnel, then routes
    /// through the funnel.
    ///
    /// Registration-before-funnel ordering is critical: if the funnel's
    /// connected guard fires `.error` and early-returns, the timer is already
    /// scheduled and will fire `cb(.timeout, [])` after `timeout` seconds —
    /// matching JS `_registerAckCallback` semantics.
    func emitTimed(event: String,
                   items: [SocketData],
                   timeout: Double,
                   cancellation: SocketAsyncAckState? = nil,
                   mappedItems: [Any]? = nil,
                   ack: @escaping (Error?, [Any]) -> Void) {
        guard let manager = self.manager else { ack(SocketAckError.disconnected, []); return }
        let queue = manager.handleQueue
        performOnHandleQueue { [weak self] in
            guard let self = self else { return }
            if cancellation?.isCancelled == true { ack(CancellationError(), []); return }
            do {
                // A custom SocketData representation is evaluated exactly once.
                // `mappedItems` has already been normalized by the caller;
                // re-running the JS-stringify normalization on it is a no-op.
                let mapped = try SocketPacket.jsonSafeEmitData(
                    mappedItems ?? ([event] + items.map { try $0.socketRepresentation() }), allowBinary: true
                )
                guard !self.failIfReserved(mapped) else {
                    ack(NSError(domain: "SocketIO.Emit", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Reserved event name: " + event]), [])
                    return
                }
                if self.enqueueRetriableIfActive(mapped, userAck: ack, attemptTimeout: timeout,
                                                 cancellation: cancellation) { return }
                // Retry queue entries allocate their IDs per attempt, never here.
                let id = self.allocateAckId()
                cancellation?.register(id)
                let ackDroppingBuffered: (Error?, [Any]) -> Void = { [weak self] err, data in
                    if err != nil { self?.dropBufferedEmit(ack: id) }
                    ack(err, data)
                }
                self.ackHandlers.addTimedAck(id, on: queue, callback: ackDroppingBuffered, timeout: timeout)
                self.emit(mapped, ack: id, binary: true, isAck: false)
            } catch {
                // Exactly one settlement for the user's ack, and the same
                // `.error` client event every other emit path reports.
                self.handleClientEvent(.error, data: [event, items, error])
                ack(error, [])
            }
        }
    }

    /// Allocate IDs on handleQueue together with acknowledgement registration.
    func allocateAckId() -> Int {
        // The modern paths call this from `handleQueue`, but the legacy
        // `emitWithAck` chain allocates through `createOnAck` on the caller's
        // thread, so the counter itself is lock-guarded. Without that, a legacy
        // emit on one thread and a modern one on `handleQueue` would race on the
        // same `Int` — and could hand two registrations the same id.
        ackIdLock.lock()
        defer { ackIdLock.unlock() }

        currentAck += 1

        return currentAck
    }
}
