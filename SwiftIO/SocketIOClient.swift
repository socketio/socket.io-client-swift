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

typealias NormalCallback = (AnyObject?) -> Void
typealias MultipleCallback = (NSArray?) -> Void

class SocketIOClient: NSObject, SRWebSocketDelegate {
    let socketURL:NSMutableString!
    let ackQueue = dispatch_queue_create("ackQueue".cStringUsingEncoding(NSUTF8StringEncoding),
        DISPATCH_QUEUE_SERIAL)
    let handleQueue = dispatch_queue_create("handleQueue".cStringUsingEncoding(NSUTF8StringEncoding),
        DISPATCH_QUEUE_SERIAL)
    let emitQueue = dispatch_queue_create("emitQueue".cStringUsingEncoding(NSUTF8StringEncoding),
        DISPATCH_QUEUE_SERIAL)
    private var ackHandlers = [SocketAckHandler]()
    private var secure = false
    private var handlers = [SocketEventHandler]()
    private var lastSocketMessage:SocketEvent?
    private var pingTimer:NSTimer!
    var closed = false
    var connected = false
    var connecting = false
    var io:SRWebSocket?
    var nsp:String?
    var reconnects = true
    var reconnecting = false
    var reconnectAttempts = -1
    var reconnectWait = 10
    var sid:String?
    
    init(socketURL:String, opts:[String: AnyObject]? = nil) {
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
                self.reconnects = reconnects
            }
            
            if let reconnectAttempts = opts!["reconnectAttempts"] as? Int {
                self.reconnectAttempts = reconnectAttempts
            }
            
            if let reconnectWait = opts!["reconnectWait"] as? Int {
                self.reconnectWait = abs(reconnectWait)
            }
            
            if let nsp = opts!["nsp"] as? String {
                self.nsp = nsp
            }
        }
    }
    
    // Closes the socket
    func close() {
        self.pingTimer?.invalidate()
        self.closed = true
        self.connecting = false
        self.connected = false
        self.io?.close()
    }
    
    // Connects to the server
    func connect() {
        if self.closed {
            println("Warning: This socket was previvously closed. Reopening could be dangerous. Be careful.")
        }
        
        self.connecting = true
        self.closed = false
        var endpoint:String
        
        if self.secure {
            endpoint = "wss://\(self.socketURL)/socket.io/?transport=websocket"
        } else {
            endpoint = "ws://\(self.socketURL)/socket.io/?transport=websocket"
        }
        
        self.io = SRWebSocket(URL: NSURL(string: endpoint))
        self.io?.delegate = self
        self.io?.open()
    }
    
    // Creates a binary message, ready for sending
    private class func createBinaryDataForSend(data:NSData) -> NSData {
        var byteArray = [UInt8](count: 1, repeatedValue: 0x0)
        byteArray[0] = 4
        var mutData = NSMutableData(bytes: &byteArray, length: 1)
        mutData.appendData(data)
        return mutData
    }
    
    // Sends a message with multiple args
    // If a message contains binary we have to send those
    // seperately.
    func emit(event:String, _ args:AnyObject...) -> SocketAckHandler {
        if !self.connected {
            return SocketAckHandler(event: "fail")
        }
        
        let ackHandler = SocketAckHandler(event: event)
        self.ackHandlers.append(ackHandler)
        
        dispatch_async(self.emitQueue) {[weak self] in
            if self == nil {
                return
            }
            
            self?._emit(event, args)
        }
        
        return ackHandler
    }
    
    private func _emit(event:String, _ args:[AnyObject]) {
        var frame:SocketEvent
        var str:String
        
        let (items, hasBinary, emitDatas) = SocketIOClient.parseEmitArgs(args)
        
        if !self.connected {
            return
        }
        
        if hasBinary {
            str = SocketEvent.createMessageForEvent(event, withArgs: items,
                hasBinary: true, withDatas: emitDatas.count, toNamespace: self.nsp)
            
            self.io?.send(str)
            for data in emitDatas {
                self.io?.send(data)
            }
        } else {
            str = SocketEvent.createMessageForEvent(event, withArgs: items, hasBinary: false,
                withDatas: 0, toNamespace: self.nsp)
            self.io?.send(str)
        }
    }
    
    // If the server wants to know that the client received data
    private func emitAck(ack:Int, withEvent event:String, withData data:[AnyObject]?, withAckType ackType:Int) {
        dispatch_async(self.ackQueue) {[weak self] in
            if self == nil || !self!.connected || data == nil {
                return
            }
            
            let (items, hasBinary, emitDatas) = SocketIOClient.parseEmitArgs(data!)
            var str:String
            
            if !hasBinary {
                if self?.nsp == nil {
                    str = SocketEvent.createAck(ack, withEvent: event, withArgs: items, withAckType: 3, withNsp: "/")
                } else {
                    str = SocketEvent.createAck(ack, withEvent: event, withArgs: items, withAckType: 3, withNsp: self!.nsp!)
                }
                
                self?.io?.send(str)
            } else {
                if self?.nsp == nil {
                    str = SocketEvent.createAck(ack, withEvent: event, withArgs: items, withAckType: 6, withNsp: "/")
                } else {
                    str = SocketEvent.createAck(ack, withEvent: event, withArgs: items, withAckType: 6, withNsp: self!.nsp!)
                }
                
                self?.io?.send(str)
                for data in emitDatas {
                    self?.io?.send(data)
                }
            }
        }
    }
    
    // Handles events
    func handleEvent(event:String, data:AnyObject?, isInternalMessage:Bool = false,
        wantsAck ack:Int? = nil, withAckType ackType:Int = 3) {
            // println("Should do event: \(event) with data: \(data)")
            if !self.connected && !isInternalMessage {
                return
            }
            
            for handler in self.handlers {
                if handler.event == event {
                    if data is NSArray {
                        handler.executeCallback(nil, items: (data as! NSArray))
                        if ack != nil {
                            self.emitAck(ack!, withEvent: event,
                                withData: handler.ack.ackData, withAckType: ackType)
                        }
                    } else {
                        handler.executeCallback(data)
                        if ack != nil {
                            self.emitAck(ack!, withEvent: event,
                                withData: handler.ack.ackData, withAckType: ackType)
                        }
                    }
                }
            }
    }
    
    private func joinNamespace() {
        if self.nsp != nil {
            self.io?.send("40/\(self.nsp!)")
        }
    }
    
    // Adds handler for single arg message
    func on(name:String, callback:NormalCallback) -> SocketAckHandler {
        let ackHandler = SocketAckHandler(event: name)
        let handler = SocketEventHandler(event: name, callback: callback, ack: ackHandler)
        self.handlers.append(handler)
        
        return ackHandler
    }
    
    // Adds handler for multiple arg message
    func onMultipleItems(name:String, callback:MultipleCallback) -> SocketAckHandler {
        let ackHandler = SocketAckHandler(event: name)
        let handler = SocketEventHandler(event: name, callback: callback, ack: ackHandler)
        self.handlers.append(handler)
        
        return ackHandler
    }
    
    // Opens the connection to the socket
    func open() {
        self.connect()
    }
    
    // Parse an NSArray looking for binary data
    private class func parseArray(arr:NSArray, var placeholders:Int) -> (NSArray, Bool, [NSData]) {
        var replacementArr = [AnyObject](count: arr.count, repeatedValue: 1)
        var hasBinary = false
        var arrayDatas = [NSData]()
        
        if placeholders == -1 {
            placeholders = 0
        }
        
        for g in 0..<arr.count {
            if arr[g] is NSData {
                hasBinary = true
                let sendData = self.createBinaryDataForSend(arr[g] as! NSData)
                
                arrayDatas.append(sendData)
                replacementArr[g] = ["_placeholder": true,
                    "num": placeholders++]
            } else if let dict = arr[g] as? NSDictionary {
                let (nestDict, hadBinary, dictArrs) = self.parseNSDictionary(dict, placeholders: placeholders)
                
                if hadBinary {
                    hasBinary = true
                    placeholders += dictArrs.count
                    replacementArr[g] = nestDict
                    arrayDatas.extend(dictArrs)
                } else {
                    replacementArr[g] = dict
                }
            } else if let nestArr = arr[g] as? NSArray {
                // Recursive
                let (nested, hadBinary, nestDatas) = self.parseArray(nestArr, placeholders: placeholders)
                
                if hadBinary {
                    hasBinary = true
                    placeholders += nestDatas.count
                    replacementArr[g] = nested
                    arrayDatas.extend(nestDatas)
                } else {
                    replacementArr[g] = arr[g]
                }
            } else {
                replacementArr[g] = arr[g]
            }
        }
        
        return (replacementArr, hasBinary, arrayDatas)
    }
    
    // Parses data for events
    static func parseData(data:String?) -> AnyObject? {
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
    
    private static func parseEmitArgs(args:[AnyObject]) -> ([AnyObject], Bool, [NSData]) {
        var items = [AnyObject](count: args.count, repeatedValue: 1)
        var numberOfPlaceholders = -1
        var hasBinary = false
        var emitDatas = [NSData]()
        
        for i in 0..<args.count {
            if let dict = args[i] as? NSDictionary {
                // Check for binary data
                let (newDict, hadBinary, binaryDatas) = SocketIOClient.parseNSDictionary(dict,
                    placeholders: numberOfPlaceholders)
                if hadBinary {
                    numberOfPlaceholders = binaryDatas.count
                    
                    emitDatas.extend(binaryDatas)
                    hasBinary = true
                    items[i] = newDict
                } else {
                    items[i] = dict
                }
            } else if let arr = args[i] as? NSArray {
                // arg is array, check for binary
                let (replace, hadData, newDatas) = SocketIOClient.parseArray(arr,
                    placeholders: numberOfPlaceholders)
                
                if hadData {
                    hasBinary = true
                    numberOfPlaceholders += emitDatas.count
                    
                    for data in newDatas {
                        emitDatas.append(data)
                    }
                    
                    items[i] = replace
                } else {
                    items[i] = arr
                }
            } else if let binaryData = args[i] as? NSData {
                // args is just binary
                hasBinary = true
                let sendData = SocketIOClient.createBinaryDataForSend(binaryData)
                
                numberOfPlaceholders++
                items[i] = ["_placeholder": true, "num": numberOfPlaceholders]
                emitDatas.append(sendData)
            } else {
                items[i] = args[i]
            }
        }
        
        return (items, hasBinary, emitDatas)
    }
    
    // Parses a NSDictionary, looking for NSData objects
    private static func parseNSDictionary(dict:NSDictionary, var placeholders:Int) -> (NSDictionary, Bool, [NSData]) {
        var returnDict = NSMutableDictionary()
        var hasBinary = false
        if placeholders == -1 {
            placeholders = 0
        }
        var returnDatas = [NSData]()
        
        for (key, value) in dict {
            if let binaryData = value as? NSData {
                hasBinary = true
                let sendData = self.createBinaryDataForSend(binaryData)
                returnDatas.append(sendData)
                returnDict[key as! String] = ["_placeholder": true, "num": placeholders++]
            } else if let arr = value as? NSArray {
                let (replace, hadBinary, arrDatas) = self.parseArray(arr, placeholders: placeholders)
                
                if hadBinary {
                    hasBinary = true
                    returnDict[key as! String] = replace
                    placeholders += arrDatas.count
                    returnDatas.extend(arrDatas)
                } else {
                    returnDict[key as! String] = arr
                }
            } else if let dict = value as? NSDictionary {
                // Recursive
                let (nestDict, hadBinary, nestDatas) = self.parseNSDictionary(dict, placeholders: placeholders)
                
                if hadBinary {
                    hasBinary = true
                    returnDict[key as! String] = nestDict
                    placeholders += nestDatas.count
                    returnDatas.extend(nestDatas)
                } else {
                    returnDict[key as! String] = dict
                }
            } else {
                returnDict[key as! String] = value
            }
        }
        
        return (returnDict, hasBinary, returnDatas)
    }
    
    // Parses messages recieved
    private func parseSocketMessage(message:AnyObject?) {
        if message == nil {
            return
        }
        
        // println(message!)
        
        if let stringMessage = message as? String {
            // Check for successful namepsace connect
            if self.nsp != nil {
                if stringMessage == "40/\(self.nsp!)" {
                    self.handleEvent("connect", data: nil)
                    return
                }
            }
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
                        self.sid = json!["sid"] as? String
                        self.startPingTimer(interval: (json!["pingInterval"] as! Int) / 1000)
                        return
                }
            }
            /**
            End check for socket info frame
            **/
            
            /**
            Begin check for message
            **/
            let messageGroups = mutMessage["(\\d*)\\/?(\\w*)?,?(\\d*)?(\\[.*\\])?"].groups()
            
            if messageGroups[1].hasPrefix("42") {
                var mesNum = messageGroups[1]
                var ackNum:String
                var namespace:String?
                var messagePart:String!
                
                if messageGroups[3] != "" {
                    ackNum = messageGroups[3]
                } else {
                    let range = Range<String.Index>(start: mesNum.startIndex, end: advance(mesNum.startIndex, 2))
                    mesNum.replaceRange(range, with: "")
                    ackNum = mesNum
                }
                
                namespace = messageGroups[2]
                messagePart = messageGroups[4]
                
                if namespace == "" && self.nsp != nil {
                    return
                }
                
                let messageInternals = RegexMutable(messagePart)["\\[\"(.*?)\",(.*?)?\\]$"].groups()
                if messageInternals != nil && messageInternals.count > 2 {
                    let event = messageInternals[1]
                    var data:String?
                    
                    if messageInternals[2] == "" {
                        data = nil
                    } else {
                        data = messageInternals[2]
                    }
                    
                    // It would be nice if socket.io only allowed one thing
                    // per message, but alas, it doesn't.
                    if let parsed:AnyObject = SocketIOClient.parseData(data) {
                        if ackNum == "" {
                            self.handleEvent(event, data: parsed)
                        } else {
                            self.handleEvent(event, data: parsed, isInternalMessage: false,
                                wantsAck: ackNum.toInt(), withAckType: 3)
                        }
                        return
                    } else if let strData = data {
                        // There are multiple items in the message
                        // Turn it into a String and run it through
                        // parseData to try and get an array.
                        let asArray = "[\(strData)]"
                        if let parsed:AnyObject = SocketIOClient.parseData(asArray) {
                            if ackNum == "" {
                                self.handleEvent(event, data: parsed)
                            } else {
                                self.handleEvent(event, data: parsed, isInternalMessage: false,
                                    wantsAck: ackNum.toInt(), withAckType: 3)
                            }
                            return
                        }
                    }
                }
                
                // Check for no item event
                let noItemMessage = RegexMutable(messagePart)["\\[\"(.*?)\"]$"].groups()
                if noItemMessage != nil && noItemMessage.count == 2 {
                    let event = noItemMessage[1]
                    if ackNum == "" {
                        self.handleEvent(event, data: nil)
                    } else {
                        self.handleEvent(event, data: nil, isInternalMessage: false,
                            wantsAck: ackNum.toInt(), withAckType: 3)
                    }
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
            if self.lastSocketMessage == nil {
                return
            }
            
            self.parseBinaryData(binary)
        }
    }
    
    // Tries to parse a message that contains binary
    private func parseBinaryMessage(#message:AnyObject) {
        
        // println(message)
        if let stringMessage = message as? String {
            var mutMessage = RegexMutable(stringMessage)
            
            /**
            Begin check for binary placeholders
            **/
            let binaryGroup = mutMessage["^(\\d*)-\\/?(\\w*)?,?(\\d*)?\\[(\".*?\"),(.*)\\]$"].groups()
            
            if binaryGroup != nil {
                // println(binaryGroup)
                var ackNum:String
                var event:String
                var mutMessageObject:NSMutableString
                var namespace:String?
                var numberOfPlaceholders:String
                let messageType = RegexMutable(binaryGroup[1])
                
                namespace = binaryGroup[2]
                if binaryGroup[3] != "" {
                    ackNum = binaryGroup[3] as String
                } else if self.nsp == nil && binaryGroup[2] != "" {
                    ackNum = binaryGroup[2]
                } else {
                    ackNum = ""
                }
                
                numberOfPlaceholders = (messageType["45"] ~= "") as String
                event = (RegexMutable(binaryGroup[4])["\""] ~= "") as String
                mutMessageObject = RegexMutable(binaryGroup[5])
                
                if namespace == "" && self.nsp != nil {
                    self.lastSocketMessage = nil
                    return
                }
                
                let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"]
                    ~= "\"~~$2\""
                
                let mes:SocketEvent
                if ackNum != "" {
                    mes = SocketEvent(event: event, args: placeholdersRemoved,
                        placeholders: numberOfPlaceholders.toInt()!)
                } else {
                    mes = SocketEvent(event: event, args: placeholdersRemoved,
                        placeholders: numberOfPlaceholders.toInt()!, ack: ackNum.toInt())
                }
                
                self.lastSocketMessage = mes
            }
            /**
            End check for binary placeholders
            **/
        }
    }
    
    // Handles binary data
    private func parseBinaryData(data:NSData) {
        let shouldExecute = self.lastSocketMessage?.addData(data)
        
        if shouldExecute != nil && shouldExecute! {
            var event = self.lastSocketMessage!.event
            var parsedArgs:AnyObject? = SocketIOClient.parseData(self.lastSocketMessage!.args as? String)
            
            if let args:AnyObject = parsedArgs {
                let filledInArgs:AnyObject = self.lastSocketMessage!.fillInPlaceholders(args)
                
                if self.lastSocketMessage!.ack != nil {
                    self.handleEvent(event, data: filledInArgs, isInternalMessage: false,
                        wantsAck: self.lastSocketMessage!.ack!, withAckType: 6)
                } else {
                    self.handleEvent(event, data: filledInArgs)
                }
            } else {
                let filledInArgs:AnyObject = self.lastSocketMessage!.fillInPlaceholders()
                
                if self.lastSocketMessage!.ack != nil {
                    self.handleEvent(event, data: filledInArgs, isInternalMessage: false,
                        wantsAck: self.lastSocketMessage!.ack!, withAckType: 6)
                } else {
                    self.handleEvent(event, data: filledInArgs)
                }
            }
        }
    }
    
    func sendPing() {
        if self.connected {
            self.io?.send("2")
        }
    }
    
    // Starts the ping timer
    private func startPingTimer(#interval:Int) {
        dispatch_async(dispatch_get_main_queue()) {
            self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(interval), target: self,
                selector: Selector("sendPing"), userInfo: nil, repeats: true)
        }
    }
    
    // We lost connection and should attempt to reestablish
    private func tryReconnect(var #triesLeft:Int) {
        if triesLeft != -1 && triesLeft <= 0 {
            self.connecting = false
            self.reconnects = false
            self.reconnecting = false
            self.handleEvent("disconnect", data: "Failed to reconnect", isInternalMessage: true)
            return
        } else if self.connected {
            self.connecting = false
            self.reconnecting = false
            return
        }
        
        // println("Trying to reconnect #\(reconnectAttempts - triesLeft)")
        self.handleEvent("reconnectAttempt", data: triesLeft, isInternalMessage: true)
        
        let waitTime = UInt64(self.reconnectWait) * NSEC_PER_SEC
        let time = dispatch_time(DISPATCH_TIME_NOW, Int64(waitTime))
        
        // Wait reconnectWait seconds and then check if connected. Repeat if not
        dispatch_after(time, dispatch_get_main_queue()) {[weak self] in
            if self == nil || self!.connected || self!.closed {
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
        dispatch_async(self.handleQueue) {[weak self] in
            if self == nil {
                return
            }
            
            self?.parseSocketMessage(message)
        }
    }
    
    // Called when the socket is opened
    func webSocketDidOpen(webSocket:SRWebSocket!) {
        self.closed = false
        self.connecting = false
        self.reconnecting = false
        self.connected = true
        
        if self.nsp != nil {
            // Join namespace
            self.joinNamespace()
            return
        }
        
        // Don't handle as internal because something crazy could happen where
        // we disconnect before it's handled
        self.handleEvent("connect", data: nil)
    }
    
    // Called when the socket is closed
    func webSocket(webSocket:SRWebSocket!, didCloseWithCode code:Int, reason:String!, wasClean:Bool) {
        self.pingTimer?.invalidate()
        self.connected = false
        self.connecting = false
        if self.closed || !self.reconnects {
            self.handleEvent("disconnect", data: reason, isInternalMessage: true)
        } else {
            self.handleEvent("reconnect", data: reason, isInternalMessage: true)
            self.tryReconnect(triesLeft: self.reconnectAttempts)
            
        }
    }
    
    // Called when an error occurs.
    func webSocket(webSocket:SRWebSocket!, didFailWithError error:NSError!) {
        self.pingTimer?.invalidate()
        self.connected = false
        self.connecting = false
        self.handleEvent("error", data: error.localizedDescription, isInternalMessage: true)
        if self.closed || !self.reconnects {
            self.handleEvent("disconnect", data: error.localizedDescription, isInternalMessage: true)
        } else if !self.reconnecting {
            self.handleEvent("reconnect", data: error.localizedDescription, isInternalMessage: true)
            self.tryReconnect(triesLeft: self.reconnectAttempts)
        }
    }
}