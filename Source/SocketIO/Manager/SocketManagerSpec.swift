//
// Created by Erik Little on 10/18/17.
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

// TODO Fix the types so that we aren't using concrete types

///
/// A manager for a socket.io connection.
///
/// A `SocketManagerSpec` is responsible for multiplexing multiple namespaces through a single `SocketEngineSpec`.
///
/// Example with `SocketManager`:
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
@objc
public protocol SocketManagerSpec : AnyObject, SocketEngineClient {
    // MARK: Properties

    /// Returns the socket associated with the default namespace ("/").
    var defaultSocket: SocketIOClient { get }

    /// The engine for this manager.
    var engine: SocketEngineSpec? { get set }

    /// If `true` then every time `connect` is called, a new engine will be created.
    var forceNew: Bool { get set }

    // TODO Per socket queues?
    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    var handleQueue: DispatchQueue { get set }

    /// The sockets in this manager indexed by namespace.
    var nsps: [String: SocketIOClient] { get set }

    /// If `true`, this manager will try and reconnect on any disconnects.
    var reconnects: Bool { get set }

    /// The number of seconds to wait before attempting to reconnect.
    var reconnectWait: Int { get set }

    /// The URL of the socket.io server.
    var socketURL: URL { get }

    /// The status of this manager.
    var status: SocketIOStatus { get }

    // MARK: Methods

    /// Connects the underlying transport.
    func connect()

    /// Connects a socket through this manager's engine.
    ///
    /// - parameter socket: The socket who we should connect through this manager.
    func connectSocket(_ socket: SocketIOClient)

    /// Called when the manager has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    func didDisconnect(reason: String)

    /// Disconnects the manager and all associated sockets.
    func disconnect()

    /// Disconnects the given socket.
    ///
    /// - parameter socket: The socket to disconnect.
    func disconnectSocket(_ socket: SocketIOClient)

    /// Disconnects the socket associated with `forNamespace`.
    ///
    /// - parameter nsp: The namespace to disconnect from.
    func disconnectSocket(forNamespace nsp: String)

    /// Sends an event to the server on all namespaces in this manager.
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The data to send with this event.
    func emitAll(_ event: String, withItems items: [Any])

    /// Tries to reconnect to the server.
    ///
    /// This will cause a `disconnect` event to be emitted, as well as an `reconnectAttempt` event.
    func reconnect()

    /// Removes the socket from the manager's control.
    /// After calling this method the socket should no longer be considered usable.
    ///
    /// - parameter socket: The socket to remove.
    /// - returns: The socket removed, if it was owned by the manager.
    @discardableResult
    func removeSocket(_ socket: SocketIOClient) -> SocketIOClient?

    /// Returns a `SocketIOClient` for the given namespace. This socket shares a transport with the manager.
    ///
    /// Calling multiple times returns the same socket.
    ///
    /// Sockets created from this method are retained by the manager.
    /// Call one of the `disconnectSocket` methods on the implementing class to remove the socket from manager control.
    /// Or call `SocketIOClient.disconnect()` on the client.
    ///
    /// - parameter nsp: The namespace for the socket.
    /// - returns: A `SocketIOClient` for the given namespace.
    func socket(forNamespace nsp: String) -> SocketIOClient
}
