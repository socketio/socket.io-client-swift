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
#if !os(Linux)
import StarscreamSocketIO
#else
import WebSockets
import Sockets
import TLS
#endif

/// Protocol that is used to implement socket.io WebSocket support
public protocol SocketEngineWebsocket : SocketEngineSpec, WebSocketDelegate {
    /// Called when a successful WebSocket connection is made.
    func handleWSConnect()

    /// Called when the WebSocket disconnects.
    func handleWSDisconnect(error: NSError?)

    /// Sends an engine.io message through the WebSocket transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    func sendWebSocketMessage(_ str: String, withType type: SocketEnginePacketType, withData datas: [Data])
}

// WebSocket methods
extension SocketEngineWebsocket {
    #if os(Linux)
    func attachWebSocketHandlers() {
        ws?.onText = {[weak self] ws, text in
            guard let this = self else { return }

            this.parseEngineMessage(text)
        }

        ws?.onBinary = {[weak self] ws, bin in
            guard let this = self else { return }

            this.parseEngineData(Data(bytes: bin))
        }

        ws?.onClose = {[weak self] _, _, reason, clean in
            guard let this = self else { return }

            this.handleWSDisconnect(error: nil)
        }
    }
    #endif

    func createWebSocketAndConnect() {
        #if !os(Linux)
        ws?.delegate = nil // TODO this seems a bit defensive, is this really needed?
        ws = WebSocket(url: urlWebSocketWithSid)

        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            for (key, value) in headers {
                ws?.headers[key] = value
            }
        }

        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                ws?.headers[headerName] = value
            }
        }

        ws?.callbackQueue = engineQueue
        ws?.enableCompression = compress
        ws?.delegate = self
        ws?.disableSSLCertValidation = selfSigned
        ws?.security = security

        ws?.connect()
        #else
        let url = urlWebSocketWithSid
        do {
            let socket = try TCPInternetSocket(scheme: url.scheme ?? "http",
                                               hostname: url.host ?? "localhost",
                                               port: Port(url.port ?? 80))
            let stream = secure ? try TLS.InternetSocket(socket, TLS.Context(.client)) : socket
            try WebSocket.background(to: connectURL, using: stream) {[weak self] ws in
                guard let this = self else { return }

                this.ws = ws

                this.attachWebSocketHandlers()
                this.handleWSConnect()
            }
        } catch {
            DefaultSocketLogger.Logger.error("Error connecting socket", type: "SocketEngineWebsocket")
        }
        #endif
    }

    func probeWebSocket() {
        if ws?.isConnected ?? false {
            sendWebSocketMessage("probe", withType: .ping, withData: [])
        }
    }

    /// Sends an engine.io message through the WebSocket transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    public func sendWebSocketMessage(_ str: String, withType type: SocketEnginePacketType, withData datas: [Data]) {
        DefaultSocketLogger.Logger.log("Sending ws: %@ as type: %@", type: "SocketEngine", args: str, type.rawValue)

        ws?.write(string: "\(type.rawValue)\(str)")

        for data in datas {
            if case let .left(bin) = createBinaryDataForSend(using: data) {
                ws?.write(data: bin)
            }
        }
    }

    // MARK: Starscream delegate methods

    #if !os(Linux)
    /// Delegate method for when a message is received.
    public func websocketDidReceiveMessage(socket: WebSocket, text: String) {
        parseEngineMessage(text)
    }

    /// Delegate method for when binary is received.
    public func websocketDidReceiveData(socket: WebSocket, data: Data) {
        parseEngineData(data)
    }
    #endif
}

#if os(Linux)
/// SSLSecurity does nothing on Linux.
public final class SSLSecurity { }

extension WebSocket {
    var isConnected: Bool {
        return state == .open
    }
}
#endif
