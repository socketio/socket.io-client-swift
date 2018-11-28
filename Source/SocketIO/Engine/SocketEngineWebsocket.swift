//
//  SocketEngineWebsocket.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/15/16.
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

/// Protocol that is used to implement socket.io WebSocket support
public protocol SocketEngineWebsocket : SocketEngineSpec {
    // MARK: Methods

    /// Sends an engine.io message through the WebSocket transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    /// - parameter completion: Callback called on transport write completion.
    func sendWebSocketMessage(_ str: String,
                              withType type: SocketEnginePacketType,
                              withData datas: [Data],
                              completion: (() -> ())?)
}

// WebSocket methods
extension SocketEngineWebsocket {
    func probeWebSocket() {
        if ws?.isConnected ?? false {
            sendWebSocketMessage("probe", withType: .ping, withData: [], completion: nil)
        }
    }

    /// Sends an engine.io message through the WebSocket transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    /// - parameter completion: Callback called on transport write completion.
    public func sendWebSocketMessage(_ str: String,
                                     withType type: SocketEnginePacketType,
                                     withData datas: [Data],
                                     completion: (() -> ())?
    ) {
        DefaultSocketLogger.Logger.log("Sending ws: \(str) as type: \(type.rawValue)", type: "SocketEngineWebSocket")

        ws?.write(string: "\(type.rawValue)\(str)")

        for data in datas {
            if case let .left(bin) = createBinaryDataForSend(using: data) {
                ws?.write(data: bin, completion: completion)
            }
        }
    }
}
