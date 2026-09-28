//
//  SocketEngineSpec.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/7/15.
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
//

import Foundation

/// Specifies a SocketEngine.
public protocol SocketEngineSpec: AnyObject {
    // MARK: Properties

    /// The client for this engine.
    var client: SocketEngineClient? { get set }

    /// `true` if this engine is closed.
    var closed: Bool { get }

    /// `true` if this engine is connected. Connected means that the initial poll connect has succeeded.
    var connected: Bool { get }

    /// Whether the underlying transport can accept a write right now without
    /// queuing. Used by Phase 7 volatile-emit gate (`socket.volatile.emit(...)`
    /// drops when this is `false`). JS-aligned per `socket.io-client/lib/socket.ts`
    /// `emit()` body which gates `discardPacket = volatile && !transport.writable`.
    /// Default impl returns `false` (fail-safe — any conformer that doesn't
    /// override drops all volatile packets, which is safer than incorrectly
    /// admitting them).
    var writable: Bool { get }

    /// Whether the server heartbeat deadline expired, even if its timer was delayed.
    /// Reading a native engine schedules its once-only timeout close when necessary.
    var hasPingExpired: Bool { get }

    /// The connect parameters sent during a connect.
    var connectParams: [String: Any]? { get set }

    /// An array of HTTPCookies that are sent during the connection.
    var cookies: [HTTPCookie]? { get }

    /// Whether binary WebSocket payloads must use Engine.IO base64 text.
    var forceBase64: Bool { get }

    /// The queue that all engine actions take place on.
    var engineQueue: DispatchQueue { get }

    /// A dictionary of extra http headers that will be set during connection.
    var extraHeaders: [String: String]? { get set }

    /// When `true`, the engine is in the process of switching to WebSockets.
    var fastUpgrade: Bool { get }

    /// When `true`, the engine will only use HTTP long-polling as a transport.
    var forcePolling: Bool { get }

    /// When `true`, the engine will only use WebSockets as a transport.
    var forceWebsockets: Bool { get }

    /// If `true`, the engine is currently in HTTP long-polling mode.
    var polling: Bool { get }

    /// If `true`, the engine is currently seeing whether it can upgrade to WebSockets.
    var probing: Bool { get }

    /// The session id for this engine.
    var sid: String { get }

    /// The path to engine.io.
    var socketPath: String { get }

    /// The url for polling.
    var urlPolling: URL { get }

    /// The url for WebSockets.
    var urlWebSocket: URL { get }


    /// Whether polling (and WebSocket) requests carry a cache-busting
    /// timestamp query parameter. `nil` is the JS default (`timestampRequests`
    /// unset): polling requests carry it, WebSocket URLs do not. `true`:
    /// both carry it. `false`: neither does.
    var timestampRequests: Bool? { get }

    /// The query parameter name used for the cache-busting timestamp.
    /// Default `"t"`, JS-aligned with `timestampParam` in engine.io-client.
    var timestampParam: String { get }


    // MARK: Initializers

    /// Creates a new engine.
    ///
    /// - parameter client: The client for this engine.
    /// - parameter url: The url for this engine.
    /// - parameter options: The options for this engine.
    init(client: SocketEngineClient, url: URL, options: [String: Any]?)

    // MARK: Methods

    /// Starts the connection to the server.
    func connect()

    /// Called when an error happens during execution. Causes a disconnection.
    func didError(reason: String)

    /// Structured native details, with a source-compatible fallback for custom engines.
    func didError(reason: String, error: SocketTransportError)

    /// Disconnects from the server.
    ///
    /// - parameter reason: The reason for the disconnection. This is communicated up to the client.
    func disconnect(reason: String)

    /// Called to switch from HTTP long-polling to WebSockets. After calling this method the engine will be in
    /// WebSocket mode.
    ///
    /// **You shouldn't call this directly**
    func doFastUpgrade()

    /// Causes any packets that were waiting for POSTing to be sent through the WebSocket. This happens because when
    /// the engine is attempting to upgrade to WebSocket it does not do any POSTing.
    ///
    /// **You shouldn't call this directly**
    func flushWaitingForPostToWebSocket()

    /// Parses raw binary received from engine.io.
    ///
    /// - parameter data: The data to parse.
    func parseEngineData(_ data: Data)

    /// Parses a raw engine.io packet.
    ///
    /// - parameter message: The message to parse.
    func parseEngineMessage(_ message: String)

    /// Writes a message to engine.io, independent of transport.
    ///
    /// - parameter msg: The message to send.
    /// - parameter type: The type of this message.
    /// - parameter data: Any data that this message has.
    /// - parameter completion: Callback called on transport write completion.
    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> ())?)
}

extension SocketEngineSpec {
    /// Existing custom engines retain their historical binary transport behaviour.
    public var forceBase64: Bool { false }
    public func didError(reason: String, error: SocketTransportError) { didError(reason: reason) }

    /// Default fail-safe — conformers that don't override drop all volatile
    /// packets. See protocol declaration for rationale.
    public var writable: Bool { return false }
    public var hasPingExpired: Bool { return false }

    /// JS default: `timestampRequests` unset, so polling requests are stamped
    /// and WebSocket URLs are not.
    public var timestampRequests: Bool? { return nil }

    /// JS default parameter name (`timestampParam: "t"` in engine.io-client).
    public var timestampParam: String { return "t" }

    /// A unique-per-request, URL-safe cache-busting value: a monotonically
    /// increasing base-36 millisecond timestamp plus a short random suffix so
    /// two requests within the same millisecond still differ.
    func cacheBustingValue() -> String {
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = UInt64.random(in: 0..<1_679_616) // 36^4, up to 4 chars

        return String(millis, radix: 36) + String(rand, radix: 36)
    }

    /// Appends the cache-busting parameter to an already-built engine URL.
    /// Evaluated per call, so every request gets a fresh value.
    func urlByAppendingCacheBuster(to url: URL) -> URL {
        var com = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        com.percentEncodedQuery = (com.percentEncodedQuery ?? "") + "&\(timestampParam.urlEncode()!)=\(cacheBustingValue())"

        return com.url!
    }

    var engineIOParam: String { "&EIO=4" }

    /// The first polling GET (no `sid` yet — used by `_connect`); every later
    /// poll and POST goes through `urlPollingWithSid`. Both carry the
    /// cache-busting parameter unless `timestampRequests` is `false`.
    /// JS-aligned with `Polling.uri()` in engine.io-client.
    var urlPollingHandshake: URL {
        guard timestampRequests != false else { return urlPolling }

        return urlByAppendingCacheBuster(to: urlPolling)
    }

    var urlPollingWithSid: URL {
        var com = URLComponents(url: urlPolling, resolvingAgainstBaseURL: false)!
        com.percentEncodedQuery = com.percentEncodedQuery! + "&sid=\(sid.urlEncode()!)"

        var query = (com.percentEncodedQueryItems ?? []).filter { $0.name.removingPercentEncoding != "EIO" }
        query.append(URLQueryItem(name: "EIO", value: "4"))
        com.percentEncodedQueryItems = query

        guard timestampRequests != false else { return com.url! }

        return urlByAppendingCacheBuster(to: com.url!)
    }

    var urlWebSocketWithSid: URL {
        var com = URLComponents(url: urlWebSocket, resolvingAgainstBaseURL: false)!
        com.percentEncodedQuery = com.percentEncodedQuery! + (sid == "" ? "" : "&sid=\(sid.urlEncode()!)")

        var query = (com.percentEncodedQueryItems ?? []).filter { $0.name.removingPercentEncoding != "EIO" }
        query.append(URLQueryItem(name: "EIO", value: "4"))
        com.percentEncodedQueryItems = query

        // JS-aligned with `WS.uri()` in engine.io-client: the WebSocket URL
        // is only stamped when `timestampRequests` is explicitly `true`.
        guard timestampRequests == true else { return com.url! }

        return urlByAppendingCacheBuster(to: com.url!)
    }

    func addHeaders(to req: inout URLRequest, includingCookies additionalCookies: [HTTPCookie]? = nil) {
        var cookiesToAdd: [HTTPCookie] = cookies ?? []
        cookiesToAdd += additionalCookies ?? []

        if !cookiesToAdd.isEmpty {
            req.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookiesToAdd)
        }

        if let extraHeaders = extraHeaders {
            for (headerName, value) in extraHeaders {
                req.setValue(value, forHTTPHeaderField: headerName)
            }
        }
    }

    func createBinaryDataForSend(using data: Data) -> Either<Data, String> {
        switch SocketEnginePacketCodec.encode(.init(type: .message, data: .binary(data)), supportsBinary: !polling && !forceBase64) {
        case .text(let value): return .right(value)
        case .binary(let value): return .left(value)
        }
    }

    /// Send an engine message (4)
    func send(_ msg: String, withData datas: [Data], completion: (() -> ())? = nil) {
        write(msg, withType: .message, withData: datas, completion: completion)
    }
}
