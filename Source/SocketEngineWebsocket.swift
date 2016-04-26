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

/// Protocol that is used to implement socket.io WebSocket support
public protocol SocketEngineWebsocket : SocketEngineSpec, WebSocketDelegate {
    func sendWebSocketMessage(str: String, withType type: SocketEnginePacketType, withData datas: [NSData])
}

// WebSocket methods
extension SocketEngineWebsocket {
    func probeWebSocket() {
        if ws?.isConnected ?? false {
            sendWebSocketMessage("probe", withType: .Ping, withData: [])
        }
    }
    
    /// Send message on WebSockets
    /// Only call on emitQueue
    public func sendWebSocketMessage(str: String, withType type: SocketEnginePacketType, withData datas: [NSData]) {
            DefaultSocketLogger.Logger.log("Sending ws: %@ as type: %@", type: "SocketEngine", args: str, type.rawValue)
            
            ws?.writeString("\(type.rawValue)\(str)")
            
            for data in datas {
                if case let .Left(bin) = createBinaryDataForSend(data) {
                    ws?.writeData(bin)
                }
            }
    }
    
    public func websocketDidReceiveMessage(socket: WebSocket, text: String) {
        parseEngineMessage(text, fromPolling: false)
    }
    
    public func websocketDidReceiveData(socket: WebSocket, data: NSData) {
        parseEngineData(data)
    }
}
