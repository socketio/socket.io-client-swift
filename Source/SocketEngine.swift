//
//  SocketEngine.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/3/15.
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

public final class SocketEngine : NSObject, URLSessionDelegate, SocketEnginePollable, SocketEngineWebsocket {
    public let emitQueue = DispatchQueue(label: "com.socketio.engineEmitQueue", attributes: [])
    public let handleQueue = DispatchQueue(label: "com.socketio.engineHandleQueue", attributes: [])
    public let parseQueue = DispatchQueue(label: "com.socketio.engineParseQueue", attributes: [])

    public var connectParams: [String: Any]? {
        didSet {
            (urlPolling, urlWebSocket) = createURLs()
        }
    }

    public var postWait = [String]()
    public var waitingForPoll = false
    public var waitingForPost = false

    public private(set) var closed = false
    public private(set) var connected = false
    public private(set) var cookies: [HTTPCookie]?
    public private(set) var doubleEncodeUTF8 = false
    public private(set) var extraHeaders: [String: String]?
    public private(set) var fastUpgrade = false
    public private(set) var forcePolling = false
    public private(set) var forceWebsockets = false
    public private(set) var invalidated = false
    public private(set) var polling = true
    public private(set) var probing = false
    public private(set) var session: URLSession?
    public private(set) var sid = ""
    public private(set) var socketPath = "/engine.io/"
    public private(set) var urlPolling = URL(string: "http://localhost/")!
    public private(set) var urlWebSocket = URL(string: "http://localhost/")!
    public private(set) var websocket = false
    public private(set) var ws: WebSocket?

    public weak var client: SocketEngineClient?

    private weak var sessionDelegate: URLSessionDelegate?

    private let logType = "SocketEngine"
    private let url: URL

    private var pingInterval: Double?
    private var pingTimeout = 0.0 {
        didSet {
            pongsMissedMax = Int(pingTimeout / (pingInterval ?? 25))
        }
    }

    private var pongsMissed = 0
    private var pongsMissedMax = 0
    private var probeWait = ProbeWaitQueue()
    private var secure = false
    private var security: SSLSecurity?
    private var selfSigned = false
    private var voipEnabled = false

    public init(client: SocketEngineClient, url: URL, config: SocketIOClientConfiguration) {
        self.client = client
        self.url = url
        for option in config {
            switch option {
            case let .connectParams(params):
                connectParams = params
            case let .cookies(cookies):
                self.cookies = cookies
            case let .doubleEncodeUTF8(encode):
                doubleEncodeUTF8 = encode
            case let .extraHeaders(headers):
                extraHeaders = headers
            case let .sessionDelegate(delegate):
                sessionDelegate = delegate
            case let .forcePolling(force):
                forcePolling = force
            case let .forceWebsockets(force):
                forceWebsockets = force
            case let .path(path):
                socketPath = path
                
                if !socketPath.hasSuffix("/") {
                    socketPath += "/"
                }
            case let .voipEnabled(enable):
                voipEnabled = enable
            case let .secure(secure):
                self.secure = secure
            case let .selfSigned(selfSigned):
                self.selfSigned = selfSigned
            case let .security(security):
                self.security = security
            default:
                continue
            }
        }

        super.init()
        
        sessionDelegate = sessionDelegate ?? self
        
        (urlPolling, urlWebSocket) = createURLs()
    }
    
    public convenience init(client: SocketEngineClient, url: URL, options: NSDictionary?) {
        self.init(client: client, url: url, config: options?.toSocketConfiguration() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Engine is being released", type: logType)
        closed = true
        stopPolling()
    }

    private func checkAndHandleEngineError(_ msg: String) {
        do {
            let dict = try msg.toNSDictionary()
            guard let error = dict["message"] as? String else { return }
            
            /*
             0: Unknown transport
             1: Unknown sid
             2: Bad handshake request
             3: Bad request
             */
            didError(reason: error)
        } catch {
            client?.engineDidError(reason: "Got unknown error from server \(msg)")
        }
    }

    private func handleBase64(message: String) {
        // binary in base64 string
        let noPrefix = message[message.index(message.startIndex, offsetBy: 2)..<message.endIndex]
        
        if let data = NSData(base64Encoded: noPrefix, options: .ignoreUnknownCharacters) {
            client?.parseEngineBinaryData(data as Data)
        }
    }

    private func closeOutEngine(reason: String) {
        sid = ""
        closed = true
        invalidated = true
        connected = false

        ws?.disconnect()
        stopPolling()
        client?.engineDidClose(reason: reason)
    }

    /// Starts the connection to the server
    public func connect() {
        if connected {
            DefaultSocketLogger.Logger.error("Engine tried opening while connected. Assuming this was a reconnect", type: logType)
            disconnect(reason: "reconnect")
        }

        DefaultSocketLogger.Logger.log("Starting engine. Server: %@", type: logType, args: url)
        DefaultSocketLogger.Logger.log("Handshaking", type: logType)

        resetEngine()

        if forceWebsockets {
            polling = false
            websocket = true
            createWebsocketAndConnect()
            return
        }

        let reqPolling = NSMutableURLRequest(url: urlPolling)

        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            reqPolling.allHTTPHeaderFields = headers
        }

        if let extraHeaders = extraHeaders {
            for (headerName, value) in extraHeaders {
                reqPolling.setValue(value, forHTTPHeaderField: headerName)
            }
        }

        doLongPoll(for: reqPolling as URLRequest)
    }

    private func createURLs() -> (URL, URL) {
        if client == nil {
            return (URL(string: "http://localhost/")!, URL(string: "http://localhost/")!)
        }

        var urlPolling = URLComponents(string: url.absoluteString)!
        var urlWebSocket = URLComponents(string: url.absoluteString)!
        var queryString = ""
        
        urlWebSocket.path = socketPath
        urlPolling.path = socketPath

        if secure {
            urlPolling.scheme = "https"
            urlWebSocket.scheme = "wss"
        } else {
            urlPolling.scheme = "http"
            urlWebSocket.scheme = "ws"
        }

        if connectParams != nil {
            for (key, value) in connectParams! {
                let keyEsc   = key.urlEncode()!
                let valueEsc = "\(value)".urlEncode()!

                queryString += "&\(keyEsc)=\(valueEsc)"
            }
        }

        urlWebSocket.percentEncodedQuery = "transport=websocket" + queryString
        urlPolling.percentEncodedQuery = "transport=polling&b64=1" + queryString

        return (urlPolling.url!, urlWebSocket.url!)
    }

    private func createWebsocketAndConnect() {
        ws = WebSocket(url: urlWebSocketWithSid as URL)

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

        ws?.callbackQueue = handleQueue
        ws?.voipEnabled = voipEnabled
        ws?.delegate = self
        ws?.disableSSLCertValidation = selfSigned
        ws?.security = security

        ws?.connect()
    }

    public func didError(reason: String) {
        DefaultSocketLogger.Logger.error("%@", type: logType, args: reason)
        client?.engineDidError(reason: reason)
        disconnect(reason: reason)
    }

    public func disconnect(reason: String) {
        guard connected else { return closeOutEngine(reason: reason) }

        DefaultSocketLogger.Logger.log("Engine is being closed.", type: logType)

        if closed {
            return closeOutEngine(reason: reason)
        }

        if websocket {
            sendWebSocketMessage("", withType: .close, withData: [])
            closeOutEngine(reason: reason)
        } else {
            disconnectPolling(reason: reason)
        }
    }

    // We need to take special care when we're polling that we send it ASAP
    // Also make sure we're on the emitQueue since we're touching postWait
    private func disconnectPolling(reason: String) {
        emitQueue.sync {
            self.postWait.append(String(SocketEnginePacketType.close.rawValue))
            let req = self.createRequestForPostWithPostWait()
            self.doRequest(for: req) {_, _, _ in }
            self.closeOutEngine(reason: reason)
        }
    }

    public func doFastUpgrade() {
        if waitingForPoll {
            DefaultSocketLogger.Logger.error("Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", type: logType)
        }

        sendWebSocketMessage("", withType: .upgrade, withData: [])
        websocket = true
        polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }

    private func flushProbeWait() {
        DefaultSocketLogger.Logger.log("Flushing probe wait", type: logType)

        emitQueue.async {
            for waiter in self.probeWait {
                self.write(waiter.msg, withType: waiter.type, withData: waiter.data)
            }

            self.probeWait.removeAll(keepingCapacity: false)

            if self.postWait.count != 0 {
                self.flushWaitingForPostToWebSocket()
            }
        }
    }

    // We had packets waiting for send when we upgraded
    // Send them raw
    public func flushWaitingForPostToWebSocket() {
        guard let ws = self.ws else { return }

        for msg in postWait {
            ws.write(string: msg)
        }

        postWait.removeAll(keepingCapacity: false)
    }

    private func handleClose(_ reason: String) {
        client?.engineDidClose(reason: reason)
    }

    private func handleMessage(_ message: String) {
        client?.parseEngineMessage(message)
    }

    private func handleNOOP() {
        doPoll()
    }
    
    private func handleOpen(openData: String) {
        guard let json = try? openData.toNSDictionary() else {
            didError(reason: "Error parsing open packet")
            
            return
        }
        
        guard let sid = json["sid"] as? String else {
            didError(reason: "Open packet contained no sid")
            
            return
        }
        
        let upgradeWs: Bool
        
        self.sid = sid
        connected = true
        pongsMissed = 0
        
        if let upgrades = json["upgrades"] as? [String] {
            upgradeWs = upgrades.contains("websocket")
        } else {
            upgradeWs = false
        }
        
        if let pingInterval = json["pingInterval"] as? Double, let pingTimeout = json["pingTimeout"] as? Double {
            self.pingInterval = pingInterval / 1000.0
            self.pingTimeout = pingTimeout / 1000.0
        }
        
        if !forcePolling && !forceWebsockets && upgradeWs {
            createWebsocketAndConnect()
        }
        
        sendPing()
        
        if !forceWebsockets {
            doPoll()
        }
        
        client?.engineDidOpen(reason: "Connect")
    }

    private func handlePong(with message: String) {
        pongsMissed = 0

        // We should upgrade
        if message == "3probe" {
            upgradeTransport()
        }
    }

    public func parseEngineData(_ data: Data) {
        DefaultSocketLogger.Logger.log("Got binary data: %@", type: "SocketEngine", args: data)

        client?.parseEngineBinaryData(data.subdata(in: 1..<data.endIndex))
    }

    public func parseEngineMessage(_ message: String, fromPolling: Bool) {
        DefaultSocketLogger.Logger.log("Got message: %@", type: logType, args: message)

        let reader = SocketStringReader(message: message)
        let fixedString: String
        
        if message.hasPrefix("b4") {
            return handleBase64(message: message)
        }

        guard let type = SocketEnginePacketType(rawValue: Int(reader.currentCharacter) ?? -1) else {
            checkAndHandleEngineError(message)
            
            return
        }

        if fromPolling && type != .noop && doubleEncodeUTF8 {
            fixedString = fixDoubleUTF8(message)
        } else {
            fixedString = message
        }

        switch type {
        case .message:
            handleMessage(String(fixedString.characters.dropFirst()))
        case .noop:
            handleNOOP()
        case .pong:
            handlePong(with: fixedString)
        case .open:
            handleOpen(openData: String(fixedString.characters.dropFirst()))
        case .close:
            handleClose(fixedString)
        default:
            DefaultSocketLogger.Logger.log("Got unknown packet type", type: logType)
        }
    }

    // Puts the engine back in its default state
    private func resetEngine() {
        closed = false
        connected = false
        fastUpgrade = false
        polling = true
        probing = false
        invalidated = false
        session = Foundation.URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: OperationQueue.main)
        sid = ""
        waitingForPoll = false
        waitingForPost = false
        websocket = false
    }

    private func sendPing() {
        guard connected else { return }

        // Server is not responding
        if pongsMissed > pongsMissedMax {
            client?.engineDidClose(reason: "Ping timeout")
            
            return
        }

        guard let pingInterval = pingInterval else { return }
        
        pongsMissed += 1
        write("", withType: .ping, withData: [])
        
        let time = DispatchTime.now() + Double(Int64(pingInterval * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
        DispatchQueue.main.asyncAfter(deadline: time) {[weak self] in self?.sendPing() }
    }

    // Moves from long-polling to websockets
    private func upgradeTransport() {
        if ws?.isConnected ?? false {
            DefaultSocketLogger.Logger.log("Upgrading transport to WebSockets", type: logType)

            fastUpgrade = true
            sendPollMessage("", withType: .noop, withData: [])
            // After this point, we should not send anymore polling messages
        }
    }

    /// Write a message, independent of transport.
    public func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data]) {
        emitQueue.async {
            guard self.connected else { return }

            if self.websocket {
                DefaultSocketLogger.Logger.log("Writing ws: %@ has data: %@",
                    type: self.logType, args: msg, data.count != 0)
                self.sendWebSocketMessage(msg, withType: type, withData: data)
            } else if !self.probing {
                DefaultSocketLogger.Logger.log("Writing poll: %@ has data: %@",
                    type: self.logType, args: msg, data.count != 0)
                self.sendPollMessage(msg, withType: type, withData: data)
            } else {
                self.probeWait.append((msg, type, data))
            }
        }
    }

    // Delegate methods
    public func websocketDidConnect(socket: WebSocket) {
        if !forceWebsockets {
            probing = true
            probeWebSocket()
        } else {
            connected = true
            probing = false
            polling = false
        }
    }

    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {
        probing = false

        if closed {
            client?.engineDidClose(reason: "Disconnect")
            
            return
        }

        if websocket {
            connected = false
            websocket = false

            if let reason = error?.localizedDescription {
                didError(reason: reason)
            } else {
                client?.engineDidClose(reason: "Socket Disconnected")
            }
        } else {
            flushProbeWait()
        }
    }
}

extension SocketEngine {
    public func URLSession(session: URLSession, didBecomeInvalidWithError error: NSError?) {
        DefaultSocketLogger.Logger.error("Engine URLSession became invalid", type: "SocketEngine")
        
        didError(reason: "Engine URLSession became invalid")
    }
}
