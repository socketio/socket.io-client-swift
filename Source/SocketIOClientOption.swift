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

/// The options for a client.
public enum SocketIOClientOption : ClientOption {
    /// A dictionary of GET parameters that will be included in the connect url.
    case connectParams([String: Any])

    /// An array of cookies that will be sent during the initial connection.
    case cookies([HTTPCookie])

    /// Deprecated
    @available(*, deprecated, message: "No longer needed in socket.io 2.0+")
    case doubleEncodeUTF8(Bool)

    /// Any extra HTTP headers that should be sent during the initial connection.
    case extraHeaders([String: String])

    /// If passed `true`, will cause the client to always create a new engine. Useful for debugging,
    /// or when you want to be sure no state from previous engines is being carried over.
    case forceNew(Bool)

    /// If passed `true`, the only transport that will be used will be HTTP long-polling.
    case forcePolling(Bool)

    /// If passed `true`, the only transport that will be used will be WebSockets.
    case forceWebsockets(Bool)

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    case handleQueue(DispatchQueue)

    /// If passed `true`, the client will log debug information. This should be turned off in production code.
    case log(Bool)

    /// Used to pass in a custom logger.
    case logger(SocketLogger)

    /// The namespace that this client should connect to. Can be changed during use using the `joinNamespace`
    /// and `leaveNamespace` methods on `SocketIOClient`.
    case nsp(String)

    /// A custom path to socket.io. Only use this if the socket.io server is configured to look for this path.
    case path(String)

    /// If passed `false`, the client will not reconnect when it loses connection. Useful if you want full control
    /// over when reconnects happen.
    case reconnects(Bool)

    /// The number of times to try and reconnect before giving up. Pass `-1` to [never give up](https://www.youtube.com/watch?v=dQw4w9WgXcQ).
    case reconnectAttempts(Int)

    /// The number of seconds to wait before reconnect attempts.
    case reconnectWait(Int)

    /// Set `true` if your server is using secure transports.
    case secure(Bool)

    /// Allows you to set which certs are valid. Useful for SSL pinning.
    case security(SSLSecurity)

    /// If you're using a self-signed set. Only use for development.
    case selfSigned(Bool)

    /// Sets an NSURLSessionDelegate for the underlying engine. Useful if you need to handle self-signed certs.
    case sessionDelegate(URLSessionDelegate)

    /// If passed `true`, the WebSocket transport will try and use voip logic to keep network connections open in
    /// the background. **This option is experimental as socket.io shouldn't be used for background communication.**
    case voipEnabled(Bool)

    // MARK: Properties

    /// The description of this option.
    public var description: String {
        let description: String

        switch self {
        case .connectParams:
            description = "connectParams"
        case .cookies:
            description = "cookies"
        case .doubleEncodeUTF8:
            description = "doubleEncodeUTF8"
        case .extraHeaders:
            description = "extraHeaders"
        case .forceNew:
            description = "forceNew"
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
        case .nsp:
            description = "nsp"
        case .path:
            description = "path"
        case .reconnects:
            description = "reconnects"
        case .reconnectAttempts:
            description = "reconnectAttempts"
        case .reconnectWait:
            description = "reconnectWait"
        case .secure:
            description = "secure"
        case .selfSigned:
            description = "selfSigned"
        case .security:
            description = "security"
        case .sessionDelegate:
            description = "sessionDelegate"
        case .voipEnabled:
            description = "voipEnabled"
        }

        return description
    }

    func getSocketIOOptionValue() -> Any {
        let value: Any

        switch self {
        case let .connectParams(params):
            value = params
        case let .cookies(cookies):
            value = cookies
        case let .doubleEncodeUTF8(encode):
            value = encode
        case let .extraHeaders(headers):
            value = headers
        case let .forceNew(force):
            value = force
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
        case let .nsp(nsp):
            value = nsp
        case let .path(path):
            value = path
        case let .reconnects(reconnects):
            value = reconnects
        case let .reconnectAttempts(attempts):
            value = attempts
        case let .reconnectWait(wait):
            value = wait
        case let .secure(secure):
            value = secure
        case let .security(security):
            value = security
        case let .selfSigned(signed):
            value = signed
        case let .sessionDelegate(delegate):
            value = delegate
        case let .voipEnabled(enabled):
            value = enabled
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
