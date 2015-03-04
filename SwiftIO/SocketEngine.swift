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
    private var pingTimer:NSTimer?
    private let pollingQueue = NSOperationQueue()
    private var _polling = true
    private var _websocket = false
    private var websocketConnected = false
    var pingInterval:Int?
    var polling:Bool {
        return self._polling
    }
    var sid = ""
    var websocket:Bool {
        return self._websocket
    }
    var ws:SRWebSocket?
    
    init(client:SocketIOClient) {
        self.client = client
    }
    
    func open(opts:[String: AnyObject]? = nil) {
        var url:String
        var urlPolling:String
        var urlWebSocket:String
        
        if self.client.secure {
            url = "\(self.client.socketURL)/socket.io/?transport="
            urlPolling = "https://" + url + "polling"
            urlWebSocket = "wss://" + url + "websocket"
        } else {
            url = "\(self.client.socketURL)/socket.io/?transport="
            urlPolling = "http://" + url + "polling"
            urlWebSocket = "ws://" + url + "websocket"
        }
        
        let reqPolling = NSURLRequest(URL: NSURL(string: urlPolling)!)
        
        NSURLConnection.sendAsynchronousRequest(reqPolling, queue: self.pollingQueue) {[weak self] res, data, err in
            var err:NSError?
            
            if self == nil || err != nil || data == nil {
                println("Error")
                println(err)
                exit(1)
            }
            
            let sub = data.subdataWithRange(NSMakeRange(5, data.length - 5))
            
            if let json = NSJSONSerialization.JSONObjectWithData(sub,
                options: NSJSONReadingOptions.AllowFragments, error: &err) as? NSDictionary {
                    println(json)
                    if let sid = json["sid"] as? String {
                        self?.sid = sid
                        
                        self?.ws = SRWebSocket(URL: NSURL(string: urlWebSocket + "&sid=\(self!.sid)")!)
                        self?.ws?.delegate = self
                        self?.ws?.open()
                        
                    } else {
                        NSLog("Error handshaking")
                        return
                    }
                    
                    if let pingInterval = json["pingInterval"] as? Int {
                        self?.pingInterval = pingInterval / 1000
                    }
            }
        }
    }
    
    func handlePollingResponse(str:String) {
        // TODO add polling
    }
    
    func parseWebSocketMessage(message:AnyObject?) {
        if !(message is String) {
            return
        }
        
        var strMessage = RegexMutable(message as String)
        
        // We should upgrade
        if strMessage == "3probe" {
            self.upgradeTransport()
            return
        }
        
        let type = strMessage["(\\d)"].matches()[0]
        
        if type != PacketType.MESSAGE.rawValue {
            // TODO Handle other packets
            return
        }
    }
    
    func probeWebSocket() {
        if self.websocketConnected {
            self.ws?.send("2probe")
        }
    }
    
    func sendPing() {
        if self.websocketConnected {
            self.ws?.send(PacketType.PING.rawValue)
        }
    }
    
    // Starts the ping timer
    private func startPingTimer() {
        if self.pingInterval == nil {
            return
        }
        
        dispatch_async(dispatch_get_main_queue()) {
            self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(self.pingInterval!), target: self,
                selector: Selector("sendPing"), userInfo: nil, repeats: true)
        }
    }
    
    private func upgradeTransport() {
        if self.websocketConnected {
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
    }
    
    // Called when an error occurs.
    func webSocket(webSocket:SRWebSocket!, didFailWithError error:NSError!) {
        self.pingTimer?.invalidate()
        self.websocketConnected = false
    }
}