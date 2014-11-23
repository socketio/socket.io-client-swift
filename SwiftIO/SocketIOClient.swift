//
//  SocketIOClient.swift
//  Socket.IO-Swift
//
//  Created by Erik Little on 11/23/14.
//

import Foundation

private class EventHandler: NSObject {
    let event:String!
    let callback:((data:Any?) -> Void)!
    
    init(event:String, callback:((data:Any?) -> Void)?) {
        self.event = event
        self.callback = callback
    }
    
    func executeCallback(args:Any?) {
        if (args != nil) {
            callback(data: args!)
        } else {
            callback(data: nil)
        }
    }
}

private struct socketMessage {
    var event:String!
    var args:AnyObject!
    
    init(event:String, args:AnyObject?) {
        self.event = event
        self.args = args?
    }
    
    func createMessage() -> String {
        var array = "42["
        array += "\"" + event + "\""
        if (args? != nil) {
            if (args is NSDictionary) {
                array += ","
                var jsonSendError:NSError?
                var jsonSend = NSJSONSerialization.dataWithJSONObject(args,
                    options: NSJSONWritingOptions(0), error: &jsonSendError)
                var jsonString = NSString(data: jsonSend!, encoding: NSUTF8StringEncoding)
                return array + jsonString! + "]"
            } else {
                array += ",\"\(args!)\""
                return array + "]"
            }
        } else {
            return array + "]"
        }
    }
}

class SocketIOClient: NSObject, SRWebSocketDelegate {
    let session:NSURLSession?
    let socketURL:String!
    var connected = false
    var connecting = false
    private var handlers = [EventHandler]()
    var io:SRWebSocket?
    var pingTimer:NSTimer!
    var secure = false
    
    init(socketURL:String, secure:Bool = false) {
        let sessionConfig:NSURLSessionConfiguration = NSURLSessionConfiguration.defaultSessionConfiguration()
        sessionConfig.allowsCellularAccess = true
        sessionConfig.HTTPAdditionalHeaders = ["Content-Type": "application/json"]
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        sessionConfig.HTTPMaximumConnectionsPerHost = 1
        
        self.session = NSURLSession(configuration: sessionConfig)
        var mutURL = RegexMutable(socketURL)
        mutURL = mutURL["http://"] ~= ""
        mutURL = mutURL["https://"] ~= ""
        self.socketURL = mutURL
        self.secure = secure
    }
    
    // Closes the socket
    func close() {
        self.pingTimer?.invalidate()
        self.connecting = false
        self.connected = false
        self.io?.close()
    }
    
    // Connects to the server
    func connect() {
        self.connecting = true
        var endpoint:String!
        if (self.secure) {
            endpoint = "wss://\(self.socketURL)/socket.io/?EIO=2&transport=websocket"
        } else {
            endpoint = "ws://\(self.socketURL)/socket.io/?EIO=2&transport=websocket"
        }
        self.io = SRWebSocket(URL: NSURL(string: endpoint))
        self.io?.delegate = self
        self.io?.open()
    }
    
    // Sends a message
    func emit(event:String, args:AnyObject? = nil) {
        if (!self.connected) {
            return
        }
        
        let frame = socketMessage(event: event, args: args)
        let str = frame.createMessage()
        
        println("Sending: \(str)")
        self.io?.send(str)
    }
    
    // Handles events
    func handleEvent(#event:String, data:Any?) {
        println("Should do event: \(event) with data: \(data)")
        
        for handler in self.handlers {
            if (handler.event == event) {
                if (data != nil) {
                    handler.executeCallback(data)
                } else {
                    handler.executeCallback(nil)
                }
            }
        }

    }
    
    // Adds handlers to the socket
    func on(name:String, callback:((data:Any?) -> Void)?) {
        let handler = EventHandler(event: name, callback: callback)
        self.handlers.append(handler)
    }
    
    // Opens the connection to the socket
    func open() {
        self.connect()
    }
    
    // Parses messages recieved
    private func parseSocketMessage(#message:AnyObject?) {
        if (message == nil) {
            // TODO handle nil
            return
        }
        
        if let stringMessage = message as? String {
            /**
            Begin check for socket info frame
            **/
            var mutMessage = RegexMutable(stringMessage)
            var setup:String!
            let messageData = mutMessage["(\\d*)(\\{.*\\})?"].groups()
            if (messageData != nil && messageData[1] == "0") {
                setup = messageData[2]
                let data = setup.dataUsingEncoding(NSUTF8StringEncoding)!
                var jsonError:NSError?
                if let json:AnyObject? = NSJSONSerialization.JSONObjectWithData(data,
                    options: nil, error: &jsonError) {
                        self.startPingTimer(interval: (json!["pingInterval"] as Int) / 1000)
                        return
                }
            }
            /**
            End check for socket info frame
            **/
            
            let messageGroups = mutMessage["(\\d*)(\\[.*\\])?"].groups()
            if (messageGroups.count == 3 && messageGroups[1] == "42") {
                let messagePart = messageGroups[2]
                let messageInternals = RegexMutable(messagePart)["\\[\"(.*?)\",?(.*?)?(,.*)?\\]"].groups()
                if (messageInternals != nil && messageInternals.count > 2) {
                    let event = messageInternals[1]
                    var data:Any!
                    if (messageInternals[2] == "") {
                        data = nil
                    } else {
                        data = messageInternals[2]

                    }
                    self.handleEvent(event: event, data: data)
                }
            }
        }
    }
    
    // Sends ping
    func sendPing() {
        if (!self.connected) {
            return
        }
        self.io?.send("2")
    }
    
    // Starts the ping timer
    func startPingTimer(#interval:Int) {
        self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(interval), target: self,
            selector: Selector("sendPing"), userInfo: nil, repeats: true)
    }
    
    // Called when a message is recieved
    func webSocket(webSocket: SRWebSocket!, didReceiveMessage message:AnyObject?) {
        // println(message)
        self.parseSocketMessage(message: message)
    }
    
    // Called when the socket is opened
    func webSocketDidOpen(webSocket: SRWebSocket!) {
        self.connecting = false
        self.connected = true
        self.handleEvent(event: "connect", data: nil)
    }
    
    // Called when the socket is closed
    func webSocket(webSocket: SRWebSocket!, didCloseWithCode code: Int, reason: String!, wasClean: Bool) {
        self.connected = false
        self.connecting = false
        self.handleEvent(event: "disconnect", data: reason)
    }
}