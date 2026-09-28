//
//  SocketEngine.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/3/15.
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

/// The class that handles the engine.io protocol and transports.
/// See `SocketEnginePollable` and `SocketEngineWebsocket` for transport specific methods.
open class SocketEngine: NSObject,
                         SocketEnginePollable, SocketEngineWebsocket, ConfigSettable {
  
  
    // MARK: Properties

    private static let logType = "SocketEngine"

    /// The queue that all engine actions take place on.
    public let engineQueue = DispatchQueue(label: "com.socketio.engineHandleQueue")
    private let engineQueueKey = DispatchSpecificKey<Bool>()
    private var generation: UInt64 = 0
    internal private(set) var webSocketTransport: EngineWebSocketTransport?
    internal var webSocketTransportFactory: ((URLRequest) -> EngineWebSocketTransport)?
    internal var webSocketProbeTimeout: TimeInterval = 10
    /// Per-session barrier for HTTP POSTs, including callbacks discarded after close.
    internal private(set) var pollingPostGroup = DispatchGroup()
    /// Internal test seam; production polling retains the default session configuration.
    internal var pollingSessionConfigurationFactory: () -> URLSessionConfiguration = { .default }
    /// Explicit per-request polling timeout; nil preserves native URLSession defaults.
    public private(set) var requestTimeout: TimeInterval?
    private var clientCertificate: URLCredential?
    private var tlsConfiguration: SocketTLSConfiguration = .systemDefault
    private var webSocketOptions = SocketWebSocketOptions()
    /// Pipeline-wide resource policy; only `maximumPollingResponseBytes` is
    /// enforced at this layer. Unlimited by default, like the JS client.
    internal private(set) var bufferLimits = SocketBufferLimits.unlimited
    private var configurationError: String?

    /// Server cookies are opt-in and never use the application's shared cookie store.
    public private(set) var withCredentials = false
    public private(set) var forceBase64 = false
    public private(set) var addTrailingSlash = true
    /// Kept across reconnects and polling-to-WebSocket upgrades, not across engines.
    internal let credentialCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage

    /// The connect parameters sent during a connect.
    public var connectParams: [String: Any]? {
        didSet {
            (urlPolling, urlWebSocket) = createURLs()
        }
    }

    /// A dictionary of extra http headers that will be set during connection.
    public var extraHeaders: [String: String]?

    /// A queue of engine.io messages waiting for POSTing
    ///
    /// **You should not touch this directly**
    public var postWait = [Post]()

    /// `true` if there is an outstanding poll. Trying to poll before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    public var waitingForPoll = false

    /// `true` if there is an outstanding post. Trying to post before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    public var waitingForPost = false

    /// `true` if this engine is closed.
    public private(set) var closed = false

    /// `true` if this engine is connected. Connected means that the initial poll connect has succeeded.
    public private(set) var connected = false

    /// Whether the active transport can accept a volatile write without queuing.
    /// The manager reads this from its own queue; native transport state is always
    /// inspected on engineQueue, including while a polling upgrade is in progress.
    public var writable: Bool {
        let read = {
            self.connected && !self.closed && !self.hasPingExpired && !self.probing && !self.fastUpgrade &&
                (self.polling ? !self.waitingForPost :
                    (self.wsConnected && self.webSocketTransport?.isWritable == true))
        }
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil { return read() }
        return engineQueue.sync(execute: read)
    }

    /// An array of HTTPCookies that are sent during the connection.
    public private(set) var cookies: [HTTPCookie]?

    /// When `true`, the engine is in the process of switching to WebSockets.
    ///
    /// **Do not touch this directly**
    public private(set) var fastUpgrade = false

    /// Ordered connection candidates; forcePolling/forceWebsockets restrict this list.
    public private(set) var transports: [SocketTransport] = [.polling, .websocket]
    public private(set) var tryAllTransports = false
    public private(set) var rememberUpgrade = false
    private var openingTransports: [SocketTransport] = []
    private static let upgradeMemory = SocketUpgradeMemory()

    private var configuredTransports: [SocketTransport] {
        if forcePolling { return transports.filter { $0 == .polling } }
        if forceWebsockets { return transports.filter { $0 == .websocket } }
        return transports
    }

    /// When `true`, the engine will only use HTTP long-polling as a transport.
    public private(set) var forcePolling = false

    /// When `true`, the engine will only use WebSockets as a transport.
    public private(set) var forceWebsockets = false

    /// `true` If engine's session has been invalidated.
    public private(set) var invalidated = false

    /// If `true`, the engine is currently in HTTP long-polling mode.
    public private(set) var polling = true

    /// The maximum number of bytes this server accepts in a single polling POST,
    /// taken from the handshake. `nil` before the handshake or if the server
    /// does not advertise a limit.
    public private(set) var maxPayload: Int?

    /// If `true`, the engine is currently seeing whether it can upgrade to WebSockets.
    public private(set) var probing = false

    /// The URLSession that will be used for polling.
    public private(set) var session: URLSession?

    /// The session id for this engine.
    public private(set) var sid = ""

    /// The path to engine.io.
    public private(set) var socketPath = "/engine.io/"

    /// Whether polling/WebSocket requests carry a cache-busting timestamp
    /// query parameter. `nil` is the JS default (`timestampRequests` unset):
    /// polling requests carry it, WebSocket URLs do not. `true`: both carry
    /// it. `false`: neither does.
    public private(set) var timestampRequests: Bool? = nil

    /// The query parameter name used for the cache-busting timestamp.
    /// Default `"t"`, JS-aligned with `timestampParam` in engine.io-client.
    public private(set) var timestampParam = "t"

    /// The url for polling.
    public private(set) var urlPolling = URL(string: "http://localhost/")!

    /// The url for WebSockets.
    public private(set) var urlWebSocket = URL(string: "http://localhost/")!

    /// Whether or not the WebSocket is currently connected.
    public private(set) var wsConnected = false

    /// The client for this engine.
    public weak var client: SocketEngineClient?

    private weak var sessionDelegate: URLSessionDelegate?

    private let url: URL

    // Monotonic deadlines do not drift with wall-clock changes. Only an Engine.IO
    // OPEN or PING resets the v4 heartbeat, never an application message.
    internal var heartbeatNow: () -> DispatchTime = { .now() }
    private var heartbeatDeadline: UInt64?
    private var heartbeatExpired = false
    private var heartbeatToken: UInt64 = 0
    private var heartbeatWork: DispatchWorkItem?
    private var pingInterval: Int?
    private var pingTimeout = 0

    /// Set while a graceful close waits for an unfinished upgrade to settle.
    /// Non-nil is JS's `readyState === "closing"`: no new packet may be written.
    private var pendingCloseReason: String?
    private(set) var probeWait = ProbeWaitQueue()
    private var secure = false

    // MARK: Initializers

    /// Creates a new engine.
    ///
    /// - parameter client: The client for this engine.
    /// - parameter url: The url for this engine.
    /// - parameter config: An array of configuration options for this engine.
    public init(client: SocketEngineClient, url: URL, config: SocketIOClientConfiguration) {
        self.client = client
        self.url = url
        self.secure = ["https", "wss"].contains(url.scheme?.lowercased() ?? "")

        super.init()

        setConfigs(config)

        engineQueue.setSpecific(key: engineQueueKey, value: true)

        (urlPolling, urlWebSocket) = createURLs()
    }

    /// Creates a new engine.
    ///
    /// - parameter client: The client for this engine.
    /// - parameter url: The url for this engine.
    /// - parameter options: The options for this engine.
    public required convenience init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        self.init(client: client, url: url, config: options?.toSocketConfiguration() ?? [])
    }

    /// :nodoc:
    deinit {
        DefaultSocketLogger.Logger.log("Engine is being released", type: SocketEngine.logType)
        closed = true
        heartbeatWork?.cancel()
        session?.invalidateAndCancel()
        let abandoned = webSocketTransport
        engineQueue.socketAsync {
            abandoned?.onEvent = nil
            abandoned?.abort()
        }
    }

    // MARK: Methods

    private func checkAndHandleEngineError(_ msg: String) {
        /*
         A message that is not a valid Engine.IO packet is JS's
         `{ type: "error", data: "parser error" }` (engine.io-parser
         `decodePacket`): `_onPacket` routes it through `_onError`, which closes
         with "transport error". Reporting it without closing would leave the
         engine attached to a transport the server has already given up on.

         A server error body names the reason:
         0: Unknown transport
         1: Unknown sid
         2: Bad handshake request
         3: Bad request
         */
        let reason = (try? msg.toDictionary())?["message"] as? String
        didError(reason: reason ?? "parser error")
    }


    /// Retires the current attempt once and completes abandoned writes locally.
    /// A graceful polling close owns its old session until the final POST or deadline.
    private func closeOutEngine(reason: String, graceful: Bool = false,
                                flushPollingQueue: Bool = false, error: SocketTransportError? = nil) {
        guard !closed else { return }
        cancelHeartbeat()
        let oldTransport = webSocketTransport
        let wasWebSocketOpen = wsConnected
        let wasPolling = polling
        let wasUpgrading = polling && (probing || fastUpgrade) && oldTransport != nil
        let pendingPosts = postWait
        let pendingProbes = probeWait
        pendingCloseReason = nil
        // Every request has to be built while the SID below is still current.
        let retiringRequests = graceful && wasPolling && flushPollingQueue
            ? pollingCloseRequests(for: pendingPosts) : []
        sid = ""
        closed = true
        invalidated = true
        connected = false
        wsConnected = false
        probing = false
        fastUpgrade = false
        waitingForPoll = false
        waitingForPost = false
        webSocketTransport = nil
        postWait.removeAll()
        probeWait.removeAll()
        // Transfer ownership before notifying clients or running completions.
        // resetEngine() may only invalidate the active slot, never this detached
        // retiring session. Its own POST group and deadline outlive a reconnect.
        let oldSession = session
        let retiringPostGroup = pollingPostGroup
        session = nil
        pollingPostGroup = DispatchGroup()
        var retiringSender: RetiringPollingSender?
        if let oldSession = oldSession, !retiringRequests.isEmpty {
            // Engine.IO permits only one POST at a time. Wait for the old
            // session's actual POST completions, even though their engine
            // callbacks are now stale. Never read the replacement session here.
            let sender = RetiringPollingSender(session: oldSession, queue: engineQueue,
                                               requests: retiringRequests, timeout: pollingRetirementDeadline)
            retiringSender = sender
            retiringPostGroup.socketNotify(queue: engineQueue) { sender.start() }
            engineQueue.socketAsyncAfter(deadline: .now() + pollingRetirementDeadline) {
                // A write stalled at close time must not retain the session
                // forever or send a close after invalidation when its barrier
                // eventually drains. Requests this sender starts itself are
                // bounded individually, at the moment they go out.
                sender.abandonIfNotStarted()
            }
        } else {
            oldSession?.invalidateAndCancel()
        }
        oldTransport?.onEvent = nil
        if graceful, !wasPolling, wasWebSocketOpen, let transport = oldTransport {
            // Send Engine.IO's close packet after earlier writes. Detach the old
            // transport first: neither its close nor its completions can affect
            // a replacement engine connection. Bound even a stalled final write.
            transport.sendBatch([.text("1")]) { [weak transport] result in
                if case .success = result { transport?.close(code: 1000, reason: nil) }
                else { transport?.abort() }
            }
            engineQueue.socketAsyncAfter(deadline: .now() + 1) { transport.abort() }
        } else {
            oldTransport?.abort()
        }
        if wasUpgrading {
            client?.engineDidFailUpgrade?(error: error ?? SocketTransportError(
                transport: "websocket", operation: "upgrade", closeReason: "socket closed"))
        }
        if let error = error, let callback = client?.engineDidClose(reason:error:) {
            callback(reason, error)
        } else {
            client?.engineDidClose(reason: reason)
        }
        // The retiring sender owns the queued packets' completions: each fires
        // when its batch reaches the wire, and any batch it gives up on is
        // completed locally there instead.
        if retiringSender == nil {
            for pending in pendingPosts { pending.completion?() }
        }
        for pending in pendingProbes { pending.completion?() }
    }

    /// Batches the abandoned polling queue exactly like a live flush would, then
    /// appends the Engine.IO close packet as its own final request.
    ///
    /// JS `close()` waits for `drain` — every buffered packet flushed, sliced by
    /// `maxPayload` — before `_onClose` tells the transport to close, and
    /// socket.io-client's `disconnect()` puts the namespace DISCONNECT packet
    /// into that buffer first. Dropping the queue here would silently swallow it.
    private func pollingCloseRequests(for pending: [Post]) -> [RetiringPollingRequest] {
        var batches = [RetiringPollingRequest]()
        var remaining = pending

        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(writablePrefixCount(of: remaining)))
            remaining.removeFirst(batch.count)
            batches.append(RetiringPollingRequest(request: createRequestForPost(with: batch.map { $0.msg }),
                                                  completions: batch.compactMap { $0.completion }))
        }

        // The close is its own request: it must never be dropped by a maxPayload
        // slice, and the server ends the session the moment it arrives.
        batches.append(RetiringPollingRequest(
            request: createRequestForPost(with: [String(SocketEnginePacketType.close.rawValue)]),
            completions: []
        ))

        return batches
    }

    /// Starts the connection to the server.
    open func connect() {
        engineQueue.socketAsync {
            self._connect()
        }
    }

    private func _connect() {
        if connected {
            DefaultSocketLogger.Logger.error("Engine tried opening while connected. Assuming this was a reconnect",
                                             type: SocketEngine.logType)
            _disconnect(reason: "transport close")
            // A reconnect cannot wait for an upgrade to settle — `resetEngine()`
            // below replaces the session either way, so close the old one now
            // instead of deferring a close that would never run.
            closeAfterUpgradeSettled(overPolling: polling)
        }

        DefaultSocketLogger.Logger.log("Starting engine. Server: \(url)", type: SocketEngine.logType)
        DefaultSocketLogger.Logger.log("Handshaking", type: SocketEngine.logType)

        openingTransports = []
        resetEngine()
        if let error = validateConfiguration() {
            didError(reason: "Invalid socket configuration: " + error)
            return
        }

        openingTransports = configuredTransports
        if rememberUpgrade, Self.upgradeMemory.succeeded, openingTransports.contains(.websocket) {
            openingTransports.removeAll { $0 == .websocket }
            openingTransports.insert(.websocket, at: 0)
        }
        startOpeningTransport()
    }

    /// Starts one attempt without notifying the manager of intermediate failures.
    private func startOpeningTransport() {
        guard let transport = openingTransports.first else { return }
        polling = transport == .polling
        if transport == .websocket {
            createWebSocketAndConnect()
        } else {
            var request = createPollingRequest(for: urlPollingHandshake)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            addHeaders(to: &request)
            doLongPoll(for: request)
        }
    }

    /// A fallback gets a fresh session/generation, so callbacks from the failed
    /// transport cannot close or parse into its successor.
    private func tryNextOpeningTransport() -> Bool {
        Self.upgradeMemory.succeeded = false
        guard !connected, tryAllTransports, openingTransports.count > 1 else { return false }
        openingTransports.removeFirst()
        resetEngine()
        startOpeningTransport()
        return true
    }

    private func createURLs() -> (URL, URL) {
        if client == nil {
            return (URL(string: "http://localhost/")!, URL(string: "http://localhost/")!)
        }

        var urlPolling = URLComponents(string: url.absoluteString)!
        var urlWebSocket = URLComponents(string: url.absoluteString)!
        var queryString = ""

        // JS `socket.io-client/lib/index.ts`:
        // `if (parsed.query && !opts.query) opts.query = parsed.queryKey` — the
        // parameters written into the server URL are used, but an explicit
        // `query` option replaces them rather than merging with them.
        let urlQuery = urlPolling.percentEncodedQuery

        urlWebSocket.path = socketPath
        urlPolling.path = socketPath

        if secure {
            urlPolling.scheme = "https"
            urlWebSocket.scheme = "wss"
        } else {
            urlPolling.scheme = "http"
            urlWebSocket.scheme = "ws"
        }

        if let connectParams = self.connectParams {
            for (key, value) in connectParams.sorted(by: { $0.key < $1.key }) {
                let keyEsc = key.urlEncode()!
                let valueEsc = "\(value)".urlEncode()!

                queryString += "&\(keyEsc)=\(valueEsc)"
            }
        } else if let urlQuery = urlQuery, !urlQuery.isEmpty {
            // Already percent-encoded by whoever built the URL; re-encoding it
            // would double-escape the separators.
            queryString += "&" + urlQuery
        }

        // Engine.IO owns these keys. Inspect decoded *names*, never substring
        // matches (e.g. token=EIO must not suppress the protocol version).
        let reserved: Set<String> = ["EIO", "transport", "sid", "b64"]
        let parameters = queryString.split(separator: "&", omittingEmptySubsequences: true).filter { part in
            let name = String(part.split(separator: "=", maxSplits: 1,
                                         omittingEmptySubsequences: false)[0])
            return !reserved.contains(name.removingPercentEncoding ?? name)
        }
        let suffix = parameters.isEmpty ? "" : "&" + parameters.joined(separator: "&")
        urlWebSocket.percentEncodedQuery = "transport=websocket" + (forceBase64 ? "&b64=1" : "") + suffix + engineIOParam
        urlPolling.percentEncodedQuery = "transport=polling&b64=1" + suffix + engineIOParam

        return (urlPolling.url!, urlWebSocket.url!)
    }

    private func createWebSocketAndConnect() {
        var request = URLRequest(url: urlWebSocketWithSid)
        addHeaders(to: &request, includingCookies:
            withCredentials ? credentialCookieStorage?.cookies(for: urlPollingWithSid) : nil)
        // addHeaders already applies explicit Cookie/extraHeaders precedence.
        request.httpShouldHandleCookies = false
        let options = webSocketOptions
        let transport = webSocketTransportFactory?(request) ?? URLSessionWebSocketTransport(
            request: request, queue: engineQueue,
            configuration: .ephemeral,
            tlsConfiguration: tlsConfiguration, sessionDelegate: sessionDelegate,
            clientCertificate: clientCertificate,
            maximumMessageSize: options.maximumMessageSize,
            maximumPendingBytes: options.maximumPendingBytes,
            maximumPendingBatches: options.maximumPendingBatches,
            maximumPendingMessages: options.maximumPendingMessages)
        let attempt = generation
        webSocketTransport = transport
        let queue = engineQueue
        transport.onEvent = { [weak self, weak transport] event in
            queue.socketAsync { [weak self, weak transport] in
                guard let self = self, let transport = transport,
                      self.generation == attempt, !self.closed,
                      self.webSocketTransport === transport else { return }
                switch event {
                case .opened(_, let headers):
                    if self.withCredentials {
                        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: self.urlPolling)
                        self.credentialCookieStorage?.setCookies(cookies, for: self.urlPolling, mainDocumentURL: nil)
                    }
                    self.wsConnected = true
                    self.client?.engineDidWebsocketUpgrade(headers: headers)
                    self.websocketDidConnect()
                case .message(.text(let message)):
                    self.parseEngineMessage(message)
                case .message(.binary(let data)):
                    self.parseEngineData(data)
                case .closed(let code, let reason, let error):
                    self.websocketDidDisconnect(error: error, reason: reason.flatMap { String(data: $0, encoding: .utf8) },
                                                closeCode: code)
                }
            }
        }
        transport.connect()
    }

    /// Server order is retained, but only locally configured transports can upgrade.
    func filterUpgrades(_ advertised: [String]) -> [SocketTransport] {
        advertised.compactMap(SocketTransport.init(rawValue:)).filter { configuredTransports.contains($0) }
    }

    private func validateConfiguration() -> String? {
        if let error = configurationError { return error }
        if let requestTimeout, !requestTimeout.isFinite || requestTimeout <= 0 {
            return "requestTimeout must be a positive finite number of seconds"
        }
        if transports.isEmpty { return "No transports available" }
        if configuredTransports.isEmpty { return "Forced transport is absent from transports" }
        if Set(transports).count != transports.count { return "Duplicate transport names" }
        if forcePolling && forceWebsockets { return "forcePolling and forceWebsockets cannot both be true" }
        if tlsConfiguration.requiresTLS && !secure { return "a custom security policy requires https/wss" }
        if let clientCertificate {
            guard secure else { return "clientCertificate requires https/wss" }
            #if canImport(Security)
            guard clientCertificate.identity != nil else { return "clientCertificate requires a client identity" }
            #else
            return "clientCertificate requires Apple's Security framework"
            #endif
        }
        return tlsConfiguration.validationError ?? webSocketOptions.validationError
    }

    // Scoped to the legacy error hook on engineQueue so overrides still observe
    // structured failures without emitting duplicate client events.
    private var currentTransportError: SocketTransportError?

    /// Called when an error happens during execution. Causes a disconnection.
    open func didError(reason: String) {
        let fail = { [weak self] in
            guard let self = self, !self.closed else { return }
            if self.tryNextOpeningTransport() { return }
            DefaultSocketLogger.Logger.error(reason, type: SocketEngine.logType)
            let error = self.currentTransportError
            if let error, let callback = self.client?.engineDidError(reason:error:) {
                callback(reason, error)
            } else {
                self.client?.engineDidError(reason: reason)
            }
            self.closeOutEngine(reason: "transport error", error: error)
        }
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil { fail() }
        else { engineQueue.socketAsync(execute: fail) }
    }

    /// Structured transport failure, reported through `didError(reason:)` before close.
    open func didError(reason: String, error: SocketTransportError) {
        let fail = { [weak self] in
            guard let self = self, !self.closed else { return }
            let previousError = self.currentTransportError
            self.currentTransportError = error
            defer { self.currentTransportError = previousError }
            self.didError(reason: reason)
        }
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil { fail() }
        else { engineQueue.socketAsync(execute: fail) }
    }

    /// Disconnects from the server.
    ///
    /// - parameter reason: The reason for the disconnection. This is communicated up to the client.
    open func disconnect(reason: String) {
        engineQueue.socketAsync {
            self._disconnect(reason: reason)
        }
    }

    private func _disconnect(reason: String) {
        guard connected && !closed else { return closeOutEngine(reason: reason) }

        DefaultSocketLogger.Logger.log("Engine is being closed.", type: SocketEngine.logType)

        // JS `close()` calls `waitForUpgrade()` while `this.upgrading`: packets
        // cannot be written through a transport paused for an upgrade, so the
        // close waits for `upgrade` or `upgradeError` and the buffer then leaves
        // over whichever transport won. Recording the reason marks the engine as
        // closing, which is what stops further writes (see `_write`).
        if polling && (probing || fastUpgrade) {
            guard pendingCloseReason == nil else { return }
            DefaultSocketLogger.Logger.log("Deferring close until the upgrade settles", type: SocketEngine.logType)
            pendingCloseReason = reason
            return
        }

        if polling {
            disconnectPolling(reason: reason)
        } else {
            closeOutEngine(reason: reason, graceful: true)
        }
    }

    /// Flushes the queued packets for the retiring SID and then its close packet.
    /// An already-started POST is allowed to finish before those requests.
    private func disconnectPolling(reason: String) {
        closeOutEngine(reason: reason, graceful: true, flushPollingQueue: true)
    }

    /// Resumes a close that `_disconnect` deferred behind an unfinished upgrade.
    private func closeAfterUpgradeSettled(overPolling: Bool) {
        guard let reason = pendingCloseReason else { return }
        pendingCloseReason = nil
        if overPolling { disconnectPolling(reason: reason) }
        else { closeOutEngine(reason: reason, graceful: true) }
    }

    /// Called to switch from HTTP long-polling to WebSockets. After calling this method the engine will be in
    /// WebSocket mode.
    ///
    /// **You shouldn't call this directly**
    open func doFastUpgrade() {
        guard canSendUpgradePacket, wsConnected, !closed else { return }
        DefaultSocketLogger.Logger.log("Switching to WebSockets", type: SocketEngine.logType)
        polling = false
        Self.upgradeMemory.succeeded = true
        retirePollingSession()
        fastUpgrade = false
        probing = false
        // Queue the upgrade packet before anything held by the polling transport.
        sendWebSocketMessage("", withType: .upgrade, withData: [], completion: nil)
        guard !closed else { return }
        client?.engineDidCompleteUpgrade?()
        flushWaitingForPostToWebSocket()
        flushProbeWait()
        // JS `waitForUpgrade()` resumes on `upgrade`, i.e. after the buffered
        // packets have gone out over the transport that won.
        closeAfterUpgradeSettled(overPolling: false)
    }

    /// Re-issues the writes held while the transport was paused for an upgrade.
    /// These packets are already buffered, so a close deferred behind the same
    /// upgrade must not drop them: JS keeps one `writeBuffer` and flushes it
    /// after `upgrade`/`upgradeError`, whereas `closing` only blocks new writes.
    private func flushProbeWait() {
        let waiting = probeWait
        probeWait.removeAll(keepingCapacity: false)
        for waiter in waiting {
            guard connected, !closed else { waiter.completion?(); continue }
            sendPreparedWrite(waiter.msg, withType: waiter.type, withData: waiter.data,
                              rawBinary: waiter.rawBinary, completion: waiter.completion)
        }
    }

    /// Flush polling wire packets as one FIFO batch (base64 binary remains valid
    /// Engine.IO text). Detach before completions to make reentrancy safe.
    open func flushWaitingForPostToWebSocket() {
        guard webSocketTransport != nil, !postWait.isEmpty else { return }
        let waiting = postWait
        postWait.removeAll(keepingCapacity: false)
        sendWebSocketBatch(waiting.map { .text($0.msg) }) {
            for waiter in waiting { waiter.completion?() }
        }
    }

    /// Completes once for the entire text header plus binary attachments. The
    /// callback reports local completion, not a server acknowledgement.
    open func sendWebSocketMessage(_ str: String, withType type: SocketEnginePacketType,
                                   withData data: [Data], completion: (() -> ())?) {
        guard DispatchQueue.getSpecific(key: engineQueueKey) != nil else {
            engineQueue.socketAsync { self.sendWebSocketMessage(str, withType: type, withData: data, completion: completion) }
            return
        }
        var messages: [EngineWebSocketMessage] = [.text(SocketEnginePacketCodec.encodeText(str, type: type))]
        messages += data.map {
            SocketEnginePacketCodec.encode(.init(type: .message, data: .binary($0)), supportsBinary: !forceBase64)
        }
        sendWebSocketBatch(messages, completion: completion)
    }

    private func sendWebSocketBatch(_ messages: [EngineWebSocketMessage], completion: (() -> Void)?) {
        guard let transport = webSocketTransport, wsConnected, !closed else {
            completion?()
            return
        }
        let attempt = generation
        transport.sendBatch(messages) { [weak self, weak transport] result in
            defer { completion?() }
            guard let self = self, let transport = transport,
                  self.generation == attempt, self.webSocketTransport === transport, !self.closed else { return }
            if case .failure(let error) = result { self.websocketDidDisconnect(error: error, reportSendError: true) }
        }
    }

    private func handleClose(_ reason: String) {
        // JS: engine.io-client maps the server's CLOSE packet to
        // "transport close" (engine.io v4 close packets carry no reason).
        closeOutEngine(reason: "transport close")
    }

    private func handleMessage(_ message: String) {
        client?.parseEngineMessage(message)
    }

    private func handleNOOP() {
        doPoll()
    }

    private func handleOpen(openData: String) {
        guard !closed, !connected else { return }
        guard let json = try? openData.toDictionary() else {
            didError(reason: "Error parsing open packet")

            return
        }

        guard let sid = json["sid"] as? String, !sid.isEmpty else {
            didError(reason: "Open packet contained no sid")

            return
        }

        // JS `onHandshake` stores the timers as-is and lets `_resetPingTimeout`
        // schedule `pingInterval + pingTimeout`: `pingInterval: 0` with a real
        // timeout is a working handshake, fractional milliseconds are fine, and
        // a missing timer makes that sum NaN so the heartbeat fires at once and
        // closes with "ping timeout". Only values this client cannot represent
        // as a Dispatch deadline stay a transport error: they originate at the
        // peer and must not overflow the integer addition below.
        func milliseconds(_ value: Any?) -> Int? {
            guard let value = value else { return 0 }
            guard SocketPacket.isJSONNumber(value), let number = value as? NSNumber else { return nil }
            let raw = number.doubleValue
            guard raw >= 0, raw <= 2_147_483_647 else { return nil }
            return Int(raw.rounded(.down))
        }
        guard let interval = milliseconds(json["pingInterval"]),
              let timeout = milliseconds(json["pingTimeout"]),
              interval <= 2_147_483_647 - timeout else {
            didError(reason: "Open packet contained invalid heartbeat timers")
            return
        }
        let upgradeWs: Bool

        self.sid = sid
        connected = true
        openingTransports = []
        Self.upgradeMemory.succeeded = !polling

        if let upgrades = json["upgrades"] as? [String] {
            upgradeWs = filterUpgrades(upgrades).contains(.websocket)
        } else {
            upgradeWs = false
        }

        self.pingInterval = interval
        self.pingTimeout = timeout

        // An omitted limit means
        // we batch without one, which is how this client always behaved.
        maxPayload = json["maxPayload"] as? Int

        if polling && upgradeWs {
            createWebSocketAndConnect()
        }

        checkPings()

        if polling {
            doPoll()
        }

        client?.engineDidOpen(reason: "Connect")
    }

    private func handlePong(with message: String) {

        // We should upgrade
        if message == "3probe" {
            DefaultSocketLogger.Logger.log("Received probe response, should upgrade to WebSockets",
                                           type: SocketEngine.logType)

            upgradeTransport()
        }

        client?.engineDidReceivePong()
    }

    private func handlePing(with message: String) {
        write("", withType: .pong, withData: [])
        checkPings()

        client?.engineDidReceivePing()
    }

    private func cancelHeartbeat() {
        heartbeatToken &+= 1
        heartbeatWork?.cancel()
        heartbeatWork = nil
        heartbeatDeadline = nil
    }

    private func checkPings() {
        guard connected, !closed, !heartbeatExpired else { return }
        cancelHeartbeat()
        let deadline = heartbeatNow() + .milliseconds((pingInterval ?? 25_000) + pingTimeout)
        heartbeatDeadline = deadline.uptimeNanoseconds
        let attempt = generation
        let token = heartbeatToken
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == attempt,
                  self.heartbeatToken == token, !self.closed else { return }
            self.heartbeatExpired = true
            self.closeOutEngine(reason: "ping timeout")
        }
        heartbeatWork = work
        engineQueue.socketAsyncAfter(deadline: deadline, execute: work)
    }

    public var hasPingExpired: Bool {
        let read = { () -> Bool in
            guard self.connected, !self.closed else { return false }
            if self.heartbeatExpired { return true }
            guard let deadline = self.heartbeatDeadline,
                  self.heartbeatNow().uptimeNanoseconds > deadline else { return false }
            self.heartbeatExpired = true
            let attempt = self.generation
            // `read` already holds `self` strongly for the duration of this
            // call; the close block is bounded by the same attempt/token guards.
            self.engineQueue.socketAsync {
                guard self.generation == attempt, self.heartbeatExpired else { return }
                self.closeOutEngine(reason: "ping timeout")
            }
            return true
        }
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil { return read() }
        return engineQueue.sync(execute: read)
    }

    /// Parses raw binary received from engine.io.
    ///
    /// - parameter data: The data to parse.
    open func parseEngineData(_ data: Data) {
        guard !closed else {
            DefaultSocketLogger.Logger.log("Ignoring binary data received after close", type: SocketEngine.logType)

            return
        }

        DefaultSocketLogger.Logger.log("Got binary data: \(data)", type: SocketEngine.logType)


        client?.parseEngineBinaryData(data)
    }

    /// Parses a raw engine.io packet.
    ///
    /// - parameter message: The message to parse.
    open func parseEngineMessage(_ message: String) {
        // JS-aligned (`_onPacket` in engine.io-client/lib/socket.ts ignores
        // packets unless readyState is opening/open/closing): after close the
        // session is over, so late packets — e.g. a handshake that finished
        // after a timeout-close — must not revive the engine.
        guard !closed else {
            DefaultSocketLogger.Logger.log("Ignoring packet received after close: \(message)", type: SocketEngine.logType)

            return
        }

        DefaultSocketLogger.Logger.log("Got message: \(message)", type: SocketEngine.logType)

        switch SocketEnginePacketCodec.decode(.text(message)) {
        case .success(let packet): dispatchDecodedPacket(packet)
        case .failure: checkAndHandleEngineError(message)
        }
    }

    /// Called on engineQueue; lifecycle processing deliberately stops at CLOSE.
    func dispatchDecodedPacket(_ packet: SocketEnginePacket) {
        guard !closed else { return }
        let text: String
        if case .text(let value) = packet.data { text = value } else { text = "" }
        switch packet.type {
        case .message:
            if case .binary(let data) = packet.data { client?.parseEngineBinaryData(data) }
            else { handleMessage(text) }
        case .noop: handleNOOP()
        case .ping: handlePing(with: "2" + text)
        case .pong: handlePong(with: "3" + text)
        case .open: handleOpen(openData: text)
        case .close: handleClose("1" + text)
        case .upgrade: break
        }
    }

    func dispatchPollingPayload(_ payload: String) {
        for packet in SocketEnginePacketCodec.decodePayload(payload) {
            guard !closed else { break }
            switch packet {
            case .success(let value): dispatchDecodedPacket(value)
            case .failure: checkAndHandleEngineError(payload)
            }
        }
    }

    /// Starts a new attempt with independent session, POST barrier and callback identity.
    private func resetEngine() {
        // Retire all callbacks before constructing a new session. A SID alone is
        // not a sufficient identity while either attempt is still handshaking.
        generation &+= 1
        webSocketTransport?.onEvent = nil
        webSocketTransport?.abort()
        webSocketTransport = nil
        let oldSession = session
        session = nil
        oldSession?.invalidateAndCancel()
        let pendingPosts = postWait
        let pendingProbes = probeWait
        postWait.removeAll(keepingCapacity: true)
        probeWait.removeAll(keepingCapacity: false)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = engineQueue
        closed = false
        connected = false
        wsConnected = false
        fastUpgrade = false
        maxPayload = nil
        polling = true
        probing = false
        invalidated = false
        sid = ""
        waitingForPoll = false
        waitingForPost = false
        cancelHeartbeat()
        heartbeatExpired = false
        pingInterval = nil
        pingTimeout = 0
        pendingCloseReason = nil
        let proxy = SocketSessionDelegateProxy(tlsConfiguration: tlsConfiguration, forwardingDelegate: sessionDelegate,
                                               clientCertificate: clientCertificate, credentialOrigin: urlPolling)
        proxy.onInvalidation = { [weak self] invalidSession, error in
            guard let self = self, self.session === invalidSession, self.polling, !self.closed,
                  let error = error else { return }
            self.didError(reason: error.localizedDescription)
        }
        pollingPostGroup = DispatchGroup()
        let configuration = pollingSessionConfigurationFactory()
        if let requestTimeout, requestTimeout.isFinite, requestTimeout > 0 {
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = requestTimeout
        }
        configuration.httpCookieStorage = withCredentials ? credentialCookieStorage : nil
        configuration.httpShouldSetCookies = withCredentials
        configuration.httpCookieAcceptPolicy = withCredentials ? .always : .never
        session = Foundation.URLSession(configuration: configuration,
                                        delegate: proxy, delegateQueue: queue)
        for pending in pendingPosts { pending.completion?() }
        for pending in pendingProbes { pending.completion?() }
    }


    /// Called when the engine should set/update its configs from a given configuration.
    ///
    /// parameter config: The `SocketIOClientConfiguration` that should be used to set/update configs.
    open func setConfigs(_ config: SocketIOClientConfiguration) {
        configurationError = nil
        // The manager passes its complete configuration. Omitted optional
        // credentials and request deadlines must not survive engine reuse.
        clientCertificate = nil
        requestTimeout = nil
        for option in config {
            switch option {
            case let .requestTimeout(timeout):
                requestTimeout = timeout
            case let .connectParams(params):
                connectParams = params
            case let .cookies(cookies):
                self.cookies = cookies
            case let .withCredentials(enabled):
                withCredentials = enabled
            case let .forceBase64(enabled):
                forceBase64 = enabled
            case let .addTrailingSlash(enabled):
                addTrailingSlash = enabled
            case let .extraHeaders(headers):
                extraHeaders = headers
            case let .sessionDelegate(delegate):
                sessionDelegate = delegate
            case let .transports(transports):
                self.transports = transports
            case let .tryAllTransports(enabled):
                tryAllTransports = enabled
            case let .rememberUpgrade(enabled):
                rememberUpgrade = enabled
            case let .forcePolling(force):
                forcePolling = force
            case let .forceWebsockets(force):
                forceWebsockets = force
            case let .path(path):
                socketPath = path
            case let .secure(secure):
                self.secure = secure
            case let .clientCertificate(credential):
                clientCertificate = credential
            case let .security(policy):
                tlsConfiguration = policy
            case let .webSocketOptions(options):
                webSocketOptions = options
            case let .bufferLimits(limits):
                bufferLimits = limits
            case let .invalidConfiguration(reason):
                configurationError = reason
            case let .timestampRequests(stamp):
                timestampRequests = stamp
            case let .timestampParam(param):
                timestampParam = param
            default:
                continue
            }
        }
        // Normalize after all options: configuration ordering must not matter.
        if socketPath.hasSuffix("/") { socketPath.removeLast() }
        if addTrailingSlash { socketPath += "/" }
        (urlPolling, urlWebSocket) = createURLs()
    }

    // Moves from long-polling to websockets
    private func upgradeTransport() {
        if wsConnected {
            DefaultSocketLogger.Logger.log("Upgrading transport to WebSockets", type: SocketEngine.logType)

            fastUpgrade = true
            // engine.io-client never sends a NOOP: the *server* sends one over
            // the outstanding polling GET when it sees the probe, which is what
            // releases that GET. The client NOOP this used to enqueue could not
            // leave over HTTP any more (`fastUpgrade` blocks POSTs), so it sat in
            // `postWait` and was flushed over the WebSocket right after the
            // upgrade packet — `5` followed by `6`. Node's engine.io ignores a
            // client NOOP; `@socket.io/bun-engine` treats it as a parse error and
            // closes the freshly upgraded connection.
            //
            // With no GET or POST outstanding there is no completion left to
            // finish the upgrade, so do it here (JS `pause()` resolves at once).
            if canSendUpgradePacket {
                doFastUpgrade()
            }
        }
    }

    /// Writes a message to engine.io, independent of transport.
    ///
    /// - parameter msg: The message to send.
    /// - parameter type: The type of this message.
    /// - parameter data: Any data that this message has.
    /// - parameter completion: Callback called on transport write completion.
    open func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())? = nil) {
        engineQueue.socketAsync {
            self._write(msg, withType: type, withData: data, completion: completion)
        }
    }

    private func _write(_ msg: String, withType type: SocketEnginePacketType,
                        withData data: [Data], rawBinary: Bool = false, completion: (() -> Void)?) {
        // JS `sendPacket` returns early once `readyState` is "closing"/"closed",
        // so a `send()` after `close()` never produces a packet — including
        // while the close is deferred behind an upgrade.
        guard connected, !closed, pendingCloseReason == nil else { completion?(); return }
        guard !probing else {
            probeWait.append((msg, type, data, rawBinary, completion))
            return
        }
        sendPreparedWrite(msg, withType: type, withData: data, rawBinary: rawBinary, completion: completion)
    }

    /// Sends one raw Engine.IO binary message, without a Socket.IO attachment header.
    open func send(_ data: Data, completion: (() -> Void)? = nil) {
        engineQueue.socketAsync {
            self._write("", withType: .message, withData: [data], rawBinary: true, completion: completion)
        }
    }

    private func sendPreparedWrite(_ msg: String, withType type: SocketEnginePacketType,
                                   withData data: [Data], rawBinary: Bool, completion: (() -> Void)?) {
        if rawBinary {
            let frames = data.map {
                SocketEnginePacketCodec.encode(.init(type: .message, data: .binary($0)), supportsBinary: !polling && !forceBase64)
            }
            if polling {
                for frame in frames {
                    if case .text(let value) = frame { postWait.append((value, completion)) }
                }
                if !waitingForPost { flushWaitingForPost() }
            } else { sendWebSocketBatch(frames, completion: completion) }
        } else if polling { sendPollMessage(msg, withType: type, withData: data, completion: completion) }
        else { sendWebSocketMessage(msg, withType: type, withData: data, completion: completion) }
    }

    private func websocketDidConnect() {
        // RFC6455 open is not Engine.IO open. In forced-WebSocket mode only the
        // subsequent Engine.IO `0{...}` handshake may set `connected`.
        guard polling else { return }
        probing = true
        probeWebSocket()
        let attempt = generation
        let candidate = webSocketTransport
        engineQueue.socketAsyncAfter(deadline: .now() + webSocketProbeTimeout) { [weak self, weak candidate] in
            guard let self = self, let candidate = candidate,
                  self.generation == attempt, self.webSocketTransport === candidate,
                  self.probing, !self.closed else { return }
            self.websocketDidDisconnect(error: nil, reason: "WebSocket probe timeout")
        }
    }

    private func websocketDidDisconnect(error: Error?, reason: String? = nil, reportSendError: Bool = false,
                                        closeCode: Int? = nil) {
        guard !closed else { return }
        if !connected, error != nil, tryNextOpeningTransport() { return }
        Self.upgradeMemory.succeeded = false
        let failed = webSocketTransport
        webSocketTransport = nil
        wsConnected = false
        failed?.onEvent = nil
        failed?.abort()
        // A retired polling session (`stopPolling()`) has no transport to fall
        // back to: resuming its poll loop would leave the engine "connected"
        // without any transport until the next reset.
        if polling && connected && !invalidated {
            // An optional upgrade candidate may fail without ending a healthy
            // polling connection. Resume both paused write and poll paths.
            probing = false
            fastUpgrade = false
            client?.engineDidFailUpgrade?(error: SocketTransportError(
                transport: "websocket", operation: "upgrade", closeCode: closeCode,
                closeReason: reason, underlyingError: error))
            guard !closed else { return }
            if pendingCloseReason != nil {
                // JS `waitForUpgrade()` also resumes on `upgradeError`: the
                // packets held for the upgrade go out over polling, followed by
                // the close. Queue them first so the close is POSTed last.
                flushProbeWait()
                closeAfterUpgradeSettled(overPolling: true)
                return
            }
            if !waitingForPost { flushWaitingForPost() }
            flushProbeWait()
            doPoll()
            return
        }
        let transportDetail = SocketTransportError(transport: "websocket", operation: "close",
                                          closeCode: closeCode, closeReason: reason, underlyingError: error)
        // A received close frame is a transport close, even if URLSession also
        // completes its outstanding receive with an error. No close frame means
        // a network/handshake failure (or an unclean 1006 close).
        let peerClosed = closeCode.map { $0 >= 1000 && $0 != 1006 } ?? false
        let message = error?.localizedDescription ?? reason ?? "Socket Disconnected"
        // The original failure must not be lost behind the close reason: JS
        // engine.io-client `_onError` always emits `error` before
        // `_onClose("transport error")`, and the manager forwards it. The socket
        // then decides (`Socket.onerror`) whether that is a `connect_error`.
        // The native close code and reason travel with it, which is what a
        // dropped WebSocket under an established connection otherwise hides.
        if let error = error, !peerClosed {
            let native = error as NSError
            var details = ["\(native.domain)/\(native.code): \(native.localizedDescription)"]
            if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
                details.append("underlying \(underlying.domain)/\(underlying.code): \(underlying.localizedDescription)")
            }
            if let code = closeCode { details.append("close code \(code)") }
            if let reason = reason, !reason.isEmpty { details.append("reason \(reason)") }
            let detail = details.joined(separator: "; ")
            DefaultSocketLogger.Logger.error("WebSocket failed: \(detail)", type: SocketEngine.logType)
            if let callback = client?.engineDidError(reason:error:) {
                callback(reportSendError ? message : detail, transportDetail)
            } else {
                client?.engineDidError(reason: reportSendError ? message : detail)
            }
        } else if let code = closeCode {
            DefaultSocketLogger.Logger.log("WebSocket closed with code \(code)\(reason.map { ": " + $0 } ?? "")",
                                           type: SocketEngine.logType)
        }
        // The disconnect reason is the JS close reason, not the error text —
        // the detail lives in the engineDidError payload above (engine.io-client
        // maps a failed transport to "transport error", a clean close to
        // "transport close").
        closeOutEngine(reason: error != nil && !peerClosed ? "transport error" : "transport close",
                       error: transportDetail)
    }

    /// Retires the polling session instead of merely draining it. JS builds a
    /// fresh transport per attempt; here the same engine object is reused, so an
    /// invalidated session that stayed in `session` would be handed to
    /// `dataTask` by a later `doPoll()` — an ObjC exception on Darwin. The
    /// retiring session keeps its own POST barrier; the engine takes a new one.
    open func stopPolling() {
        guard DispatchQueue.getSpecific(key: engineQueueKey) != nil else {
            engineQueue.socketAsync { self.stopPolling() }
            return
        }
        invalidated = true
        retirePollingSession()
    }

    /// Detach the polling resources without invalidating a live WebSocket engine.
    /// The upgrade barrier has drained before the successful handoff calls this.
    private func retirePollingSession() {
        waitingForPoll = false
        waitingForPost = false
        let retiring = session
        session = nil
        pollingPostGroup = DispatchGroup()
        retiring?.finishTasksAndInvalidate()
    }

    /// Polling entry points retain the common implementation and its upgrade barrier.
    open func doPoll() { performPollingRead() }

    open func sendPollMessage(_ message: String, withType type: SocketEnginePacketType,
                              withData datas: [Data], completion: (() -> ())?) {
        performPollingWrite(message, withType: type, withData: datas, completion: completion)
    }

    /// Internal test seam; production polling retirement remains bounded to one second.
    internal var pollingRetirementDeadline: TimeInterval = 1

    /// Supplies an isolated session for lifecycle tests without opening a network request.
    internal func setTestSession(_ value: URLSession?) { session = value }

    // Test Properties

    func setConnected(_ value: Bool) {
        connected = value
    }

    func setFastUpgrade(_ value: Bool) {
        fastUpgrade = value
    }

    func setMaxPayload(_ value: Int?) {
        maxPayload = value
    }
}

/// One request of a retiring polling session, with the write completions of the
/// packets it carries.
private struct RetiringPollingRequest {
    let request: URLRequest
    let completions: [() -> Void]
}

/// Drains a retired polling session: the packets that were still queued at close
/// time, then the Engine.IO close packet — one request at a time, because
/// Engine.IO permits only one POST per session at a time.
///
/// Every method runs on the engine queue it is constructed with, and the session
/// is retired exactly once. The per-request bound is armed when the request goes
/// out, so a slow earlier POST cannot consume the budget of the close after it.
private final class RetiringPollingSender {
    private let session: URLSession
    private let queue: DispatchQueue
    private let requests: [RetiringPollingRequest]
    private let timeout: TimeInterval
    private var index = 0
    private var started = false
    private var finished = false

    init(session: URLSession, queue: DispatchQueue, requests: [RetiringPollingRequest], timeout: TimeInterval) {
        self.session = session
        self.queue = queue
        self.requests = requests
        self.timeout = timeout
    }

    /// Called once the retiring session's own POST barrier has drained.
    func start() {
        guard !started, !finished else { return }
        started = true
        sendNext()
    }

    /// Called at the barrier deadline: a POST that was already in flight when the
    /// engine closed never settled, so nothing more may be written on this session.
    func abandonIfNotStarted() {
        guard !started else { return }
        finish(cancelling: true)
    }

    private func sendNext() {
        guard !finished else { return }
        guard index < requests.count else { return finish(cancelling: false) }

        let entry = requests[index]
        let attempt = index
        // The task's completion deliberately retains this sender: once the
        // barrier's notify block has run, nothing else holds it, and the chain
        // has to survive as far as the close packet. The per-request bound below
        // always cancels the task, so the retain is always released.
        let delivery = SocketQueueWork(queue: queue) {
            guard !self.finished, self.index == attempt else { return }
            for completion in entry.completions { completion() }
            self.index += 1
            self.sendNext()
        }
        let queue = self.queue
        let task = session.dataTask(with: entry.request) { _, _, _ in
            queue.socketAsync { delivery.run() }
        }
        task.resume()
        queue.socketAsyncAfter(deadline: .now() + timeout) { [weak task] in
            guard !self.finished, self.index == attempt else { return }
            task?.cancel()
            self.finish(cancelling: true)
        }
    }

    private func finish(cancelling: Bool) {
        guard !finished else { return }
        finished = true
        if cancelling { session.invalidateAndCancel() } else { session.finishTasksAndInvalidate() }
        // A write that never reached the wire still completes locally: the
        // callback reports the end of this attempt, not delivery.
        for entry in requests[index...] {
            for completion in entry.completions { completion() }
        }
    }
}

enum EngineError: Error {
    case canceled
}

/// JS shares prior WebSocket success across Engine.IO instances. Guard the
/// native counterpart because engines may run on different serial queues.
private final class SocketUpgradeMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var succeeded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
