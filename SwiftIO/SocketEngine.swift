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
        return countElements(self)
    }
}

private typealias Probe = (msg:String, type:PacketType, data:ContiguousArray<NSData>?)
private typealias ProbeWaitQueue = [Probe]

public enum PacketType:String {
    case OPEN = "0"
    case CLOSE = "1"
    case PING = "2"
    case PONG = "3"
    case MESSAGE = "4"
    case UPGRADE = "5"
    case NOOP = "6"
}

public class SocketEngine: NSObject, WebSocketDelegate {
    private let workQueue = NSOperationQueue()
    private let emitQueue = dispatch_queue_create(
        "engineEmitQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
    private let parseQueue = dispatch_queue_create(
        "engineParseQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
    private let handleQueue = dispatch_queue_create(
        "engineHandleQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
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
    var connected:Bool {
        return self._connected
    }
    
    weak var client:SocketEngineClient?
    var cookies:[NSHTTPCookie]?
    var pingInterval:Int?
    var polling:Bool {
        return self._polling
    }
    var sid = ""
    var urlPolling:String?
    var urlWebSocket:String?
    var websocket:Bool {
        return self._websocket
    }
    var ws:WebSocket?
    
    public init(client:SocketEngineClient, forcePolling:Bool,
        forceWebsockets:Bool, withCookies cookies:[NSHTTPCookie]?) {
            self.client = client
            self.forcePolling = forcePolling
            self.forceWebsockets = forceWebsockets
            self.cookies = cookies
            self.session = NSURLSession(configuration: NSURLSessionConfiguration.ephemeralSessionConfiguration(),
                delegate: nil, delegateQueue: self.workQueue)
    }
    
    public func close(#fast:Bool) {
        self.pingTimer?.invalidate()
        self.closed = true
        
        self.write("", withType: PacketType.CLOSE, withData: nil)
        self.ws?.disconnect()
        
        if fast || self.polling {
            self.client?.didForceClose("Disconnect")
        }
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
        
        var url = "\(self.client!.socketURL)/socket.io/?transport="
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
                    NSCharacterSet.URLHostAllowedCharacterSet())!
                urlPolling += "&\(keyEsc)="
                urlWebSocket += "&\(keyEsc)="
                
                if value is String {
                    let valueEsc = (value as String).stringByAddingPercentEncodingWithAllowedCharacters(
                        NSCharacterSet.URLHostAllowedCharacterSet())!
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
        self.ws = WebSocket(url: NSURL(string: self.urlWebSocket! + "&sid=\(self.sid)")!)
        self.ws?.queue = self.handleQueue
        self.ws?.delegate = self
        
        if connect {
            self.ws?.connect()
        }
    }
    
    private func doFastUpgrade() {
        if self.waitingForPoll {
            NSLog("Outstanding poll when switched to websockets," +
                "we'll probably disconnect soon. You should report this.")
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
        
        self.doRequest(req)
    }
    
    private func doRequest(req:NSMutableURLRequest) {
        if !self.polling {
            return
        }
        
        req.cachePolicy = NSURLRequestCachePolicy.ReloadIgnoringLocalAndRemoteCacheData
        
        // NSLog("Doing request: \(req)")
        self.session.dataTaskWithRequest(req) {[weak self] data, res, err in
            if self == nil {
                return
            } else if err != nil {
                if self!.polling {
                    self?.handlePollingFailed(err.localizedDescription)
                } else {
                    NSLog(err.localizedDescription)
                }
                
                return
            }
            
            // NSLog("Got response: \(res)")
            
            if let str = NSString(data: data, encoding: NSUTF8StringEncoding) as? String {
                dispatch_async(self!.parseQueue) {
                    self?.parsePollingMessage(str)
                    return
                }
            }
            
            self?.waitingForPoll = false
            if self!.fastUpgrade {
                self?.doFastUpgrade()
                return
            } else if !self!.closed && self!.polling {
                self?.doPoll()
            }
            }.resume()
    }
    
    private func flushProbeWait() {
        // NSLog("flushing probe wait")
        dispatch_async(self.emitQueue) {[weak self] in
            if self == nil {
                return
            }
            
            for waiter in self!.probeWait {
                self?.write(waiter.msg, withType: waiter.type, withData: waiter.data)
            }
            
            self?.probeWait.removeAll(keepCapacity: false)
            
            if self?.postWait.count != 0 {
                self?.flushWaitingForPostToWebSocket()
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
            let len = countElements(packet)
            
            postStr += "\(len):\(packet)"
        }
        
        self.postWait.removeAll(keepCapacity: false)
        
        let req = NSMutableURLRequest(URL: NSURL(string: self.urlPolling! + "&sid=\(self.sid)")!)
        
        req.HTTPMethod = "POST"
        req.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        
        let postData = postStr.dataUsingEncoding(NSUTF8StringEncoding,
            allowLossyConversion: false)!
        
        req.HTTPBody = postData
        req.setValue(String(postData.length), forHTTPHeaderField: "Content-Length")
        
        self.waitingForPost = true
        
        // NSLog("posting: \(postStr)")
        // NSLog("Posting with WS status of: \(self.websocket)")
        
        self.session.dataTaskWithRequest(req) {[weak self] data, res, err in
            if self == nil {
                return
            } else if err != nil && self!.polling {
                self?.handlePollingFailed(err.localizedDescription)
                return
            } else if err != nil {
                NSLog(err.localizedDescription)
                return
            }
            
            self?.waitingForPost = false
            dispatch_async(self!.emitQueue) {
                if !self!.fastUpgrade {
                    self?.flushWaitingForPost()
                    self?.doPoll()
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
        
        if self.client == nil {
            return
        }
        
        if !self.closed && !self.client!.reconnecting {
            self.client?.pollingDidFail(reason)
        } else if !self.client!.reconnecting {
            self.client?.didForceClose(reason)
        }
    }
    
    public func open(opts:[String: AnyObject]? = nil) {
        if self.connected {
            fatalError("Engine tried to open while connected")
        }
        
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
            } else {
                return true
            }
            
            return false
        }
        
        for var i = 0, l = str.length; i < l; i = i &+ 1 {
            let chr = String(strArray[i])
            
            if chr != ":" {
                length += chr
            } else {
                if length == "" || testLength(length, &n) {
                    NSLog("parsing error: \(str)")
                    self.handlePollingFailed("Error parsing XHR message")
                    return
                }
                
                msg = String(strArray[i&+1...i&+n])
                
                if let lengthInt = length.toInt() {
                    if lengthInt != msg.length {
                        NSLog("parsing error: \(str)")
                        return
                    }
                }
                
                if msg.length != 0 {
                    // Be sure to capture the value of the msg
                    dispatch_async(self.handleQueue) {[weak self, msg] in
                        self?.parseEngineMessage(msg, fromPolling: true)
                        return
                    }
                }
                
                i += n
                length = ""
            }
        }
    }
    
    private func parseEngineData(data:NSData) {
        if self.client == nil {
            return
        }
        
        dispatch_async(self.client!.handleQueue) {[weak self] in
            self?.client?.parseBinaryData(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
            return
        }
    }
    
    private func parseEngineMessage(var message:String, fromPolling:Bool) {
        // NSLog("Engine got message: \(message)")
        if fromPolling {
            fixDoubleUTF8(&message)
        }
        
        let type = message["^(\\d)"].groups()?[1]
        
        if type != PacketType.MESSAGE.rawValue {
            // TODO Handle other packets
            if message.hasPrefix("b4") {
                // binary in base64 string
                
                message.removeRange(Range<String.Index>(start: message.startIndex,
                    end: advance(message.startIndex, 2)))
                
                if let data = NSData(base64EncodedString: message,
                    options: NSDataBase64DecodingOptions.IgnoreUnknownCharacters) {
                        // println("sending \(data)")
                        
                        if self.client == nil {
                            return
                        }
                        
                        dispatch_async(self.client!.handleQueue) {[weak self] in
                            self?.client?.parseBinaryData(data)
                            return
                        }
                }
                
                return
            } else if type == PacketType.NOOP.rawValue {
                self.doPoll()
                return
            } else if type == PacketType.PONG.rawValue {
                // We should upgrade
                if message == "3probe" {
                    self.upgradeTransport()
                    return
                }
                
                return
            } else if type == PacketType.OPEN.rawValue {
                var err:NSError?
                
                message.removeAtIndex(message.startIndex)
                let mesData = message.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
                
                if let json = NSJSONSerialization.JSONObjectWithData(mesData,
                    options: NSJSONReadingOptions.AllowFragments, error: &err) as? NSDictionary {
                        if let sid = json["sid"] as? String {
                            // println(json)
                            self.sid = sid
                            self._connected = true
                            if !self.forcePolling && !self.forceWebsockets {
                                self.createWebsocket(andConnect: true)
                            }
                        } else {
                            NSLog("Error handshaking")
                            return
                        }
                        
                        if let pingInterval = json["pingInterval"] as? Int {
                            self.pingInterval = pingInterval / 1000
                        }
                } else {
                    fatalError("Error parsing engine connect")
                }
                
                self.startPingTimer()
                
                if !self.forceWebsockets {
                    self.doPoll()
                }
                
                return
            } else if type == PacketType.CLOSE.rawValue {
                if self.client == nil {
                    return
                }
                
                if self.polling {
                    self.client!.didForceClose("Disconnect")
                }
                
                return
            }
            // println("Got something idk what to do with")
            // println(messageString)
        }
        
        // Remove message type
        message.removeAtIndex(message.startIndex)
        
        if self.client == nil {
            return
        }
        
        dispatch_async(self.client!.handleQueue) {[weak self] in
            self?.client?.parseSocketMessage(message)
            return
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
            // println("Sending poll: \(msg) as type: \(type.rawValue)")
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
            // println("Sending ws: \(str) as type: \(type.rawValue)")
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
        dispatch_async(dispatch_get_main_queue()) {
            self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(self.pingInterval!),
                target: self,
                selector: Selector("sendPing"), userInfo: nil, repeats: true)
        }
    }
    
    private func upgradeTransport() {
        if self.websocketConnected {
            // NSLog("Doing fast upgrade")
            // Do a fast upgrade
            // At this point, we should not send anymore polling messages-
            self.fastUpgrade = true
            self.sendPollMessage("", withType: PacketType.NOOP)
        }
    }
    
    public func write(msg:String, withType type:PacketType, withData data:ContiguousArray<NSData>?) {
        dispatch_async(self.emitQueue) {[weak self] in
            if self == nil || !self!.connected {
                return
            }
            
            if self!.websocket {
                // NSLog("writing ws: \(msg):\(data)")
                self?.sendWebSocketMessage(msg, withType: type, datas: data)
            } else {
                // NSLog("writing poll: \(msg):\(data)")
                self?.sendPollMessage(msg, withType: type, datas: data)
            }
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
            self.client?.didForceClose("Disconnect")
            return
        }
        
        if self.websocket {
            self.pingTimer?.invalidate()
            self._connected = false
            self._websocket = false
            
            let reason = error?.localizedDescription
            self.client?.webSocketDidCloseWithCode(1,
                reason: reason == nil ? "Socket Disconnected" : reason!)
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
