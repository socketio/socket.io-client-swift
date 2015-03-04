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
    private var pollingTimer:NSTimer?
    private var _polling = true
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
        self.pollingTimer?.invalidate()
        
        if websocketConnected {
            self.ws?.send(PacketType.MESSAGE.rawValue + PacketType.CLOSE.rawValue)
            self.ws?.close()
        }
    }
    
    private func createURLs(params:[String: AnyObject]? = nil) -> (String, String) {
        var url = "\(self.client.socketURL)/socket.io/?transport="
        var urlPolling:String
        var urlWebSocket:String
        let time = Int(NSDate().timeIntervalSince1970 * 1000)
        
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
        if self.urlPolling == nil || self.websocket {
            return
        }
        
        let time = Int(NSDate().timeIntervalSince1970)
        let req = NSURLRequest(URL: NSURL(string: self.urlPolling! + "&t=\(time)-0&b64=1" + "&sid=\(self.sid)")!)
        
        NSURLConnection.sendAsynchronousRequest(req, queue: self.pollingQueue) {[weak self] res, data, err in
            if self == nil {
                return
            }
            
            if err != nil {
                println(err)
                return
            }
            
            let str = NSString(data: data, encoding: NSUTF8StringEncoding)
            
            println(str)
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
                    println("Error")
                    println(err)
                    if !self!.client.reconnecting {
                        self?.client.tryReconnect(triesLeft: self!.client.reconnectAttempts)
                    }
                    return
                }
                
                if let dataString = NSString(data: data, encoding: NSUTF8StringEncoding) {
                    var mutString = RegexMutable(dataString)
                    
                    let parsed = mutString["(\\d*):(\\d)(\\{.*\\})?"].groups()
                    
                    if parsed.count == 4 {
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
                                    self?.sid = sid
                                    
                                    self?.ws = SRWebSocket(URL: NSURL(string: urlWebSocket + "&sid=\(self!.sid)")!)
                                    self?.ws?.delegate = self
                                    //self?.ws?.open()
                                    
                                } else {
                                    NSLog("Error handshaking")
                                    return
                                }
                                
                                if let pingInterval = json["pingInterval"] as? Int {
                                    self?.pingInterval = pingInterval / 1000
                                }
                        }
                    }
                    
                    self?.doPoll()
                    self?.startPingTimer()
                }
        }
    }
    
    func handlePollingResponse(str:String) {
        // TODO add polling
    }
    
    func parseWebSocketMessage(message:AnyObject?) {
        if let data = message as? NSData {
            // Strip off message type
            self.client.parseSocketMessage(data.subdataWithRange(NSMakeRange(1, data.length - 1)))
            return
        }
        
        var message = message as String
        var strMessage = RegexMutable(message)
        
        // We should upgrade
        if strMessage == "3probe" {
            self.upgradeTransport()
            self.pollingTimer?.invalidate()
            return
        }
        
        let type = strMessage["(\\d)"].matches()[0]
        
        if type != PacketType.MESSAGE.rawValue {
            // TODO Handle other packets
            return
        }
        
        message.removeAtIndex(message.startIndex)
        self.client.parseSocketMessage(message)
    }
    
    func probeWebSocket() {
        if self.websocketConnected {
            self.ws?.send("2probe")
        }
    }
    
    func send(msg:AnyObject) {
        if self.websocketConnected {
            if !(msg is NSData) {
                self.ws?.send("\(PacketType.MESSAGE.rawValue)\(msg)")
            } else {
                self.ws?.send(msg)
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
            var req = NSMutableURLRequest(URL: NSURL(string: self.urlPolling! + "&t=\(time)-0&b64=1" + "&sid=\(self.sid)")!)
            let postStr = "1:\(PacketType.PING.rawValue)"
            let postData = postStr.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
            let postLength = "\(postData.length)"
            
            req.HTTPMethod = "POST"
            req.setValue(postLength, forHTTPHeaderField: "Content-Length")
            req.setValue("application/html-text", forHTTPHeaderField: "Content-Type")
            req.HTTPBody = postData
            
            NSURLConnection.sendAsynchronousRequest(req, queue: self.pollingQueue) {[weak self] res, data, err in
                if err != nil {
                    println(err)
                    self?.pingTimer?.invalidate()
                    if !self!.client.reconnecting {
                        self?.client.tryReconnect(triesLeft: self!.client.reconnectAttempts)
                    }
                    return
                }
                
                self?.doPoll()
            }
        }
    }
    
    func sendPollMessage(msg:AnyObject) {
        
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
        
        self.parseWebSocketMessage(message)
    }
    
    // Called when the socket is opened
    func webSocketDidOpen(webSocket:SRWebSocket!) {
        println("socket opened")
        self.startPingTimer()
        self.websocketConnected = true
        self.probeWebSocket()
    }
    
    // Called when the socket is closed
    func webSocket(webSocket:SRWebSocket!, didCloseWithCode code:Int, reason:String!, wasClean:Bool) {
        println("socket closed")
        self.pingTimer?.invalidate()
        self.websocketConnected = false
        
        // Temp
        self.client.webSocket(webSocket, didCloseWithCode: code, reason: reason, wasClean: wasClean)
    }
    
    // Called when an error occurs.
    func webSocket(webSocket:SRWebSocket!, didFailWithError error:NSError!) {
        self.pingTimer?.invalidate()
        self.websocketConnected = false
        
        // Temp
        self.client.webSocket(webSocket, didFailWithError: error)
    }
}