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

private typealias PollWaitQueue = [() -> Void]

private enum PacketType: String {
    case OPEN = "0"
    case CLOSE = "1"
    case PING = "2"
    case PONG = "3"
    case MESSAGE = "4"
    case UPGRADE = "5"
    case NOOP = "6"
}

public class SocketEngine: NSObject, WebSocketDelegate {
    unowned let client:SocketIOClient
    private let workQueue = NSOperationQueue()
    private let emitQueue = dispatch_queue_create(
        "emitQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
    private let parseQueue = dispatch_queue_create(
        "parseQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
    private let handleQueue = dispatch_queue_create(
        "handleQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
    private let session:NSURLSession!
    private var _connected = false
    private var fastUpgrade = false
    private var forcePolling = false
    private var pingTimer:NSTimer?
    private var postWait = [String]()
    private var _polling = true
    private var probing = false
    private var probeWait = PollWaitQueue()
    private var waitingForPoll = false
    private var waitingForPost = false
    private var _websocket = false
    private var websocketConnected = false
    var connected:Bool {
        return self._connected
    }
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
    
    init(client:SocketIOClient, forcePolling:Bool = false) {
        self.client = client
        self.forcePolling = forcePolling
        self.session = NSURLSession(configuration: NSURLSessionConfiguration.ephemeralSessionConfiguration(),
            delegate: nil, delegateQueue: self.workQueue)
    }
    
    func close() {
        self.pingTimer?.invalidate()
        self.send(PacketType.CLOSE.rawValue)
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
    
    private func createURLs(params:[String: AnyObject]? = nil) -> (String, String) {
        var url = "\(self.client.socketURL)/socket.io/?transport="
        var urlPolling:String
        var urlWebSocket:String
        
        if self.client.secure {
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
    
    private func doFastUpgrade() {
        self.sendWebSocketMessage("", withType: PacketType.UPGRADE)
        self._websocket = true
        self._polling = false
        self.fastUpgrade = false
        self.flushProbeWait()
    }
    
    private func doPoll() {
        if self.websocket || self.waitingForPoll || !self.connected {
            return
        }
        
        self.waitingForPoll = true
        self.doRequest(self.parsePollingMessage)
    }
    
    private func doRequest(callback:(String) -> Void) {
        if !self.polling {
            return
        }
        
        let req = NSURLRequest(URL: NSURL(string: self.urlPolling! + "&sid=\(self.sid)")!)
        
        self.session.dataTaskWithRequest(req) {[weak self] data, res, err in
            if self == nil {
                return
            } else if err != nil {
                if self!.polling {
                    self?.handlePollingFailed(err)
                }
                
                return
            }
            
            // println(data)
            
            if let str = NSString(data: data, encoding: NSUTF8StringEncoding) as? String {
                dispatch_async(self!.parseQueue) {callback(str)}
            }
            
            self?.waitingForPoll = false
            
            if self!.fastUpgrade {
                self?.doFastUpgrade()
                return
            } else {
                self?.doPoll()
            }
            }.resume()
    }
    
    private func flushProbeWait() {
        // println("flushing probe wait")
        dispatch_async(self.emitQueue) {[weak self] in
            if self == nil {
                return
            }
            
            for waiter in self!.probeWait {
                waiter()
            }
            
            self?.probeWait.removeAll(keepCapacity: false)
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
        
        // NSLog("posting: \(postStr)")
        req.HTTPBody = postData
        req.setValue(String(postData.length), forHTTPHeaderField: "Content-Length")
        
        self.waitingForPost = true
        self.session.dataTaskWithRequest(req) {[weak self] data, res, err in
            if self == nil {
                return
            } else if err != nil && self!.polling {
                self?.handlePollingFailed(err)
                return
            }
            
            self?.waitingForPost = false
            dispatch_async(self!.emitQueue) {
                self?.flushWaitingForPost()
                self?.doPoll()
                return
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
    private func handlePollingFailed(reason:NSError?) {
        assert(self.polling, "Polling failed when we're not polling")
        
        if !self.client.reconnecting {
            self._connected = false
            self.ws?.disconnect()
            self.pingTimer?.invalidate()
            self.waitingForPoll = false
            self.waitingForPost = false
            self.client.pollingDidFail(reason)
        }
    }
    
    func open(opts:[String: AnyObject]? = nil) {
        if self.connected {
            assert(false, "We're in a bad state, this shouldn't happen.")
        }
        
        let (urlPolling, urlWebSocket) = self.createURLs(params: opts)
        self.urlPolling = urlPolling
        self.urlWebSocket = urlWebSocket
        let reqPolling = NSURLRequest(URL: NSURL(string: urlPolling + "&b64=1")!)
        
        self.session.dataTaskWithRequest(reqPolling) {[weak self] data, res, err in
            var err2:NSError?
            if self == nil {
                return
            } else if err != nil || data == nil {
                self?.handlePollingFailed(err)
                return
            }
            
            if let dataString = NSString(data: data, encoding: NSUTF8StringEncoding) as? String {
                let parsed:[String]? = dataString["(\\d*):(\\d)(\\{.*\\})?"].groups()
                
                if parsed == nil || parsed?.count != 4 {
                    return
                }
                
                let length = parsed![1]
                let type = parsed![2]
                let jsonData = parsed![3].dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
                
                if type != "0" {
                    NSLog("Error handshaking")
                    return
                }
                
                if let json = NSJSONSerialization.JSONObjectWithData(jsonData!,
                    options: NSJSONReadingOptions.AllowFragments, error: &err2) as? NSDictionary {
                        if let sid = json["sid"] as? String {
                            // println(json)
                            self?.sid = sid
                            self?._connected = true
                            
                            if !self!.forcePolling {
                                self?.ws = WebSocket(url: NSURL(string: urlWebSocket + "&sid=\(self!.sid)")!)
                                self?.ws?.queue = self?.handleQueue
                                self?.ws?.delegate = self
                                self?.ws?.connect()
                            }
                        } else {
                            NSLog("Error handshaking")
                            return
                        }
                        
                        if let pingInterval = json["pingInterval"] as? Int {
                            self?.pingInterval = pingInterval / 1000
                        }
                }
                
                self?.doPoll()
                self?.startPingTimer()
            }}.resume()
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
                    println("failure in parsePollingMessage")
                    return
                }
                
                msg = String(strArray[i&+1...i&+n])
                
                if let lengthInt = length.toInt() {
                    if lengthInt != msg.length {
                        println("parsing error")
                        return
                    }
                }
                
                if msg.length != 0 {
                    // Be sure to capture the value of the msg
                    dispatch_async(self.handleQueue) {[weak self, msg] in
                        self?.parseEngineMessage(msg)
                        return
                    }
                }
                
                i += n
                length = ""
            }
        }
    }
    
    private func parseEngineData(data:NSData) {
        self.client.parseBinaryData(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
    }
    
    private func parseEngineMessage(var message:String) {
        // NSLog("Engine got message: \(message)")
        fixDoubleUTF8(&message)
        
        // We should upgrade
        if message == "3probe" {
            self.upgradeTransport()
            return
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
                        dispatch_async(self.client.handleQueue) {[weak self] in
                            self?.client.parseBinaryData(data)
                            return
                        }
                }
                
                return
            } else if type == PacketType.NOOP.rawValue {
                self.doPoll()
                return
            }
            
            if message == PacketType.CLOSE.rawValue {
                // do nothing
                return
            }
            // println("Got something idk what to do with")
            // println(messageString)
        }
        
        // Remove message type
        message.removeAtIndex(message.startIndex)
        
        dispatch_async(self.client.handleQueue) {[weak self] in
            self?.client.parseSocketMessage(message)
            return
        }
    }
    
    private func probeWebSocket() {
        if self.websocketConnected {
            self.sendWebSocketMessage("probe", withType: PacketType.PING)
        }
    }
    
    public func send(msg:String, datas:[NSData]? = nil) {
        let _send = {[weak self] (msg:String, datas:[NSData]?) -> () -> Void in
            return {
                if self == nil || !self!.connected {
                    return
                }
                
                if self!.websocket {
                    // println("sending ws: \(msg):\(datas)")
                    self?.sendWebSocketMessage(msg, withType: PacketType.MESSAGE, datas: datas)
                } else {
                    // println("sending poll: \(msg):\(datas)")
                    self?.sendPollMessage(msg, withType: PacketType.MESSAGE, datas: datas)
                }
            }
        }
        
        dispatch_async(self.emitQueue) {[weak self] in
            if self == nil {
                return
            }
            
            if self!.probing {
                self?.probeWait.append(_send(msg, datas))
            } else {
                _send(msg, datas)()
            }
        }
    }
    
    func sendPing() {
        if self.websocket {
            self.sendWebSocketMessage("", withType: PacketType.PING)
        } else {
            self.sendPollMessage("", withType: PacketType.PING)
        }
    }
    
    private func sendPollMessage(msg:String, withType type:PacketType,
        datas:[NSData]? = nil) {
            // println("Sending poll: \(msg) as type: \(type.rawValue)")
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
    
    private func sendWebSocketMessage(str:String, withType type:PacketType, datas:[NSData]? = nil) {
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
            self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(self.pingInterval!), target: self,
                selector: Selector("sendPing"), userInfo: nil, repeats: true)
        }
    }
    
    private func upgradeTransport() {
        if self.websocketConnected {
            // Do a fast upgrade
            self.fastUpgrade = true
            self.probing = false
            self.sendPollMessage("", withType: PacketType.NOOP)
        }
    }
    
    public func websocketDidConnect(socket:WebSocket) {
        self.websocketConnected = true
        self.probing = true
        self.probeWebSocket()
    }
    
    public func websocketDidDisconnect(socket:WebSocket, error:NSError?) {
        self.websocketConnected = false
        self.probing = false
        
        if self.websocket {
            self.pingTimer?.invalidate()
            self._connected = false
            self._websocket = false
            self._polling = true
            self.client.webSocketDidCloseWithCode(1, reason: "Socket Disconnect", wasClean: true)
        } else {
            self.flushProbeWait()
        }
    }
    
    public func websocketDidReceiveMessage(socket:WebSocket, text:String) {
        self.parseEngineMessage(text)
    }
    
    public func websocketDidReceiveData(socket:WebSocket, data:NSData) {
        self.parseEngineData(data)
    }
}
