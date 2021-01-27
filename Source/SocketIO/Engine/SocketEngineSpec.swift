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
import Starscream

/// Specifies a SocketEngine.
public protocol SocketEngineSpec: class {
    // MARK: Properties

    /// The client for this engine.
    var client: SocketEngineClient? { get set }

    /// `true` if this engine is closed.
    var closed: Bool { get }

    /// If `true` the engine will attempt to use WebSocket compression.
    var compress: Bool { get }

    /// `true` if this engine is connected. Connected means that the initial poll connect has succeeded.
    var connected: Bool { get }

    /// The connect parameters sent during a connect.
    var connectParams: [String: Any]? { get set }

    /// An array of HTTPCookies that are sent during the connection.
    var cookies: [HTTPCookie]? { get }

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

    /// The version of engine.io being used. Default is three.
    var version: SocketIOVersion { get }

    /// If `true`, then the engine is currently in WebSockets mode.
    @available(*, deprecated, message: "No longer needed, if we're not polling, then we must be doing websockets")
    var websocket: Bool { get }

    /// The WebSocket for this engine.
    var ws: WebSocket? { get }

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
    var engineIOParam: String {
        switch version {
        case .two:
            return "&EIO=3"
        case .three:
            return "&EIO=4"
        }
    }

    var urlPollingWithSid: URL {
        var com = URLComponents(url: urlPolling, resolvingAgainstBaseURL: false)!
        com.percentEncodedQuery = com.percentEncodedQuery! + "&sid=\(sid.urlEncode()!)"

        if !com.percentEncodedQuery!.contains("EIO") {
            com.percentEncodedQuery = com.percentEncodedQuery! + engineIOParam
        }

        return com.url!
    }

    var urlWebSocketWithSid: URL {
        var com = URLComponents(url: urlWebSocket, resolvingAgainstBaseURL: false)!
        com.percentEncodedQuery = com.percentEncodedQuery! + (sid == "" ? "" : "&sid=\(sid.urlEncode()!)")

        if !com.percentEncodedQuery!.contains("EIO") {
            com.percentEncodedQuery = com.percentEncodedQuery! + engineIOParam
        }


        return com.url!
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
        let prefixB64 = version.rawValue >= 3 ? "b" : "b4"

        if polling {
            return .right(prefixB64 + data.base64EncodedString(options: Data.Base64EncodingOptions(rawValue: 0)))
        } else {
            return .left(version.rawValue >= 3 ? data : Data([0x4]) + data)
        }
    }

    /// Send an engine message (4)
    func send(_ msg: String, withData datas: [Data], completion: (() -> ())? = nil) {
        write(msg, withType: .message, withData: datas, completion: completion)
    }
}
