//
//  SocketClientManager.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 6/11/16.
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

/**
 Experimental socket manager.

 API subject to change.

 Can be used to persist sockets across ViewControllers.

 Sockets are strongly stored, so be sure to remove them once they are no
 longer needed.

 Example usage:
 ```
 let manager = SocketClientManager.sharedManager
 manager["room1"] = socket1
 manager["room2"] = socket2
 manager.removeSocket(socket: socket2)
 manager["room1"]?.emit("hello")
 ```
 */
open class SocketClientManager : NSObject {
    // MARK: Properties.

    /// The shared manager.
    open static let sharedManager = SocketClientManager()

    private var sockets = [String: SocketIOClient]()

    /// Gets a socket by its name.
    ///
    /// - returns: The socket, if one had the given name.
    open subscript(string: String) -> SocketIOClient? {
        get {
            return sockets[string]
        }

        set(socket) {
            sockets[string] = socket
        }
    }

    // MARK: Methods.

    /// Adds a socket.
    ///
    /// - parameter socket: The socket to add.
    /// - parameter labeledAs: The label for this socket.
    open func addSocket(_ socket: SocketIOClient, labeledAs label: String) {
        sockets[label] = socket
    }

    /// Removes a socket by a given name.
    ///
    /// - parameter withLabel: The label of the socket to remove.
    /// - returns: The socket for the given label, if one was present.
    @discardableResult
    open func removeSocket(withLabel label: String) -> SocketIOClient? {
        return sockets.removeValue(forKey: label)
    }

    /// Removes a socket.
    ///
    /// - parameter socket: The socket to remove.
    /// - returns: The socket if it was in the manager.
    @discardableResult
    open func removeSocket(_ socket: SocketIOClient) -> SocketIOClient? {
        var returnSocket: SocketIOClient?

        for (label, dictSocket) in sockets where dictSocket === socket {
            returnSocket = sockets.removeValue(forKey: label)
        }

        return returnSocket
    }

    /// Removes all the sockets in the manager.
    open func removeSockets() {
        sockets.removeAll()
    }
}
