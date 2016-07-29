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

public final class SocketEngine : NSObject, NSURLSessionDelegate, SocketEnginePollable, SocketEngineWebsocket {
    public let emitQueue = dispatch_queue_create("com.socketio.engineEmitQueue", DISPATCH_QUEUE_SERIAL)
    public let handleQueue = dispatch_queue_create("com.socketio.engineHandleQueue", DISPATCH_QUEUE_SERIAL)
    public let parseQueue = dispatch_queue_create("com.socketio.engineParseQueue", DISPATCH_QUEUE_SERIAL)

    public var connectParams: [String: AnyObject]? {
        didSet {
            (urlPolling, urlWebSocket) = createURLs()
        }
    }
    
    public var postWait = [String]()
    public var waitingForPoll = false
    public var waitingForPost = false
    
    public private(set) var closed = false
    public private(set) var connected = false
    public private(set) var cookies: [NSHTTPCookie]?
    public private(set) var doubleEncodeUTF8 = true
    public private(set) var extraHeaders: [String: String]?
    public private(set) var fastUpgrade = false
    public private(set) var forcePolling = false
    public private(set) var forceWebsockets = false
    public private(set) var invalidated = false
    public private(set) var polling = true
    public private(set) var probing = false
    public private(set) var session: NSURLSession?
    public private(set) var sid = ""
    public private(set) var socketPath = "/engine.io/"
    public private(set) var urlPolling = NSURL()
    public private(set) var urlWebSocket = NSURL()
    public private(set) var websocket = false
    public private(set) var ws: WebSocket?

    public weak var client: SocketEngineClient?
    
    private weak var sessionDelegate: NSURLSessionDelegate?

    private let logType = "SocketEngine"
    private let url: NSURL
    
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

    public init(client: SocketEngineClient, url: NSURL, options: Set<SocketIOClientOption>) {
        self.client = client
        self.url = url
        
        for option in options {
            switch option {
            case let .ConnectParams(params):
                connectParams = params
            case let .Cookies(cookies):
                self.cookies = cookies
            case let .DoubleEncodeUTF8(encode):
                doubleEncodeUTF8 = encode
            case let .ExtraHeaders(headers):
                extraHeaders = headers
            case let .SessionDelegate(delegate):
                sessionDelegate = delegate
            case let .ForcePolling(force):
                forcePolling = force
            case let .ForceWebsockets(force):
                forceWebsockets = force
            case let .Path(path):
                socketPath = path
                
                if !socketPath.hasSuffix("/") {
                    socketPath += "/"
                }
            case let .VoipEnabled(enable):
                voipEnabled = enable
            case let .Secure(secure):
                self.secure = secure
            case let .Security(security):
                self.security = security
            case let .SelfSigned(selfSigned):
                self.selfSigned = selfSigned
            default:
                continue
            }
        }
        
        super.init()
        
        sessionDelegate = sessionDelegate ?? self
        
        (urlPolling, urlWebSocket) = createURLs()
    }
    
    public convenience init(client: SocketEngineClient, url: NSURL, options: NSDictionary?) {
        self.init(client: client, url: url, options: options?.toSocketOptionsSet() ?? [])
    }
    
    deinit {
        DefaultSocketLogger.Logger.log("Engine is being released", type: logType)
        closed = true
        stopPolling()
    }
    
    private func checkAndHandleEngineError(msg: String) {
        do {
            let dict = try msg.toNSDictionary()
            guard let error = dict["message"] as? String else { return }
            
            /*
             0: Unknown transport
             1: Unknown sid
             2: Bad handshake request
             3: Bad request
             */
            didError(error)
        } catch {
            client?.engineDidError("Got unknown error from server \(msg)")
        }
    }

    private func checkIfMessageIsBase64Binary(message: String) -> Bool {
        if message.hasPrefix("b4") {
            // binary in base64 string
            let noPrefix = message[message.startIndex.advancedBy(2)..<message.endIndex]

            if let data = NSData(base64EncodedString: noPrefix, options: .IgnoreUnknownCharacters) {
                client?.parseEngineBinaryData(data)
            }
            
            return true
        } else {
            return false
        }
    }
    
    private func closeOutEngine(reason: String) {
        sid = ""
        closed = true
        invalidated = true
        connected = false
        
        ws?.disconnect()
        stopPolling()
        client?.engineDidClose(reason)
    }
    
    /// Starts the connection to the server
    public func connect() {
        if connected {
            DefaultSocketLogger.Logger.error("Engine tried opening while connected. Assuming this was a reconnect", type: logType)
            disconnect("reconnect")
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
        
        let reqPolling = NSMutableURLRequest(URL: urlPolling)
        
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            reqPolling.allHTTPHeaderFields = headers
        }
        
        if let extraHeaders = extraHeaders {
            for (headerName, value) in extraHeaders {
                reqPolling.setValue(value, forHTTPHeaderField: headerName)
            }
        }
        
        doLongPoll(reqPolling)
    }

    private func createURLs() -> (NSURL, NSURL) {
        if client == nil {
            return (NSURL(), NSURL())
        }

        let urlPolling = NSURLComponents(string: url.absoluteString)!
        let urlWebSocket = NSURLComponents(string: url.absoluteString)!
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
        
        return (urlPolling.URL!, urlWebSocket.URL!)
    }

    private func createWebsocketAndConnect() {
        ws = WebSocket(url: urlWebSocketWithSid)
        
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            for (key, value) in headers {
                ws?.headers[key] = value
            }
        }

        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                ws?.headers[headerName] = value
            }
        }

        ws?.queue = handleQueue
        ws?.voipEnabled = voipEnabled
        ws?.delegate = self
        ws?.selfSignedSSL = selfSigned
        ws?.security = security

        ws?.connect()
    }
    
    public func didError(error: String) {
        DefaultSocketLogger.Logger.error("%@", type: logType, args: error)
        client?.engineDidError(error)
        disconnect(error)
    }
    
    public func disconnect(reason: String) {
        guard connected else { return closeOutEngine(reason) }
        
        DefaultSocketLogger.Logger.log("Engine is being closed.", type: logType)
        
        if closed {
            return closeOutEngine(reason)
        }
        
        if websocket {
            sendWebSocketMessage("", withType: .Close, withData: [])
            closeOutEngine(reason)
        } else {
            disconnectPolling(reason)
        }
    }
    
    // We need to take special care when we're polling that we send it ASAP
    // Also make sure we're on the emitQueue since we're touching postWait
    private func disconnectPolling(reason: String) {
        dispatch_sync(emitQueue) {
            self.postWait.append(String(SocketEnginePacketType.Close.rawValue))
            let req = self.createRequestForPostWithPostWait()
            self.doRequest(req) {_, _, _ in }
            self.closeOutEngine(reason)
        }
    }

    public func doFastUpgrade() {
        if waitingForPoll {
            DefaultSocketLogger.Logger.error("Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", type: logType)
        }

        sendWebSocketMessage("", withType: .Upgrade, withData: [])
        websocket = true
        polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }

    private func flushProbeWait() {
        DefaultSocketLogger.Logger.log("Flushing probe wait", type: logType)

        dispatch_async(emitQueue) {
            for waiter in self.probeWait {
                self.write(waiter.msg, withType: waiter.type, withData: waiter.data)
            }
            
            self.probeWait.removeAll(keepCapacity: false)
            
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
            ws.writeString(msg)
        }
        
        postWait.removeAll(keepCapacity: true)
    }

    private func handleClose(reason: String) {
        client?.engineDidClose(reason)
    }

    private func handleMessage(message: String) {
        client?.parseEngineMessage(message)
    }

    private func handleNOOP() {
        doPoll()
    }

    private func handleOpen(openData: String) {
        do {
            let json = try openData.toNSDictionary()
            
            if let sid = json["sid"] as? String {
                let upgradeWs: Bool

                self.sid = sid
                connected = true

                if let upgrades = json["upgrades"] as? [String] {
                    upgradeWs = upgrades.contains("websocket")
                } else {
                    upgradeWs = false
                }

                if let pingInterval = json["pingInterval"] as? Double, pingTimeout = json["pingTimeout"] as? Double {
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
                
                client?.engineDidOpen("Connect")
            }
        } catch {
            didError("Error parsing open packet")
        }
    }

    private func handlePong(pongMessage: String) {
        pongsMissed = 0

        // We should upgrade
        if pongMessage == "3probe" {
            upgradeTransport()
        }
    }
    
    public func parseEngineData(data: NSData) {
        DefaultSocketLogger.Logger.log("Got binary data: %@", type: "SocketEngine", args: data)
        client?.parseEngineBinaryData(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
    }

    public func parseEngineMessage(message: String, fromPolling: Bool) {
        DefaultSocketLogger.Logger.log("Got message: %@", type: logType, args: message)
        
        let reader = SocketStringReader(message: message)
        let fixedString: String

        guard let type = SocketEnginePacketType(rawValue: Int(reader.currentCharacter) ?? -1) else {
            if !checkIfMessageIsBase64Binary(message) {
                checkAndHandleEngineError(message)
            }
            
            return
        }

        if fromPolling && type != .Noop && doubleEncodeUTF8 {
            fixedString = fixDoubleUTF8(message)
        } else {
            fixedString = message
        }

        switch type {
        case .Message:
            handleMessage(fixedString[fixedString.startIndex.successor()..<fixedString.endIndex])
        case .Noop:
            handleNOOP()
        case .Pong:
            handlePong(fixedString)
        case .Open:
            handleOpen(fixedString[fixedString.startIndex.successor()..<fixedString.endIndex])
        case .Close:
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
        session = NSURLSession(configuration: .defaultSessionConfiguration(),
            delegate: sessionDelegate,
            delegateQueue: NSOperationQueue.mainQueue())
        sid = ""
        waitingForPoll = false
        waitingForPost = false
        websocket = false
    }

    private func sendPing() {
        if !connected {
            return
        }
        
        //Server is not responding
        if pongsMissed > pongsMissedMax {
            client?.engineDidClose("Ping timeout")
            return
        }
        
        if let pingInterval = pingInterval {
            pongsMissed += 1
            write("", withType: .Ping, withData: [])
            
            let time = dispatch_time(DISPATCH_TIME_NOW, Int64(pingInterval * Double(NSEC_PER_SEC)))
            dispatch_after(time, dispatch_get_main_queue()) {[weak self] in
                self?.sendPing()
            }
        }
    }
    
    // Moves from long-polling to websockets
    private func upgradeTransport() {
        if ws?.isConnected ?? false {
            DefaultSocketLogger.Logger.log("Upgrading transport to WebSockets", type: logType)

            fastUpgrade = true
            sendPollMessage("", withType: .Noop, withData: [])
            // After this point, we should not send anymore polling messages
        }
    }

    /// Write a message, independent of transport.
    public func write(msg: String, withType type: SocketEnginePacketType, withData data: [NSData]) {
        dispatch_async(emitQueue) {
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
            client?.engineDidClose("Disconnect")
            return
        }
        
        if websocket {
            connected = false
            websocket = false
            
            if let reason = error?.localizedDescription {
                didError(reason)
            } else {
                client?.engineDidClose("Socket Disconnected")
            }
        } else {
            flushProbeWait()
        }
    }
}

extension SocketEngine {
    public func URLSession(session: NSURLSession, didBecomeInvalidWithError error: NSError?) {
        DefaultSocketLogger.Logger.error("Engine URLSession became invalid", type: "SocketEngine")
        
        didError("Engine URLSession became invalid")
    }
}
