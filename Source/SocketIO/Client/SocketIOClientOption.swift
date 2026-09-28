//
//  SocketIOClientOption .swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/17/15.
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

import Foundation

protocol ClientOption : CustomStringConvertible, Equatable {
    func getSocketIOOptionValue() -> Any
}

/// Native Engine.IO transports, in connection-attempt order.
public enum SocketTransport: String, Sendable {
    case polling
    case websocket
}

/// The options for a client.
public enum SocketIOClientOption : ClientOption {
    /// The default timeout in seconds used when waiting for an acknowledgement
    /// from `emit(_:_:ack:)` / `emit(_:with:ack:)`. `nil` (unset) means no
    /// default — a plain ack that never times out. JS-aligned with the
    /// `ackTimeout` (milliseconds) option in `socket.io-client/lib/socket.ts`.
    case ackTimeout(Double)

    /// Whether the manager should automatically call `connect()` at the end of `init`.
    /// Default `false` to preserve existing behavior. JS `Manager` defaults to `true`;
    /// Swift inverts the default. When `true`, the default socket and sockets
    /// created later via `manager.socket(forNamespace:)` connect automatically,
    /// matching JS `Manager.socket()`. When `false`, each socket requires connect().
    /// **Note:** when `true`, engine I/O begins before `SocketManager.init` returns.
    /// Listener attachment on `defaultSocket` happens AFTER init in user code; events
    /// fire asynchronously on the configured `handleQueue` so they do reach attached
    /// listeners, but be aware of the ordering. JS-aligned with `Manager` constructor.
    case autoConnect(Bool)

    /// How many times an emit is re-sent when the server does not acknowledge
    /// it in time, JS-aligned with the `retries` option in
    /// `socket.io-client/lib/socket.ts`. Default `0` (retries disabled).
    ///
    /// When set, every event emit (plain, err-first ack, and
    /// `timeout(after:).emit`) goes through an ordered queue: each attempt
    /// waits `ackTimeout` (or the per-emit `timeout(after:)`) for the ack and
    /// is re-sent on failure until the budget is exhausted, in strict queue
    /// order. The final ack callback then fires with `SocketAckError.timeout`.
    ///
    /// Plain `emit` / `send` calls without a user acknowledgement callback require
    /// a finite, non-negative `ackTimeout` when retries are enabled. Otherwise
    /// the emit is rejected before queueing or sending, emits `.error` with
    /// `[eventName, items, NSError]` (domain `SocketIO.Emit`, code `2`), and invokes
    /// its local completion asynchronously, if provided. Zero is a valid timeout.
    /// Explicit acknowledgement APIs retain their existing no-timeout behavior.
    /// The server must acknowledge retried events even without a user callback.
    case retries(Int)

    /// A dictionary of GET parameters that will be included in the connect url.
    case connectParams([String: Any])

    /// Seconds the engine.io handshake may take before the attempt is failed with `.connectError("timeout")`
    /// and the engine is closed. Default `20`, JS-aligned with `Manager`'s `timeout` option
    /// (`socket.io-client/lib/manager.ts`). `.infinity` disables the timeout.
    case connectTimeout(Double)

    /// Maximum seconds for each polling HTTP request (handshake, GET and POST).
    /// Must be finite and greater than zero. Also limits the total transfer duration.
    /// Omitted: retain Foundation defaults (60 seconds idle, 7 days total).
    /// Unlike JavaScript's milliseconds, this value uses seconds. Does not affect WebSocket.
    case requestTimeout(Double)

    /// An array of cookies that will be sent during the initial connection.
    case cookies([HTTPCookie])

    /// Accept and resend server cookies in an isolated, engine-owned cookie jar.
    /// Default false, like JS withCredentials. Explicit cookies/headers remain explicit.
    case withCredentials(Bool)

    /// Encode binary WebSocket messages as Engine.IO base64 text. Polling always does so.
    case forceBase64(Bool)

    /// Append a trailing slash to the transport path. Default true, like JS.
    case addTrailingSlash(Bool)

    /// Any extra HTTP headers that should be sent during the initial connection.
    case extraHeaders([String: String])

    /// If passed `true`, will cause the client to always create a new engine. Useful for debugging,
    /// or when you want to be sure no state from previous engines is being carried over.
    case forceNew(Bool)

    /// Ordered initial transport candidates. Defaults to polling then WebSocket.
    case transports([SocketTransport])

    /// Try the next configured transport if the initial handshake fails.
    case tryAllTransports(Bool)

    /// Start with WebSocket after a previously successful WebSocket connection.
    case rememberUpgrade(Bool)

    /// If passed `true`, the only transport that will be used will be HTTP long-polling.
    case forcePolling(Bool)

    /// If passed `true`, the only transport that will be used will be WebSockets.
    case forceWebsockets(Bool)

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    ///
    /// **This should be a serial queue! Concurrent queues are not supported and might cause crashes and races**.
    case handleQueue(DispatchQueue)

    /// If passed `true`, the client will log debug information. This should be turned off in production code.
    case log(Bool)

    /// Used to pass in a custom logger.
    case logger(SocketLogger)

    /// A custom path to socket.io. Only use this if the socket.io server is configured to look for this path.
    case path(String)

    /// If passed `false`, the client will not reconnect when it loses connection. Useful if you want full control
    /// over when reconnects happen.
    case reconnects(Bool)

    /// The number of times to try and reconnect before giving up. Pass `-1` to [never give up](https://www.youtube.com/watch?v=dQw4w9WgXcQ).
    case reconnectAttempts(Int)

    /// The minimum number of seconds to wait before reconnect attempts.
    case reconnectWait(Int)

    /// The maximum number of seconds to wait before reconnect attempts.
    case reconnectWaitMax(Int)

    /// The randomization factor for calculating reconnect jitter.
    case randomizationFactor(Double)

    /// Set `true` if your server is using secure transports.
    case secure(Bool)

    /// Whether to add a cache-busting timestamp query parameter with each
    /// transport request. `nil` (default, JS `timestampRequests` unset):
    /// polling requests carry it, WebSocket URLs do not. `true`: both carry
    /// it. `false`: neither does. JS-aligned with `timestampRequests` in
    /// engine.io-client (`Polling.uri()` vs `WS.uri()`).
    case timestampRequests(Bool)

    /// The query parameter name used for the cache-busting timestamp.
    /// Default `"t"`. JS-aligned with `timestampParam` in engine.io-client.
    case timestampParam(String)

    /// Shared native TLS policy for polling and WebSocket. Normal system trust is the default.
    case security(SocketTLSConfiguration)

    /// Client identity for mutual TLS, shared by polling and WebSocket.
    /// Create with URLCredential(identity:certificates:persistence:). Sent only
    /// to the configured HTTPS/WSS host and port; server trust still applies.
    case clientCertificate(URLCredential)

    /// Forwards authentication (except server trust and configured client certificates),
    /// redirect, lifecycle and metrics events.
    /// Server trust is always controlled by `security`, never by this delegate.
    case sessionDelegate(URLSessionDelegate)

    /// Native incoming-message and outgoing-queue limits.
    case webSocketOptions(SocketWebSocketOptions)

    /// Complete incoming packet, attachment-count and nesting limits for all transports.
    case parserOptions(SocketParserOptions)

    /// Pipeline-wide buffer/queue limits: send buffer, retry queue, recovery
    /// replay, engine-to-manager handoff, polling response body and binary
    /// reconstruction deadline. Everything is unlimited by default, which is
    /// the JavaScript behaviour.
    case bufferLimits(SocketBufferLimits)

    /// Carries a dictionary conversion failure to connection validation. No
    /// network request is started when this option is present.
    case invalidConfiguration(String)

    // MARK: Properties

    /// The description of this option.
    public var description: String {
        let description: String

        switch self {
        case .webSocketOptions:
            description = "webSocketOptions"
        case .parserOptions:
            description = "parserOptions"
        case .bufferLimits:
            description = "bufferLimits"
        case .invalidConfiguration:
            description = "invalidConfiguration"
        case .ackTimeout:
            description = "ackTimeout"
        case .autoConnect:
            description = "autoConnect"
        case .retries:
            description = "retries"
        case .connectParams:
            description = "connectParams"
        case .requestTimeout:
            description = "requestTimeout"
        case .connectTimeout:
            description = "connectTimeout"
        case .withCredentials:
            description = "withCredentials"
        case .forceBase64:
            description = "forceBase64"
        case .addTrailingSlash:
            description = "addTrailingSlash"
        case .cookies:
            description = "cookies"
        case .extraHeaders:
            description = "extraHeaders"
        case .forceNew:
            description = "forceNew"
        case .transports:
            description = "transports"
        case .tryAllTransports:
            description = "tryAllTransports"
        case .rememberUpgrade:
            description = "rememberUpgrade"
        case .forcePolling:
            description = "forcePolling"
        case .forceWebsockets:
            description = "forceWebsockets"
        case .handleQueue:
            description = "handleQueue"
        case .log:
            description = "log"
        case .logger:
            description = "logger"
        case .path:
            description = "path"
        case .reconnects:
            description = "reconnects"
        case .reconnectAttempts:
            description = "reconnectAttempts"
        case .reconnectWait:
            description = "reconnectWait"
        case .reconnectWaitMax:
            description = "reconnectWaitMax"
        case .randomizationFactor:
            description = "randomizationFactor"
        case .secure:
            description = "secure"
        case .timestampRequests:
            description = "timestampRequests"
        case .timestampParam:
            description = "timestampParam"
        case .clientCertificate:
            description = "clientCertificate"
        case .security:
            description = "security"
        case .sessionDelegate:
            description = "sessionDelegate"
        }

        return description
    }

    func getSocketIOOptionValue() -> Any {
        let value: Any

        switch self {
        case let .webSocketOptions(options):
            value = options
        case let .parserOptions(options):
            value = options
        case let .bufferLimits(limits):
            value = limits
        case let .invalidConfiguration(reason):
            value = reason
        case let .ackTimeout(timeout):
            value = timeout
        case let .autoConnect(autoConnect):
            value = autoConnect
        case let .connectParams(params):
            value = params
        case let .retries(count):
            value = count
        case let .requestTimeout(timeout):
            value = timeout
        case let .connectTimeout(timeout):
            value = timeout
        case let .withCredentials(enabled):
            value = enabled
        case let .forceBase64(enabled):
            value = enabled
        case let .addTrailingSlash(enabled):
            value = enabled
        case let .cookies(cookies):
            value = cookies
        case let .extraHeaders(headers):
            value = headers
        case let .forceNew(force):
            value = force
        case let .transports(transports):
            value = transports
        case let .tryAllTransports(enabled):
            value = enabled
        case let .rememberUpgrade(enabled):
            value = enabled
        case let .forcePolling(force):
            value = force
        case let .forceWebsockets(force):
            value = force
        case let .handleQueue(queue):
            value = queue
        case let .log(log):
            value = log
        case let .logger(logger):
            value = logger
        case let .path(path):
            value = path
        case let .reconnects(reconnects):
            value = reconnects
        case let .reconnectAttempts(attempts):
            value = attempts
        case let .reconnectWait(wait):
            value = wait
        case let .reconnectWaitMax(wait):
            value = wait
        case let .randomizationFactor(factor):
            value = factor
        case let .secure(secure):
            value = secure
        case let .timestampRequests(timestampRequests):
            value = timestampRequests
        case let .timestampParam(timestampParam):
            value = timestampParam
        case let .clientCertificate(credential):
            value = credential
        case let .security(security):
            value = security
        case let .sessionDelegate(delegate):
            value = delegate
        }

        return value
    }

    // MARK: Operators

    /// Compares whether two options are the same.
    ///
    /// - parameter lhs: Left operand to compare.
    /// - parameter rhs: Right operand to compare.
    /// - returns: `true` if the two are the same option.
    public static func ==(lhs: SocketIOClientOption, rhs: SocketIOClientOption) -> Bool {
        return lhs.description == rhs.description
    }

}
