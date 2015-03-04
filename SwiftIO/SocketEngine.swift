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
    private let pollingQueue = NSOperationQueue()
    private var pingTimer:NSTimer?
    private var _polling = true
    private var wait = false
    private var _websocket = false
    private var websocketConnected = false
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
    
    init(client:SocketIOClient) {
        self.client = client
    }
    
    func close() {
        self.pingTimer?.invalidate()
        
        if self.websocket {
            self.ws?.send(PacketType.MESSAGE.rawValue + PacketType.CLOSE.rawValue)
            self.ws?.close()
        } else {
            // TODO handling polling
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
    
    func doPoll() {
        if self.urlPolling == nil || self.websocket || self.wait {
            return
        }
        
        let time = Int(NSDate().timeIntervalSince1970)
        let req = NSURLRequest(URL:
            NSURL(string: self.urlPolling! + "&t=\(time)-0&b64=1" + "&sid=\(self.sid)")!)
        self.wait = true
        
        NSURLConnection.sendAsynchronousRequest(req,
            queue: self.pollingQueue) {[weak self] res, data, err in
                if self == nil {
                    return
                } else if err != nil {
                    // println(err)
                    self?.handlePollingFailed()
                    return
                }
                
                // println(data)
                
                if let str = NSString(data: data, encoding: NSUTF8StringEncoding) {
                    // println(str)
                    
                    self?.parsePollingMessage(str)
                }
                
                self?.wait = false
                self?.doPoll()
        }
    }
    
    func open(opts:[String: AnyObject]? = nil) {
        let (urlPolling, urlWebSocket) = self.createURLs(params: opts)
        
        self.urlPolling = urlPolling
        self.urlWebSocket = urlWebSocket
        let time = Int(NSDate().timeIntervalSince1970)
        let reqPolling = NSURLRequest(URL: NSURL(string: urlPolling + "&t=\(time)-0&b64=1")!)
        
        NSURLConnection.sendAsynchronousRequest(reqPolling,
            queue: self.pollingQueue) {[weak self] res, data, err in
                var err:NSError?
                if self == nil {
                    return
                } else if err != nil || data == nil {
                    // println(err)
                    self?.handlePollingFailed()
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
                    
                    if let json = NSJSONSerialization.JSONObjectWithData(jsonData!,
                        options: NSJSONReadingOptions.AllowFragments, error: &err) as? NSDictionary {
                            if let sid = json["sid"] as? String {
                                // println(json)
                                self?.sid = sid
                                
                                self?.ws = SRWebSocket(URL:
                                    NSURL(string: urlWebSocket + "&sid=\(self!.sid)")!)
                                self?.ws?.delegate = self
                                // self?.ws?.open()
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
    
    // A poll failed, try and reconnect
    private func handlePollingFailed() {
        if !self.client.reconnecting {
            self.pingTimer?.invalidate()
            self.wait = false
            self.client.handleEvent("reconnect", data: "XHR polling timeout", isInternalMessage: true)
            self.client.tryReconnect(triesLeft: self.client.reconnectAttempts)
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
        
        for var i = 0, l = str.length; i < l; i++ {
            let strArray = Array(str)
            let chr = String(strArray[i])
            
            if chr != ":" {
                length += chr
            } else {
                if  testLength(length, &n) || length == "" {
                    println("parsing error at testlength")
                    exit(1)
                }
                
                msg = String(strArray[i+1...i+n])
                
                if let lengthInt = length.toInt() {
                    if lengthInt != msg.length {
                        println("parsing error")
                        exit(1)
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
                        self.client.parseSocketMessage(data)
                }
                
                return
            }
            
            println("Got something idk what to do with")
            println(messageString)
        }
        
        // Remove message type
        messageString.removeAtIndex(messageString.startIndex)
        self.client.parseSocketMessage(messageString)
    }
    
    func probeWebSocket() {
        if self.websocketConnected {
            self.ws?.send("2probe")
        }
    }
    
    func send(msg:AnyObject) {
        if self.websocket {
            if !(msg is NSData) {
                self.ws?.send("\(PacketType.MESSAGE.rawValue)\(msg)")
            } else {
                let (data, nilString) = self.createBinaryDataForSend(msg as NSData)
                self.ws?.send(data!)
            }
        } else {
            self.sendPollMessage(msg)
        }
    }
    
    func sendPing() {
        if self.websocket {
            self.ws?.send(PacketType.PING.rawValue)
        } else {
            let time = Int(NSDate().timeIntervalSince1970)
            var req = NSMutableURLRequest(URL: NSURL(string:
                self.urlPolling! + "&t=\(time)-0&b64=1" + "&sid=\(self.sid)")!)
            let postStr = "1:\(PacketType.PING.rawValue)"
            let postData = postStr.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
            let postLength = "\(postData.length)"
            
            req.HTTPMethod = "POST"
            req.setValue(postLength, forHTTPHeaderField: "Content-Length")
            req.setValue("application/html-text", forHTTPHeaderField: "Content-Type")
            req.HTTPBody = postData
            
            NSURLConnection.sendAsynchronousRequest(req,
                queue: self.pollingQueue) {[weak self] res, data, err in
                    if self == nil {
                        return
                    } else if err != nil {
                        println(err)
                        self?.handlePollingFailed()
                        return
                    }
                    
                    self?.doPoll()
            }
        }
    }
    
    func sendPollMessage(msg:AnyObject) {
        var postData:NSData
        let time = Int(NSDate().timeIntervalSince1970)
        var req = NSMutableURLRequest(URL:
            NSURL(string:self.urlPolling! + "&t=\(time)&b64=1" + "&sid=\(self.sid)")!)
        
        req.HTTPMethod = "POST"
        req.setValue("application/html-text", forHTTPHeaderField: "Content-Type")
        
        if msg is NSData {
            println("sending poll binary")
            let (nilData, data) = self.createBinaryDataForSend(msg as NSData)
            
            let dataLen = countElements(data!)
            postData = "\(dataLen):\(data!)".dataUsingEncoding(NSUTF8StringEncoding,
                allowLossyConversion: false)!
        } else if !(msg is String) {
            return
        } else {
            // println(msg)
            let strMsg = "\(PacketType.MESSAGE.rawValue)\(msg as String)"
            // println(strMsg)
            
            let postCount = countElements(strMsg)
            postData = ("\(postCount):\(strMsg)").dataUsingEncoding(NSUTF8StringEncoding,
                allowLossyConversion: false)!
        }
        
        req.setValue(String(postData.length), forHTTPHeaderField: "Content-Length")
        req.HTTPBody = postData
        
        NSURLConnection.sendAsynchronousRequest(req, queue: self.pollingQueue) {[weak self] res, data, err in
            if err != nil {
                println(err)
                return
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
            self._websocket = true
            self._polling = false
            self.ws?.send(PacketType.UPGRADE.rawValue)
        }
    }
    
    // Called when a message is recieved
    func webSocket(webSocket:SRWebSocket!, didReceiveMessage message:AnyObject?) {
        // println(message)
        
        self.parseEngineMessage(message)
    }
    
    // Called when the socket is opened
    func webSocketDidOpen(webSocket:SRWebSocket!) {
        self.websocketConnected = true
        self.probeWebSocket()
    }
    
    // Called when the socket is closed
    func webSocket(webSocket:SRWebSocket!, didCloseWithCode code:Int, reason:String!, wasClean:Bool) {
        self.websocketConnected = false
        self._websocket = false
        self._polling = true
        
        self.client.webSocketDidCloseWithCode(code, reason: reason, wasClean: wasClean)
    }
    
    // Called when an error occurs.
    func webSocket(webSocket:SRWebSocket!, didFailWithError error:NSError!) {
        self.websocketConnected = false
        self._websocket = false
        self._polling = true
        
        self.client.webSocketDidFailWithError(error)
    }
}