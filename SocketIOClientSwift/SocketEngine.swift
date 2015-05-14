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

extension String {
    private var length:Int {
        return count(self)
    }
}

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
    private var pingTimer:NSTimer?
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
        return self._connected
    }
    weak var client:SocketEngineClient?
    var cookies:[NSHTTPCookie]?
    var log = false
    var pingInterval:Int?
    var polling:Bool {
        return self._polling
    }
    var sid = ""
    var socketPath = ""
    var urlPolling:String?
    var urlWebSocket:String?
    var websocket:Bool {
        return self._websocket
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
            delegate: sessionDelegate, delegateQueue: self.workQueue)
    }
    
    public convenience init(client:SocketEngineClient, opts:NSDictionary?) {
        self.init(client: client, sessionDelegate: opts?["sessionDelegate"] as? NSURLSessionDelegate)
        self.forceWebsockets = opts?["forceWebsockets"] as? Bool ?? false
        self.forcePolling = opts?["forcePolling"] as? Bool ?? false
        self.cookies = opts?["cookies"] as? [NSHTTPCookie]
        self.log = opts?["log"] as? Bool ?? false
        self.socketPath = opts?["path"] as? String ?? ""
    }
    
    deinit {
        SocketLogger.log("Engine is being deinit", client: self)
    }
    
    public func close(#fast:Bool) {
        SocketLogger.log("Engine is being closed. Fast: \(fast)", client: self)
        
        self.pingTimer?.invalidate()
        self.closed = true
        
        self.ws?.disconnect()
        
        if fast || self.polling {
            self.write("", withType: PacketType.CLOSE, withData: nil)
            self.client?.engineDidClose("Disconnect")
        }
        
        self.stopPolling()
    }
    
    private func createBinaryDataForSend(data:NSData) -> (NSData?, String?) {
        if self.websocket {
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
    
    private func createURLs(params:[String: AnyObject]?) -> (String, String) {
        if self.client == nil {
            return ("", "")
        }
        
        let path = self.socketPath == "" ? "/socket.io" : self.socketPath
        
        var url = "\(self.client!.socketURL)\(path)/?transport="
        var urlPolling:String
        var urlWebSocket:String
        
        if self.client!.secure {
            urlPolling = "https://" + url + "polling"
            urlWebSocket = "wss://" + url + "websocket"
        } else {
            urlPolling = "http://" + url + "polling"
            urlWebSocket = "ws://" + url + "websocket"
        }
        
        if params != nil {
            
            for (key, value) in params! {
                let keyEsc = key.stringByAddingPercentEncodingWithAllowedCharacters(
                    self.allowedCharacterSet)!
                urlPolling += "&\(keyEsc)="
                urlWebSocket += "&\(keyEsc)="
                
                if value is String {
                    let valueEsc = (value as! String).stringByAddingPercentEncodingWithAllowedCharacters(
                        self.allowedCharacterSet)!
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
        self.ws = WebSocket(url: NSURL(string: self.urlWebSocket! + "&sid=\(self.sid)")!,
            cookies: self.cookies)
        self.ws?.queue = self.handleQueue
        self.ws?.delegate = self
        
        if connect {
            self.ws?.connect()
        }
    }
    
    private func doFastUpgrade() {
        if self.waitingForPoll {
            SocketLogger.err("Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", client: self)
        }
        
        self.sendWebSocketMessage("", withType: PacketType.UPGRADE, datas: nil)
        self._websocket = true
        self._polling = false
        self.fastUpgrade = false
        self.probing = false
        self.flushProbeWait()
    }
    
    private func doPoll() {
        if self.websocket || self.waitingForPoll || !self.connected {
            return
        }

        self.waitingForPoll = true
        let req = NSMutableURLRequest(URL: NSURL(string: self.urlPolling! + "&sid=\(self.sid)&b64=1")!)
        
        if self.cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(self.cookies!)
            req.allHTTPHeaderFields = headers
        }
        
        self.doRequest(req)
    }
    
    private func doRequest(req:NSMutableURLRequest) {
        if !self.polling {
            return
        }
        
        req.cachePolicy = NSURLRequestCachePolicy.ReloadIgnoringLocalAndRemoteCacheData
        
        SocketLogger.log("Doing polling request", client: self)
        
        self.session.dataTaskWithRequest(req) {[weak self] data, res, err in
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
        
        dispatch_async(self.emitQueue) {[weak self] in
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
        if self.postWait.count == 0 || !self.connected {
            return
        } else if self.websocket {
            self.flushWaitingForPostToWebSocket()
            return
        }
        
        var postStr = ""
        
        for packet in self.postWait {
            let len = count(packet)
            
            postStr += "\(len):\(packet)"
        }
        
        self.postWait.removeAll(keepCapacity: false)
        
        let req = NSMutableURLRequest(URL: NSURL(string: self.urlPolling! + "&sid=\(self.sid)")!)
        
        if self.cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(self.cookies!)
            req.allHTTPHeaderFields = headers
        }
        
        req.HTTPMethod = "POST"
        req.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        
        let postData = postStr.dataUsingEncoding(NSUTF8StringEncoding,
            allowLossyConversion: false)!
        
        req.HTTPBody = postData
        req.setValue(String(postData.length), forHTTPHeaderField: "Content-Length")
        
        self.waitingForPost = true
        
        SocketLogger.log("POSTing: \(postStr)", client: self)
        
        self.session.dataTaskWithRequest(req) {[weak self] data, res, err in
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
        for msg in self.postWait {
            self.ws?.writeString(msg)
        }
        
        self.postWait.removeAll(keepCapacity: true)
    }
    
    // A poll failed, tell the client about it
    private func handlePollingFailed(reason:String) {
        self._connected = false
        self.ws?.disconnect()
        self.pingTimer?.invalidate()
        self.waitingForPoll = false
        self.waitingForPost = false
        
        // If cancelled we were already closing
        if self.client == nil || reason == "cancelled" {
            return
        }
        
        if !self.closed {
            self.client?.didError(reason)
            self.client?.engineDidClose(reason)
        }
    }
    
    public func open(opts:[String: AnyObject]? = nil) {
        if self.connected {
            SocketLogger.err("Tried to open while connected", client: self)
            
            self.client?.didError("Tried to open while connected")
            return
        }
        
        SocketLogger.log("Starting engine", client: self)
        SocketLogger.log("Handshaking", client: self)
        
        self.closed = false
        let (urlPolling, urlWebSocket) = self.createURLs(opts)
        self.urlPolling = urlPolling
        self.urlWebSocket = urlWebSocket
        
        if self.forceWebsockets {
            self._polling = false
            self._websocket = true
            self.createWebsocket(andConnect: true)
            return
        }
        
        let reqPolling = NSMutableURLRequest(URL: NSURL(string: urlPolling + "&b64=1")!)
        
        if self.cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(self.cookies!)
            reqPolling.allHTTPHeaderFields = headers
        }
        
        self.doRequest(reqPolling)
    }
    
    // Translatation of engine.io-parser#decodePayload
    private func parsePollingMessage(str:String) {
        if str.length == 1 {
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
        
        for var i = 0, l = str.length; i < l; i = i &+ 1 {
            let chr = String(strArray[i])
            
            if chr != ":" {
                length += chr
            } else {
                if length == "" || testLength(length, &n) {
                    SocketLogger.err("Parsing error: \(str)", client: self)
                    
                    self.handlePollingFailed("Error parsing XHR message")
                    return
                }
                
                msg = String(strArray[i&+1...i&+n])
                
                if let lengthInt = length.toInt() {
                    if lengthInt != msg.length {
                        SocketLogger.err("parsing error: \(str)", client: self)
                        return
                    }
                }
                
                if msg.length != 0 {
                    // Be sure to capture the value of the msg
                    dispatch_async(self.handleQueue) {[weak self, msg] in
                        self?.parseEngineMessage(msg, fromPolling: true)
                    }
                }
                
                i += n
                length = ""
            }
        }
    }
    
    private func parseEngineData(data:NSData) {
        if let client = self.client {
            dispatch_async(client.handleQueue) {[weak self] in
                self?.client?.parseBinaryData(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
            }
        }
    }
    
    private func parseEngineMessage(var message:String, fromPolling:Bool) {
        SocketLogger.log("Got message: \(message)", client: self)
        
        if fromPolling {
            fixDoubleUTF8(&message)
        }
        
        let type = PacketType(str: (message["^(\\d)"].groups()?[1]))
        
        if type == PacketType.MESSAGE {
            // Remove message type
            message.removeAtIndex(message.startIndex)
            
            if let client = self.client {
                dispatch_async(client.handleQueue) {[weak self] in
                    self?.client?.parseSocketMessage(message)
                }
            }
        } else if type == PacketType.NOOP {
            self.doPoll()
        } else if type == PacketType.PONG {
            // We should upgrade
            if message == "3probe" {
                self.upgradeTransport()
            }
        } else if type == PacketType.OPEN {
            var err:NSError?
            
            message.removeAtIndex(message.startIndex)
            let mesData = message.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
            
            if let json = NSJSONSerialization.JSONObjectWithData(mesData,
                options: NSJSONReadingOptions.AllowFragments,
                error: &err) as? NSDictionary, let sid = json["sid"] as? String {
                    self.sid = sid
                    self._connected = true
                    
                    if !self.forcePolling && !self.forceWebsockets {
                        self.createWebsocket(andConnect: true)
                    }
                    
                    if let pingInterval = json["pingInterval"] as? Int {
                        self.pingInterval = pingInterval / 1000
                    }
            } else {
                self.client?.didError("Engine failed to handshake")
                return
            }
            
            self.startPingTimer()
            
            if !self.forceWebsockets {
                self.doPoll()
            }
        } else if type == PacketType.CLOSE {
            if self.client == nil {
                return
            }
            
            if self.polling {
                self.client!.engineDidClose("Disconnect")
            }
        } else if message.hasPrefix("b4") {
            // binary in base64 string
            message.removeRange(Range<String.Index>(start: message.startIndex,
                end: advance(message.startIndex, 2)))
            
            if let data = NSData(base64EncodedString: message,
                options: NSDataBase64DecodingOptions.IgnoreUnknownCharacters), client = self.client {
                    dispatch_async(client.handleQueue) {[weak self] in
                        self?.client?.parseBinaryData(data)
                    }
            }
        }
    }
    
    private func probeWebSocket() {
        if self.websocketConnected {
            self.sendWebSocketMessage("probe", withType: PacketType.PING)
        }
    }
    
    /// Send an engine message (4)
    public func send(msg:String, withData datas:ContiguousArray<NSData>?) {
        if self.probing {
            self.probeWait.append((msg, PacketType.MESSAGE, datas))
        } else {
            self.write(msg, withType: PacketType.MESSAGE, withData: datas)
        }
    }
    
    func sendPing() {
        self.write("", withType: PacketType.PING, withData: nil)
    }
    
    /// Send polling message.
    /// Only call on emitQueue
    private func sendPollMessage(var msg:String, withType type:PacketType,
        datas:ContiguousArray<NSData>? = nil) {
            SocketLogger.log("Sending poll: \(msg) as type: \(type.rawValue)", client: self)
            
            doubleEncodeUTF8(&msg)
            let strMsg = "\(type.rawValue)\(msg)"
            
            self.postWait.append(strMsg)
            
            if datas != nil {
                for data in datas! {
                    let (nilData, b64Data) = self.createBinaryDataForSend(data)
                    
                    self.postWait.append(b64Data!)
                }
            }
            
            if !self.waitingForPost {
                self.flushWaitingForPost()
            }
    }
    
    /// Send message on WebSockets
    /// Only call on emitQueue
    private func sendWebSocketMessage(str:String, withType type:PacketType,
        datas:ContiguousArray<NSData>? = nil) {
            SocketLogger.log("Sending ws: \(str) as type: \(type.rawValue)", client: self)
            
            self.ws?.writeString("\(type.rawValue)\(str)")
            
            if datas != nil {
                for data in datas! {
                    let (data, nilString) = self.createBinaryDataForSend(data)
                    if data != nil {
                        self.ws?.writeData(data!)
                    }
                }
            }
    }
    
    // Starts the ping timer
    private func startPingTimer() {
        if self.pingInterval == nil {
            return
        }
        
        self.pingTimer?.invalidate()
        dispatch_async(dispatch_get_main_queue()) {[weak self] in
            if let this = self {
                this.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(this.pingInterval!),
                    target: this,
                    selector: Selector("sendPing"), userInfo: nil, repeats: true)
            }
        }
    }
    
    func stopPolling() {
        self.session.invalidateAndCancel()
    }
    
    private func upgradeTransport() {
        if self.websocketConnected {
            SocketLogger.log("Upgrading transport to WebSockets", client: self)
            
            // Do a fast upgrade
            // At this point, we should not send anymore polling messages-
            self.fastUpgrade = true
            self.sendPollMessage("", withType: PacketType.NOOP)
        }
    }
    
    /**
    Write a message, independent of transport.
    */
    public func write(msg:String, withType type:PacketType, withData data:ContiguousArray<NSData>?) {
        dispatch_async(self.emitQueue) {[weak self] in
            if let this = self where this.connected {
                if this.websocket {
                    SocketLogger.log("Writing ws: \(msg):\(data)", client: this)
                    this.sendWebSocketMessage(msg, withType: type, datas: data)
                } else {
                    SocketLogger.log("Writing poll: \(msg):\(data)", client: this)
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
            
            self.write(msg, withType: pType, withData: arr)
        }
    }
    
    // Delagate methods
    
    public func websocketDidConnect(socket:WebSocket) {
        self.websocketConnected = true
        
        if !self.forceWebsockets {
            self.probing = true
            self.probeWebSocket()
        } else {
            self._connected = true
            self.probing = false
            self._polling = false
        }
    }
    
    public func websocketDidDisconnect(socket:WebSocket, error:NSError?) {
        self.websocketConnected = false
        self.probing = false
        
        if self.closed {
            self.client?.engineDidClose("Disconnect")
            return
        }
        
        if self.websocket {
            self.pingTimer?.invalidate()
            self._connected = false
            self._websocket = false
            
            let reason = error?.localizedDescription ?? "Socket Disconnected"
            
            if error != nil {
                self.client?.didError(reason)
            }
            
            self.client?.engineDidClose(reason)
        } else {
            self.flushProbeWait()
        }
    }
    
    public func websocketDidReceiveMessage(socket:WebSocket, text:String) {
        self.parseEngineMessage(text, fromPolling: false)
    }
    
    public func websocketDidReceiveData(socket:WebSocket, data:NSData) {
        self.parseEngineData(data)
    }
}
