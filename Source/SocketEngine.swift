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

public final class SocketEngine : NSObject, SocketEnginePollable, SocketEngineWebsocket {
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

    private typealias Probe = (msg: String, type: SocketEnginePacketType, data: [NSData])
    private typealias ProbeWaitQueue = [Probe]

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
    private var selfSigned = false
    private var voipEnabled = false

    public init(client: SocketEngineClient, url: NSURL, options: Set<SocketIOClientOption>) {
        self.client = client
        self.url = url
        
        for option in options {
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
            case let .voipEnabled(enable):
                voipEnabled = enable
            case let .secure(secure):
                self.secure = secure
            case let .selfSigned(selfSigned):
                self.selfSigned = selfSigned
            default:
                continue
            }
        }
        
        super.init()
        
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
        guard let stringData = msg.data(usingEncoding: NSUTF8StringEncoding,
            allowLossyConversion: false) else { return }
        
        do {
            if let dict = try NSJSONSerialization.jsonObject(with: stringData,
                options: NSJSONReadingOptions.mutableContainers) as? NSDictionary {
                    guard let code = dict["code"] as? Int else { return }
                    guard let error = dict["message"] as? String else { return }
                    
                    switch code {
                    case 0: // Unknown transport
                        didError(error)
                    case 1: // Unknown sid.
                        didError(error)
                    case 2: // Bad handshake request
                        didError(error)
                    case 3: // Bad request
                        didError(error)
                    default:
                        didError(error)
                    }
            }
        } catch {
            didError("Got unknown error from server \(msg)")
        }
    }

    private func checkIfMessageIsBase64Binary(message: String) -> Bool {
        if message.hasPrefix("b4") {
            // binary in base64 string
            let noPrefix = message[message.startIndex.advanced(by: 2)..<message.endIndex]

            if let data = NSData(base64EncodedString: noPrefix,
                options: .ignoreUnknownCharacters) {
                    client?.parseEngineBinaryData(data)
            }
            
            return true
        } else {
            return false
        }
    }
    
    /// Starts the connection to the server
    public func connect() {
        if connected {
            DefaultSocketLogger.Logger.error("Engine tried opening while connected. Assuming this was a reconnect", type: logType)
            disconnect("reconnect")
        }
        
        DefaultSocketLogger.Logger.log("Starting engine", type: logType)
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
            let headers = NSHTTPCookie.requestHeaderFields(with: cookies!)
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
        urlWebSocket.query = "transport=websocket"
        urlPolling.query = "transport=polling&b64=1"

        if secure {
            urlPolling.scheme = "https"
            urlWebSocket.scheme = "wss"
        } else {
            urlPolling.scheme = "http"
            urlWebSocket.scheme = "ws"
        }

        if connectParams != nil {
            for (key, value) in connectParams! {
                queryString += "&\(key)=\(value)"
            }
        }

        urlWebSocket.query = urlWebSocket.query! + queryString
        urlPolling.query = urlPolling.query! + queryString
        
        return (urlPolling.url!, urlWebSocket.url!)
    }

    private func createWebsocketAndConnect() {
        ws = WebSocket(url: urlWebSocketWithSid)
        
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFields(with: cookies!)
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

        ws?.connect()
    }
    
    public func didError(error: String) {
        DefaultSocketLogger.Logger.error(error, type: logType)
        client?.engineDidError(error)
        disconnect(error)
    }
    
    public func disconnect(reason: String) {
        func postSendClose(data: NSData?, _ res: NSURLResponse?, _ err: NSError?) {
            sid = ""
            closed = true
            invalidated = true
            connected = false
            
            ws?.disconnect()
            stopPolling()
            client?.engineDidClose(reason)
        }
        
        DefaultSocketLogger.Logger.log("Engine is being closed.", type: logType)
        
        if closed {
            return postSendClose(nil, nil, nil)
        }
        
        if websocket {
            sendWebSocketMessage("", withType: .close, withData: [])
            postSendClose(nil, nil, nil)
        } else {
            // We need to take special care when we're polling that we send it ASAP
            // Also make sure we're on the emitQueue since we're touching postWait
            dispatch_sync(emitQueue) {
                self.postWait.append(String(SocketEnginePacketType.close.rawValue))
                let req = self.createRequestForPostWithPostWait()
                self.doRequest(req, callbackWith: postSendClose)
            }
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

        dispatch_async(emitQueue) {
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
            ws.writeString(fixDoubleUTF8(msg))
        }
        
        postWait.removeAll(keepingCapacity: true)
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
        let mesData = openData.data(usingEncoding: NSUTF8StringEncoding, allowLossyConversion: false)!
        do {
            let json = try NSJSONSerialization.jsonObject(with: mesData,
                options: NSJSONReadingOptions.allowFragments) as? NSDictionary
            if let sid = json?["sid"] as? String {
                let upgradeWs: Bool

                self.sid = sid
                connected = true

                if let upgrades = json?["upgrades"] as? [String] {
                    upgradeWs = upgrades.contains("websocket")
                } else {
                    upgradeWs = false
                }

                if let pingInterval = json?["pingInterval"] as? Double, pingTimeout = json?["pingTimeout"] as? Double {
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
                
                client?.engineDidOpen?("Connect")
            }
        } catch {
            didError("Error parsing open packet")
            return
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
        client?.parseEngineBinaryData(data.subdata(with: NSMakeRange(1, data.length - 1)))
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

        if fromPolling && type != .noop && doubleEncodeUTF8 {
            fixedString = fixDoubleUTF8(message)
        } else {
            fixedString = message
        }

        switch type {
        case .message:
            handleMessage(fixedString[fixedString.startIndex.successor()..<fixedString.endIndex])
        case .noop:
            handleNOOP()
        case .pong:
            handlePong(fixedString)
        case .open:
            handleOpen(fixedString[fixedString.startIndex.successor()..<fixedString.endIndex])
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
        session = NSURLSession(configuration: .defaultSessionConfiguration(),
            delegate: sessionDelegate,
            delegateQueue: NSOperationQueue())
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
            write("", withType: .ping, withData: [])
            
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
            sendPollMessage("", withType: .noop, withData: [])
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
            
            let reason = error?.localizedDescription ?? "Socket Disconnected"
            
            if error != nil {
                didError(reason)
            }
            
            client?.engineDidClose(reason)
        } else {
            flushProbeWait()
        }
    }
}
