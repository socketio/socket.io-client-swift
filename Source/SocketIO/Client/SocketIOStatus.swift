//
//  SocketIOStatus.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 8/14/15.
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

/// Represents state of a manager or client.
@objc
public enum SocketIOStatus : Int, CustomStringConvertible {
    // MARK: Cases

    /// The client/manager has never been connected. Or the client has been reset.
    case notConnected

    /// The client/manager was once connected, but not anymore.
    case disconnected

    /// The client/manager is in the process of connecting.
    case connecting

    /// The client/manager is currently connected.
    case connected

    // MARK: Properties

    /// - returns: True if this client/manager is connected/connecting to a server.
    public var active: Bool {
        return self == .connected || self == .connecting
    }

    public var description: String {
        switch self {
        case .connected:    return "connected"
        case .connecting:   return "connecting"
        case .disconnected: return "disconnected"
        case .notConnected: return "notConnected"
        }
    }
}
