//
//  SocketIOClient.swift
//  Socket.IO-Swift
//
//  Created by Erik Little on 11/23/14.
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

private class EventHandler: NSObject {
    let event:String!
    let callback:((data:AnyObject?) -> Void)!
    
    init(event:String, callback:((data:AnyObject?) -> Void)?) {
        self.event = event
        self.callback = callback
    }
    
    func executeCallback(args:AnyObject?) {
        if args != nil {
            callback(data: args!)
        } else {
            callback(data: nil)
        }
    }
}

private class Event {
    var args:AnyObject!
    var currentPlace = 0
    var event:String!
    lazy var datas = [NSData]()
    var placeholders:Int!
    
    init(event:String, args:AnyObject?, placeholders:Int = 0) {
        self.event = event
        self.args = args?
        self.placeholders = placeholders
    }
    
    func addData(data:NSData) -> Bool {
        func checkDoEvent() -> Bool {
            if self.placeholders == self.currentPlace {
                return true
            } else {
                return false
            }
        }
        
        if checkDoEvent() {
            return true
        }
        
        self.datas.append(data)
        self.currentPlace++
        
        if checkDoEvent() {
            self.currentPlace = 0
            return true
        } else {
            return false
        }
    }
    
    func createMessage() -> String {
        var array = "42["
        array += "\"" + event + "\""
        
        if args? != nil {
            if args is NSDictionary {
                array += ","
                var jsonSendError:NSError?
                var jsonSend = NSJSONSerialization.dataWithJSONObject(args as NSDictionary,
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
    
    func createBinaryMessage() -> String {
        var array = "45\(self.placeholders)-["
        array += "\"" + event + "\""
        if args? != nil {
            if args is NSDictionary {
                array += ","
                var jsonSendError:NSError?
                var jsonSend = NSJSONSerialization.dataWithJSONObject(args as NSDictionary,
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
    
    func fillInPlaceholders(args:AnyObject) -> AnyObject {
        if let dict = args as? NSDictionary {
            var newDict = [String: AnyObject]()
            
            for (key, value) in dict {
                newDict[key as String] = value
                
                // If the value is a string we need to check
                // if it is a placeholder for data
                if let value = value as? String {
                    if value == "~~\(self.currentPlace)" {
                        newDict[key as String] = self.datas.removeAtIndex(0)
                        self.currentPlace++
                    }
                }
            }
            
            return newDict
        } else if let string = args as? String {
            if string == "~~\(self.currentPlace)" {
                return self.datas.removeAtIndex(0)
            }
        }
        
        return false
    }
}

class SocketIOClient: NSObject, SRWebSocketDelegate {
    let socketURL:String!
    let secure:Bool!
    private var handlers = [EventHandler]()
    private var lastSocketMessage:Event?
    var connected = false
    var connecting = false
    var io:SRWebSocket?
    var pingTimer:NSTimer!
    var reconnnects = true
    var reconnecting = false
    var reconnectAttempts = -1
    var reconnectWait = 10
    
    init(socketURL:String, opts:[String: AnyObject]? = nil) {
        super.init()
        var mutURL = RegexMutable(socketURL)
        
        if mutURL["https://"].matches().count != 0 {
            self.secure = true
        } else {
            self.secure = false
        }
        mutURL = mutURL["http://"] ~= ""
        mutURL = mutURL["https://"] ~= ""
        self.socketURL = mutURL
        
        // Set options
        if opts != nil {
            if let reconnects = opts!["reconnects"] as? Bool {
                self.reconnnects = reconnects
            }
            
            if let reconnectAttempts = opts!["reconnectAttempts"] as? Int {
                self.reconnectAttempts = reconnectAttempts
            }
            
            if let reconnectWait = opts!["reconnectWait"] as? Int {
                self.reconnectWait = abs(reconnectWait)
            }
        }
    }
    
    // Closes the socket
    func close() {
        self.pingTimer?.invalidate()
        self.connecting = false
        self.connected = false
        self.reconnnects = false
        self.io?.close()
    }
    
    // Connects to the server
    func connect() {
        self.connecting = true
        var endpoint:String!
        
        if self.secure! {
            endpoint = "wss://\(self.socketURL)/socket.io/?EIO=2&transport=websocket"
        } else {
            endpoint = "ws://\(self.socketURL)/socket.io/?EIO=2&transport=websocket"
        }
        
        self.io = SRWebSocket(URL: NSURL(string: endpoint))
        self.io?.delegate = self
        self.io?.open()
    }
    
    // Creates a binary message, ready for sending
    private func createBinaryDataForSend(data:NSData) -> NSData {
        var byteArray = [UInt8](count: 1, repeatedValue: 0x0)
        byteArray[0] = 4
        var mutData = NSMutableData(bytes: &byteArray, length: 1)
        mutData.appendData(data)
        return mutData
    }
    
    // Sends a message
    func emit(event:String, args:AnyObject? = nil) {
        if !self.connected {
            return
        }
        
        var frame:Event!
        var str:String!
        
        if let dict = args as? NSDictionary {
            // Check for binary data
            let (newDict, hadBinary, binaryDatas) = self.parseNSDictionary(dict: dict)
            if hadBinary {
                frame = Event(event: event, args: newDict, placeholders: binaryDatas!.count)
                str = frame.createBinaryMessage()
                self.io?.send(str)
                
                for data in binaryDatas! {
                    let sendData = self.createBinaryDataForSend(data)
                    self.io?.send(sendData)
                }
                
                return
            }
        } else if let binaryData = args as? NSData {
            // args is just binary
            frame = Event(event: event, args: ["_placeholder": true, "num": 0], placeholders: 1)
            str = frame.createBinaryMessage()
            self.io?.send(str)
            let sendData = self.createBinaryDataForSend(binaryData)
            self.io?.send(sendData)
            
            return
        }
        
        frame = Event(event: event, args: args)
        str = frame.createMessage()
        
        // println("Sending: \(str)")
        self.io?.send(str)
    }
    
    // Handles events
    func handleEvent(#event:String, var data:AnyObject?) {
        // println("Should do event: \(event) with data: \(data)")
        // data = parseData(data as? String)
        for handler in self.handlers {
            if handler.event == event {
                if data == nil {
                    handler.executeCallback(nil)
                    continue
                }
                
                handler.executeCallback(data)
            }
        }
    }
    
    // Adds handlers to the socket
    func on(name:String, callback:((data:AnyObject?) -> Void)?) {
        let handler = EventHandler(event: name, callback: callback)
        self.handlers.append(handler)
    }
    
    // Opens the connection to the socket
    func open() {
        self.connect()
    }
    
    // Parses data for events
    private func parseData(data:String?) -> AnyObject? {
        if data == nil {
            return nil
        }
        
        var err:NSError?
        let stringData = data!.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
        let parsed:AnyObject? = NSJSONSerialization.JSONObjectWithData(stringData!,
            options: NSJSONReadingOptions.AllowFragments, error: &err)
        
        if err != nil {
            // println(err)
            return nil
        }
        
        return parsed
    }
    
    // Parses a NSDictionary, looking for NSData objects
    private func parseNSDictionary(#dict:NSDictionary) -> (NSDictionary, Bool, [NSData]?) {
        var returnDict = NSMutableDictionary()
        var placeholder = 0
        var containedData = false
        var returnDatas = [NSData]()
        for (key, value) in dict {
            if let binaryData = value as? NSData {
                containedData = true
                returnDatas.append(binaryData)
                returnDict[key as String] = ["_placeholder": true, "num": placeholder]
                placeholder++
            } else {
                returnDict[key as String] = value
            }
        }
        
        if containedData {
            return (returnDict, true, returnDatas)
        } else {
            return (returnDict, false, nil)
        }
    }
    
    // Parses messages recieved
    private func parseSocketMessage(#message:AnyObject?) {
        if message == nil {
            return
        }
        
        // println(message!)
        
        if let stringMessage = message as? String {
            /**
            Begin check for socket info frame
            **/
            var mutMessage = RegexMutable(stringMessage)
            var setup:String!
            let messageData = mutMessage["(\\d*)(\\{.*\\})?"].groups()
            if messageData != nil && messageData[1] == "0" {
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
            
            /**
            Begin check for message
            **/
            let messageGroups = mutMessage["(\\d*)(\\[.*\\])?"].groups()
            if messageGroups.count == 3 && messageGroups[1] == "42" {
                let messagePart = messageGroups[2]
                let messageInternals = RegexMutable(messagePart)["\\[\"(.*?)\",(.*?)?\\]$"].groups()
                if messageInternals != nil && messageInternals.count > 2 {
                    let event = messageInternals[1]
                    var data:String?
                    
                    if messageInternals[2] == "" {
                        data = nil
                    } else {
                        data = messageInternals[2]
                    }
                    
                    if let json:AnyObject = self.parseData(data) {
                        self.handleEvent(event: event, data: json)
                        return
                    }
                    
                    self.handleEvent(event: event, data: data)
                    return
                }
            }
            /**
            End Check for message
            **/
            
            // Check for message with binary placeholders
            self.parseBinaryMessage(message: message!)
        }
        
        // Message is binary
        if let binary = message as? NSData {
            self.parseBinaryData(binary)
        }
    }
    
    // Tries to parse a message that contains binary
    func parseBinaryMessage(#message:AnyObject) {
        if let stringMessage = message as? String {
            var mutMessage = RegexMutable(stringMessage)
            
            /**
            Begin check for binary placeholder
            **/
            let binaryGroup = mutMessage["(\\d*)-\\[\"(.*)\",(\\{.*\\})\\]$"].groups()
            
            // println(binaryGroup)
            if binaryGroup != nil {
                let messageType = RegexMutable(binaryGroup[1])
                let numberOfPlaceholders = messageType["45"] ~= ""
                let event = binaryGroup[2]
                let mutMessageObject = RegexMutable(binaryGroup[3])
                let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
                let mes = Event(event: event, args: placeholdersRemoved,
                    placeholders: numberOfPlaceholders.integerValue)
                self.lastSocketMessage = mes
                return
            }
            /**
            End check for binary placeholder
            **/
        }
    }
    
    // Handles binary data
    func parseBinaryData(data:NSData) {
        if self.lastSocketMessage == nil {
            return
        }
        
        let shouldExecute = self.lastSocketMessage?.addData(data)
        
        if shouldExecute != nil && shouldExecute! {
            var event = self.lastSocketMessage!.event
            var parsedArgs:AnyObject? = self.parseData(self.lastSocketMessage!.args as? String)
            if let args:AnyObject = parsedArgs {
                let filledInArgs:AnyObject = self.lastSocketMessage!.fillInPlaceholders(args)
                self.handleEvent(event: event, data: filledInArgs)
            }
        }
    }
    
    // Sends ping
    func sendPing() {
        if self.connected {
            self.io?.send("2")
        }
    }
    
    // Starts the ping timer
    private func startPingTimer(#interval:Int) {
        self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(interval), target: self,
            selector: Selector("sendPing"), userInfo: nil, repeats: true)
    }
    
    // We lost connection and should attempt to reestablish
    private func tryReconnect(var #triesLeft:Int) {
        if triesLeft != -1 && triesLeft <= 0 {
            self.connecting = false
            self.reconnnects = false
            self.reconnecting = false
            self.handleEvent(event: "disconnect", data: "Failed to reconnect")
            return
        } else if self.connected {
            self.connecting = false
            self.reconnecting = false
            return
        }
        
        // println("Trying to reconnect #\(reconnectAttempts - triesLeft)")
        self.handleEvent(event: "reconnectAttempt", data: triesLeft)
        
        let waitTime = UInt64(self.reconnectWait) * NSEC_PER_SEC
        let time = dispatch_time(DISPATCH_TIME_NOW, Int64(waitTime))
        
        // Wait reconnectWait seconds and then check if connected. Repeat if not
        dispatch_after(time, dispatch_get_main_queue()) {[weak self] in
            if self == nil || self!.connected {
                return
            }
            
            if triesLeft != -1 {
                triesLeft = triesLeft - 1
            }
            
            self!.tryReconnect(triesLeft: triesLeft)
        }
        self.reconnecting = true
        self.connect()
    }
    
    // Called when a message is recieved
    func webSocket(webSocket:SRWebSocket!, didReceiveMessage message:AnyObject?) {
        // println(message)
        self.parseSocketMessage(message: message)
    }
    
    // Called when the socket is opened
    func webSocketDidOpen(webSocket:SRWebSocket!) {
        self.connecting = false
        self.reconnecting = false
        self.connected = true
        self.handleEvent(event: "connect", data: nil)
    }
    
    // Called when the socket is closed
    func webSocket(webSocket:SRWebSocket!, didCloseWithCode code:Int, reason:String!, wasClean:Bool) {
        self.pingTimer?.invalidate()
        self.connected = false
        self.connecting = false
        if !self.reconnnects {
            self.handleEvent(event: "disconnect", data: reason)
        } else {
            self.handleEvent(event: "reconnect", data: reason)
            self.tryReconnect(triesLeft: self.reconnectAttempts)
            
        }
    }
    
    func webSocket(webSocket:SRWebSocket!, didFailWithError error:NSError!) {
        self.pingTimer?.invalidate()
        self.connected = false
        self.connecting = false
        if !self.reconnnects {
            self.handleEvent(event: "disconnect", data: error.localizedDescription)
        } else if !self.reconnecting {
            self.handleEvent(event: "reconnect", data: error.localizedDescription)
            self.tryReconnect(triesLeft: self.reconnectAttempts)
        }
    }
}