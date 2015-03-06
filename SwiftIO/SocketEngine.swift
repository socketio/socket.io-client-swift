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

// This is used because in Swift 1.1, turning on -O causes a
// memory access violation in SocketEngine#parseEngineMessage
private var fixSwift:AnyObject?

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

class SocketEngine: NSObject, SRWebSocketDelegate {
    unowned let client:SocketIOClient
    private let workQueue = NSOperationQueue()
    private let emitQueue = dispatch_queue_create(
        "emitQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
    private let handleQueue = dispatch_queue_create(
        "handleQueue".cStringUsingEncoding(NSUTF8StringEncoding), DISPATCH_QUEUE_SERIAL)
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
    var connected = false
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
    var ws:SRWebSocket?
    
    init(client:SocketIOClient, forcePolling:Bool = false) {
        self.client = client
        self.forcePolling = forcePolling
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
    
    private func doPoll() {
        if self.urlPolling == nil || self.websocket || self.waitingForPoll || !self.connected {
            return
        }
        
        let req = NSURLRequest(URL:
            NSURL(string: self.urlPolling! + "&sid=\(self.sid)")!)
        self.waitingForPoll = true
        
        NSURLConnection.sendAsynchronousRequest(req,
            queue: self.workQueue) {[weak self] res, data, err in
                if self == nil {
                    return
                } else if err != nil {
                    if self!.polling {
                        self?.handlePollingFailed(err)
                    }
                    return
                }
                
                // println(data)
                
                if let str = NSString(data: data, encoding: NSUTF8StringEncoding) {
                    // println(str)
                    
                    dispatch_async(self?.handleQueue) {[weak self] in
                        self?.parsePollingMessage(str)
                        return
                    }
                }
                
                self?.waitingForPoll = false
                self?.doPoll()
        }
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
        if self.postWait.count == 0 || !self.connected || !self.polling  {
            return
        }
        
        let postStr = self.postWait.reduce("") {$0 + $1}
        assert(self.postWait.count != 0)
        self.postWait.removeAll(keepCapacity: true)
        
        var req = NSMutableURLRequest(URL:
            NSURL(string: self.urlPolling! + "&sid=\(self.sid)")!)
        
        req.HTTPMethod = "POST"
        req.setValue("application/html-text", forHTTPHeaderField: "Content-Type")
        
        let postData = postStr.dataUsingEncoding(NSUTF8StringEncoding,
            allowLossyConversion: false)!
        
        
        req.setValue(String(postData.length), forHTTPHeaderField: "Content-Length")
        req.HTTPBody = postData
        
        self.waitingForPost = true
        NSURLConnection.sendAsynchronousRequest(req, queue: self.workQueue) {[weak self] res, data, err in
            if err != nil {
                if self!.polling {
                    self?.handlePollingFailed(err)
                }
                return
            }
            
            self?.flushWaitingForPost()
            self?.waitingForPost = false
            self?.doPoll()
        }
    }
    
    // A poll failed, tell the client about it
    // We check to see if we were closed by the server first
    private func handlePollingFailed(reason:NSError?) {
        if !self.client.reconnecting {
            self.connected = false
            self.pingTimer?.invalidate()
            self.waitingForPoll = false
            self.waitingForPost = false
            self.client.pollingDidFail(reason)
        }
    }
    
    func open(opts:[String: AnyObject]? = nil) {
        if self.waitingForPost || self.waitingForPoll || self.websocket || self.connected {
            assert(false, "We're in a bad state, this shouldn't happen.")
        }
        
        let (urlPolling, urlWebSocket) = self.createURLs(params: opts)
        
        self.urlPolling = urlPolling
        self.urlWebSocket = urlWebSocket
        let reqPolling = NSURLRequest(URL: NSURL(string: urlPolling + "&b64=1")!)
        
        NSURLConnection.sendAsynchronousRequest(reqPolling,
            queue: self.workQueue) {[weak self] res, data, err in
                var err:NSError?
                if self == nil {
                    return
                } else if err != nil || data == nil {
                    if self!.polling {
                        self?.handlePollingFailed(err)
                    }
                    return
                }
                
                if let dataString = NSString(data: data, encoding: NSUTF8StringEncoding) {
                    var mutString = RegexMutable(dataString)
                    let parsed = mutString["(\\d*):(\\d)(\\{.*\\})?"].groups()
                    
                    if parsed.count != 4 {
                        return
                    }
                    
                    let length = parsed[1]
                    let type = parsed[2]
                    let jsonData = parsed[3].dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
                    
                    if type != "0" {
                        NSLog("Error handshaking")
                        return
                    }
                    
                    self?.connected = true
                    
                    if let json = NSJSONSerialization.JSONObjectWithData(jsonData!,
                        options: NSJSONReadingOptions.AllowFragments, error: &err) as? NSDictionary {
                            if let sid = json["sid"] as? String {
                                // println(json)
                                self?.sid = sid
                                
                                if !self!.forcePolling {
                                    self?.ws = SRWebSocket(URL:
                                        NSURL(string: urlWebSocket + "&sid=\(self!.sid)")!)
                                    self?.ws?.delegate = self
                                    self?.ws?.open()
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
                }
        }
    }
    
    // Translatation of engine.io-parser#decodePayload
    private func parsePollingMessage(str:String) {
        if str.length == 1 {
            return
        }
        
        // println(str)
        
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
            let strArray = Array(str)
            let chr = String(strArray[i])
            
            if chr != ":" {
                length += chr
            } else {
                if length == "" || testLength(length, &n) {
                    self.handlePollingFailed(nil)
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
                    fixSwift = msg
                    self.parseEngineMessage(fixSwift)
                }
                
                i += n
                length = ""
            }
        }
    }
    
    private func parseEngineMessage(message:AnyObject?) {
        // println(message)
        if let data = message as? NSData {
            // Strip off message type
            self.client.parseSocketMessage(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
            return
        }
        
        var messageString = message as String
        var strMessage = RegexMutable(messageString)
        
        // We should upgrade
        if strMessage == "3probe" {
            self.upgradeTransport()
            return
        }
        
        let type = strMessage["^(\\d)"].groups()?[1]
        
        if type != PacketType.MESSAGE.rawValue {
            // TODO Handle other packets
            if messageString.hasPrefix("b4") {
                // binary in base64 string
                messageString.removeRange(Range<String.Index>(start: messageString.startIndex,
                    end: advance(messageString.startIndex, 2)))
                
                if let data = NSData(base64EncodedString: messageString,
                    options: NSDataBase64DecodingOptions.IgnoreUnknownCharacters) {
                        // println("sending \(data)")
                        self.client.parseSocketMessage(data)
                }
                
                return
            }
            
            if messageString == PacketType.CLOSE.rawValue {
                // do nothing
                return
            }
            // println("Got something idk what to do with")
            // println(messageString)
        }
        
        // Remove message type
        messageString.removeAtIndex(messageString.startIndex)
        // println("sending \(messageString)")
        
        self.client.parseSocketMessage(messageString)
    }
    
    private func probeWebSocket() {
        if self.websocketConnected {
            self.sendWebSocketMessage("probe", withType: PacketType.PING)
        }
    }
    
    func send(msg:String, datas:[NSData]? = nil) {
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
        // println("sending ping")
        
        if self.websocket {
            self.sendWebSocketMessage("", withType: PacketType.PING)
        } else {
            self.sendPollMessage("", withType: PacketType.PING)
        }
    }
    
    private func sendPollMessage(msg:String, withType type:PacketType, datas:[NSData]? = nil) {
        // println("Sending: \(msg)")
        var postData:NSData
        var bDatas:[String]?
        
        if datas != nil {
            bDatas = [String]()
            for data in datas! {
                let (nilData, b64Data) = self.createBinaryDataForSend(data)
                let dataLen = countElements(b64Data!)
                
                bDatas!.append("\(dataLen):\(b64Data!)")
            }
        }
        
        let strMsg = "\(type.rawValue)\(msg)"
        let postCount = countElements(strMsg)
        var postStr = "\(postCount):\(strMsg)"
        
        if bDatas != nil {
            for data in bDatas! {
                postStr += data
            }
        }
        
        self.postWait.append(postStr)
        
        if waitingForPost {
            self.doPoll()
            return
        } else {
            self.flushWaitingForPost()
        }
    }
    
    private func sendWebSocketMessage(str:String, withType type:PacketType, datas:[NSData]? = nil) {
        self.ws?.send("\(type.rawValue)\(str)")
        
        if datas != nil {
            for data in datas! {
                let (data, nilString) = self.createBinaryDataForSend(data)
                if data != nil {
                    self.ws?.send(data!)
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
            self.probing = false
            self._websocket = true
            self.waitingForPoll = false
            self._polling = false
            self.sendWebSocketMessage("", withType: PacketType.UPGRADE)
            self.flushProbeWait()
        }
    }
    
    // Called when a message is recieved
    func webSocket(webSocket:SRWebSocket!, didReceiveMessage message:AnyObject?) {
        // println(message)
        
        dispatch_async(self.handleQueue) {[weak self] in
            self?.parseEngineMessage(message)
            return
        }
    }
    
    // Called when the socket is opened
    func webSocketDidOpen(webSocket:SRWebSocket!) {
        self.websocketConnected = true
        self.probing = true
        self.probeWebSocket()
    }
    
    // Called when the socket is closed
    func webSocket(webSocket:SRWebSocket!, didCloseWithCode code:Int, reason:String!, wasClean:Bool) {
        self.websocketConnected = false
        self.probing = false
        
        if self.websocket {
            self.pingTimer?.invalidate()
            self.connected = false
            self._websocket = false
            self._polling = true
            self.client.webSocketDidCloseWithCode(code, reason: reason, wasClean: wasClean)
        } else {
            self.flushProbeWait()
        }
    }
    
    // Called when an error occurs.
    func webSocket(webSocket:SRWebSocket!, didFailWithError error:NSError!) {
        self.websocketConnected = false
        self._polling = true
        self.probing = false
        
        if self.websocket {
            self.pingTimer?.invalidate()
            self.connected = false
            self.client.webSocketDidFailWithError(error)
        } else {
            self.flushProbeWait()
        }
    }
}