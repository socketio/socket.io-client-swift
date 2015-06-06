//
//  SocketEngine.swift
//  Socket.IO-Swift
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

public final class SocketEngine: NSObject, WebSocketDelegate, SocketLogClient {
    private typealias Probe = (msg:String, type:PacketType, data:ContiguousArray<NSData>?)
    private typealias ProbeWaitQueue = [Probe]
    
    private let allowedCharacterSet = NSCharacterSet(charactersInString: "!*'();:@&=+$,/?%#[]\" {}").invertedSet
    private let workQueue = NSOperationQueue()
    private let emitQueue = dispatch_queue_create("engineEmitQueue", DISPATCH_QUEUE_SERIAL)
    private let parseQueue = dispatch_queue_create("engineParseQueue", DISPATCH_QUEUE_SERIAL)
    private let handleQueue = dispatch_queue_create("engineHandleQueue", DISPATCH_QUEUE_SERIAL)
    private let session:NSURLSession!
    
    private var closed = false
    private var _connected = false
    private var fastUpgrade = false
    private var forcePolling = false
    private var forceWebsockets = false
    private var pingInterval:Int?
    private var pingTimer:NSTimer?
    private var pingTimeout = 0 {
        didSet {
            pongsMissedMax = pingTimeout / (pingInterval ?? 25)
        }
    }
    private var pongsMissed = 0
    private var pongsMissedMax = 0
    private var postWait = [String]()
    private var _polling = true
    private var probing = false
    private var probeWait = ProbeWaitQueue()
    private var waitingForPoll = false
    private var waitingForPost = false
    private var _websocket = false
    private var websocketConnected = false
    
    let logType = "SocketEngine"
    
    var connected:Bool {
        return _connected
    }
    weak var client:SocketEngineClient?
    var cookies:[NSHTTPCookie]?
    var log = false
    var polling:Bool {
        return _polling
    }
    var sid = ""
    var socketPath = ""
    var urlPolling:String?
    var urlWebSocket:String?
    var websocket:Bool {
        return _websocket
    }
    var ws:WebSocket?
    
    public enum PacketType:Int {
        case OPEN = 0
        case CLOSE = 1
        case PING = 2
        case PONG = 3
        case MESSAGE = 4
        case UPGRADE = 5
        case NOOP = 6
        
        init?(str:String?) {
            if let value = str?.toInt(), raw = PacketType(rawValue: value) {
                self = raw
            } else {
                return nil
            }
        }
    }
    
    public init(client:SocketEngineClient, sessionDelegate:NSURLSessionDelegate?) {
        self.client = client
        self.session = NSURLSession(configuration: NSURLSessionConfiguration.ephemeralSessionConfiguration(),
            delegate: sessionDelegate, delegateQueue: workQueue)
    }
    
    public convenience init(client:SocketEngineClient, opts:NSDictionary?) {
        self.init(client: client, sessionDelegate: opts?["sessionDelegate"] as? NSURLSessionDelegate)
        forceWebsockets = opts?["forceWebsockets"] as? Bool ?? false
        forcePolling = opts?["forcePolling"] as? Bool ?? false
        cookies = opts?["cookies"] as? [NSHTTPCookie]
        log = opts?["log"] as? Bool ?? false
        socketPath = opts?["path"] as? String ?? ""
    }
    
    deinit {
        SocketLogger.log("Engine is being deinit", client: self)
    }
    
    public func close(#fast:Bool) {
        SocketLogger.log("Engine is being closed. Fast: %@", client: self, args: fast)
        
        pingTimer?.invalidate()
        closed = true
        
        ws?.disconnect()
        
        if fast || polling {
            write("", withType: PacketType.CLOSE, withData: nil)
            client?.engineDidClose("Disconnect")
        }
        
        stopPolling()
    }
    
    private func createBinaryDataForSend(data:NSData) -> (NSData?, String?) {
        if websocket {
            var byteArray = [UInt8](count: 1, repeatedValue: 0x0)
            byteArray[0] = 4
            var mutData = NSMutableData(bytes: &byteArray, length: 1)
            
            mutData.appendData(data)
            
            return (mutData, nil)
        } else {
            var str = "b4"
            str += data.base64EncodedStringWithOptions(
                NSDataBase64EncodingOptions.Encoding64CharacterLineLength)
            
            return (nil, str)
        }
    }
    
    private func createURLs(params:[String: AnyObject]?) -> (String?, String?) {
        if client == nil {
            return (nil, nil)
        }
        
        let path = socketPath == "" ? "/socket.io" : socketPath
        
        var url = "\(client!.socketURL)\(path)/?transport="
        var urlPolling:String
        var urlWebSocket:String
        
        if client!.secure {
            urlPolling = "https://" + url + "polling"
            urlWebSocket = "wss://" + url + "websocket"
        } else {
            urlPolling = "http://" + url + "polling"
            urlWebSocket = "ws://" + url + "websocket"
        }
        
        if params != nil {
            
            for (key, value) in params! {
                let keyEsc = key.stringByAddingPercentEncodingWithAllowedCharacters(
                    allowedCharacterSet)!
                urlPolling += "&\(keyEsc)="
                urlWebSocket += "&\(keyEsc)="
                
                if value is String {
                    let valueEsc = (value as! String).stringByAddingPercentEncodingWithAllowedCharacters(
                        allowedCharacterSet)!
                    urlPolling += "\(valueEsc)"
                    urlWebSocket += "\(valueEsc)"
                } else {
                    urlPolling += "\(value)"
                    urlWebSocket += "\(value)"
                }
            }
        }
        
        return (urlPolling, urlWebSocket)
    }
    
    private func createWebsocket(andConnect connect:Bool) {
        ws = WebSocket(url: NSURL(string: urlWebSocket! + "&sid=\(sid)")!,
            cookies: cookies)
        ws?.queue = handleQueue
        ws?.delegate = self
        
        if connect {
            ws?.connect()
        }
    }
    
    private func doFastUpgrade() {
        if waitingForPoll {
            SocketLogger.err("Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", client: self)
        }
        
        sendWebSocketMessage("", withType: PacketType.UPGRADE, datas: nil)
        _websocket = true
        _polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }
    
    private func doPoll() {
        if websocket || waitingForPoll || !connected {
            return
        }
        
        waitingForPoll = true
        let req = NSMutableURLRequest(URL: NSURL(string: urlPolling! + "&sid=\(sid)&b64=1")!)
        
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            req.allHTTPHeaderFields = headers
        }
        
        doRequest(req)
    }
    
    private func doRequest(req:NSMutableURLRequest) {
        if !polling {
            return
        }
        
        req.cachePolicy = NSURLRequestCachePolicy.ReloadIgnoringLocalAndRemoteCacheData
        
        SocketLogger.log("Doing polling request", client: self)
        
        session.dataTaskWithRequest(req) {[weak self] data, res, err in
            if let this = self {
                if err != nil {
                    if this.polling {
                        this.handlePollingFailed(err.localizedDescription)
                    } else {
                        SocketLogger.err(err.localizedDescription, client: this)
                    }
                    return
                }
                
                SocketLogger.log("Got polling response", client: this)
                
                if let str = NSString(data: data, encoding: NSUTF8StringEncoding) as? String {
                    dispatch_async(this.parseQueue) {[weak this] in
                        this?.parsePollingMessage(str)
                    }
                }
                
                this.waitingForPoll = false
                
                if this.fastUpgrade {
                    this.doFastUpgrade()
                } else if !this.closed && this.polling {
                    this.doPoll()
                }
            }}.resume()
    }
    
    private func flushProbeWait() {
        SocketLogger.log("Flushing probe wait", client: self)
        
        dispatch_async(emitQueue) {[weak self] in
            if let this = self {
                for waiter in this.probeWait {
                    this.write(waiter.msg, withType: waiter.type, withData: waiter.data)
                }
                
                this.probeWait.removeAll(keepCapacity: false)
                
                if this.postWait.count != 0 {
                    this.flushWaitingForPostToWebSocket()
                }
            }
        }
    }
    
    private func flushWaitingForPost() {
        if postWait.count == 0 || !connected {
            return
        } else if websocket {
            flushWaitingForPostToWebSocket()
            return
        }
        
        var postStr = ""
        
        for packet in postWait {
            let len = count(packet)
            
            postStr += "\(len):\(packet)"
        }
        
        postWait.removeAll(keepCapacity: false)
        
        let req = NSMutableURLRequest(URL: NSURL(string: urlPolling! + "&sid=\(sid)")!)
        
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            req.allHTTPHeaderFields = headers
        }
        
        req.HTTPMethod = "POST"
        req.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        
        let postData = postStr.dataUsingEncoding(NSUTF8StringEncoding,
            allowLossyConversion: false)!
        
        req.HTTPBody = postData
        req.setValue(String(postData.length), forHTTPHeaderField: "Content-Length")
        
        waitingForPost = true
        
        SocketLogger.log("POSTing: %@", client: self, args: postStr)
        
        session.dataTaskWithRequest(req) {[weak self] data, res, err in
            if let this = self {
                if err != nil && this.polling {
                    this.handlePollingFailed(err.localizedDescription)
                    return
                } else if err != nil {
                    NSLog(err.localizedDescription)
                    return
                }
                
                this.waitingForPost = false
                
                dispatch_async(this.emitQueue) {[weak this] in
                    if !(this?.fastUpgrade ?? true) {
                        this?.flushWaitingForPost()
                        this?.doPoll()
                    }
                }
            }}.resume()
    }
    
    // We had packets waiting for send when we upgraded
    // Send them raw
    private func flushWaitingForPostToWebSocket() {
        for msg in postWait {
            ws?.writeString(msg)
        }
        
        postWait.removeAll(keepCapacity: true)
    }
    
    private func handleClose() {
        if polling {
            client?.engineDidClose("Disconnect")
        }
    }
    
    private func checkIfMessageIsBase64Binary(var message:String) {
        if message.hasPrefix("b4") {
            // binary in base64 string
            message.removeRange(Range<String.Index>(start: message.startIndex,
                end: advance(message.startIndex, 2)))
            
            if let data = NSData(base64EncodedString: message,
                options: NSDataBase64DecodingOptions.IgnoreUnknownCharacters), client = client {
                    dispatch_async(client.handleQueue) {[weak self] in
                        self?.client?.parseBinaryData(data)
                    }
            }
        }
    }
    
    private func handleMessage(message:String) {
        if let client = client {
            dispatch_async(client.handleQueue) {[weak client] in
                client?.parseSocketMessage(message)
            }
        }
    }
    
    private func handleNOOP() {
        doPoll()
    }
    
    private func handleOpen(openData:String) {
        var err:NSError?
        let mesData = openData.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
        
        if let json = NSJSONSerialization.JSONObjectWithData(mesData,
            options: NSJSONReadingOptions.AllowFragments,
            error: &err) as? NSDictionary, sid = json["sid"] as? String {
                self.sid = sid
                _connected = true
                
                if !forcePolling && !forceWebsockets {
                    createWebsocket(andConnect: true)
                }
                
                if let pingInterval = json["pingInterval"] as? Int, pingTimeout = json["pingTimeout"] as? Int {
                    self.pingInterval = pingInterval / 1000
                    self.pingTimeout = pingTimeout / 1000
                }
        } else {
            client?.didError("Engine failed to handshake")
            return
        }
        
        startPingTimer()
        
        if !forceWebsockets {
            doPoll()
        }
    }
    
    private func handlePong(pongMessage:String) {
        pongsMissed = 0
        
        // We should upgrade
        if pongMessage == "3probe" {
            upgradeTransport()
        }
    }
    
    // A poll failed, tell the client about it
    private func handlePollingFailed(reason:String) {
        _connected = false
        ws?.disconnect()
        pingTimer?.invalidate()
        waitingForPoll = false
        waitingForPost = false
        
        // If cancelled we were already closing
        if client == nil || reason == "cancelled" {
            return
        }
        
        if !closed {
            client?.didError(reason)
            client?.engineDidClose(reason)
        }
    }
    
    public func open(opts:[String: AnyObject]? = nil) {
        if connected {
            SocketLogger.err("Tried to open while connected", client: self)
            
            client?.didError("Tried to open while connected")
            return
        }
        
        SocketLogger.log("Starting engine", client: self)
        SocketLogger.log("Handshaking", client: self)
        
        closed = false
        
        (urlPolling, urlWebSocket) = createURLs(opts)
        
        if forceWebsockets {
            _polling = false
            _websocket = true
            createWebsocket(andConnect: true)
            return
        }
        
        let reqPolling = NSMutableURLRequest(URL: NSURL(string: urlPolling! + "&b64=1")!)
        
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            reqPolling.allHTTPHeaderFields = headers
        }
        
        doRequest(reqPolling)
    }
    
    // Translatation of engine.io-parser#decodePayload
    private func parsePollingMessage(str:String) {
        if count(str) == 1 {
            return
        }
        
        // println(str)
        
        let strArray = Array(str)
        var length = ""
        var n = 0
        var msg = ""
        
        func testLength(length:String, inout n:Int) -> Bool {
            if let num = length.toInt() {
                n = num
                return false
            } else {
                return true
            }
        }
        
        for var i = 0, l = count(str); i < l; i++ {
            let chr = String(strArray[i])
            
            if chr != ":" {
                length += chr
            } else {
                if length == "" || testLength(length, &n) {
                    SocketLogger.err("Parsing error: %@", client: self, args: str)
                    handlePollingFailed("Error parsing XHR message")
                    return
                }
                
                msg = String(strArray[i+1...i+n])
                
                if let lengthInt = length.toInt() where lengthInt != count(msg) {
                    SocketLogger.err("Parsing error: %@", client: self, args: str)
                    return
                }
                
                if count(msg) != 0 {
                    // Be sure to capture the value of the msg
                    dispatch_async(handleQueue) {[weak self, msg] in
                        self?.parseEngineMessage(msg, fromPolling: true)
                    }
                }
                
                i += n
                length = ""
            }
        }
    }
    
    private func parseEngineData(data:NSData) {
        if let client = client {
            dispatch_async(client.handleQueue) {[weak self] in
                self?.client?.parseBinaryData(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
            }
        }
    }
    
    private func parseEngineMessage(var message:String, fromPolling:Bool) {
        SocketLogger.log("Got message: %@", client: self, args: message)
        
        if fromPolling {
            fixDoubleUTF8(&message)
        }
        
        let type = PacketType(str: (message["^(\\d)"].groups()?[1])) ?? {
            self.checkIfMessageIsBase64Binary(message)
            return PacketType.NOOP
        }()
        
        switch type {
        case PacketType.MESSAGE:
            message.removeAtIndex(message.startIndex)
            handleMessage(message)
        case PacketType.NOOP:
            handleNOOP()
        case PacketType.PONG:
            handlePong(message)
        case PacketType.OPEN:
            message.removeAtIndex(message.startIndex)
            handleOpen(message)
        case PacketType.CLOSE:
            handleClose()
        default:
            SocketLogger.log("Got unknown packet type", client: self)
        }
    }
    
    private func probeWebSocket() {
        if websocketConnected {
            sendWebSocketMessage("probe", withType: PacketType.PING)
        }
    }
    
    /// Send an engine message (4)
    public func send(msg:String, withData datas:ContiguousArray<NSData>?) {
        if probing {
            probeWait.append((msg, PacketType.MESSAGE, datas))
        } else {
            write(msg, withType: PacketType.MESSAGE, withData: datas)
        }
    }
    
    @objc private func sendPing() {
        //Server is not responding
        if pongsMissed > pongsMissedMax {
            pingTimer?.invalidate()
            client?.engineDidClose("Ping timeout")
            return
        }
        
        ++pongsMissed
        write("", withType: PacketType.PING, withData: nil)
    }
    
    /// Send polling message.
    /// Only call on emitQueue
    private func sendPollMessage(var msg:String, withType type:PacketType,
        datas:ContiguousArray<NSData>? = nil) {
            SocketLogger.log("Sending poll: %@ as type: %@", client: self, args: msg, type.rawValue)
            
            doubleEncodeUTF8(&msg)
            let strMsg = "\(type.rawValue)\(msg)"
            
            postWait.append(strMsg)
            
            if datas != nil {
                for data in datas! {
                    let (nilData, b64Data) = createBinaryDataForSend(data)
                    
                    postWait.append(b64Data!)
                }
            }
            
            if !waitingForPost {
                flushWaitingForPost()
            }
    }
    
    /// Send message on WebSockets
    /// Only call on emitQueue
    private func sendWebSocketMessage(str:String, withType type:PacketType,
        datas:ContiguousArray<NSData>? = nil) {
            SocketLogger.log("Sending ws: %@ as type: %@", client: self, args: str, type.rawValue)
            
            ws?.writeString("\(type.rawValue)\(str)")
            
            if datas != nil {
                for data in datas! {
                    let (data, nilString) = createBinaryDataForSend(data)
                    if data != nil {
                        ws?.writeData(data!)
                    }
                }
            }
    }
    
    // Starts the ping timer
    private func startPingTimer() {
        if pingInterval == nil {
            return
        }
        
        pingTimer?.invalidate()
        dispatch_async(dispatch_get_main_queue()) {[weak self] in
            if let this = self {
                this.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(this.pingInterval!),
                    target: this,
                    selector: Selector("sendPing"), userInfo: nil, repeats: true)
            }
        }
    }
    
    func stopPolling() {
        session.invalidateAndCancel()
    }
    
    private func upgradeTransport() {
        if websocketConnected {
            SocketLogger.log("Upgrading transport to WebSockets", client: self)
            
            fastUpgrade = true
            sendPollMessage("", withType: PacketType.NOOP)
            // After this point, we should not send anymore polling messages
        }
    }
    
    /**
    Write a message, independent of transport.
    */
    public func write(msg:String, withType type:PacketType, withData data:ContiguousArray<NSData>?) {
        dispatch_async(emitQueue) {[weak self] in
            if let this = self where this.connected {
                if this.websocket {
                    SocketLogger.log("Writing ws: %@ has data: %@", client: this,
                        args: msg, data == nil ? false : true)
                    this.sendWebSocketMessage(msg, withType: type, datas: data)
                } else {
                    SocketLogger.log("Writing poll: %@ has data: %@", client: this,
                        args: msg, data == nil ? false : true)
                    this.sendPollMessage(msg, withType: type, datas: data)
                }
            }
        }
    }
    
    /**
    Write a message, independent of transport. For Objective-C. withData should be an NSArray of NSData
    */
    public func writeObjc(msg:String, withType type:Int, withData data:NSArray?) {
        if let pType = PacketType(rawValue: type) {
            var arr = ContiguousArray<NSData>()
            
            if data != nil {
                for d in data! {
                    arr.append(d as! NSData)
                }
            }
            
            write(msg, withType: pType, withData: arr)
        }
    }
    
    // Delagate methods
    
    public func websocketDidConnect(socket:WebSocket) {
        websocketConnected = true
        
        if !forceWebsockets {
            probing = true
            probeWebSocket()
        } else {
            _connected = true
            probing = false
            _polling = false
        }
    }
    
    public func websocketDidDisconnect(socket:WebSocket, error:NSError?) {
        websocketConnected = false
        probing = false
        
        if closed {
            client?.engineDidClose("Disconnect")
            return
        }
        
        if websocket {
            pingTimer?.invalidate()
            _connected = false
            _websocket = false
            
            let reason = error?.localizedDescription ?? "Socket Disconnected"
            
            if error != nil {
                client?.didError(reason)
            }
            
            client?.engineDidClose(reason)
        } else {
            flushProbeWait()
        }
    }
    
    public func websocketDidReceiveMessage(socket:WebSocket, text:String) {
        parseEngineMessage(text, fromPolling: false)
    }
    
    public func websocketDidReceiveData(socket:WebSocket, data:NSData) {
        parseEngineData(data)
    }
}
