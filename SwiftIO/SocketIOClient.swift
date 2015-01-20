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

class SocketIOClient: NSObject, SRWebSocketDelegate {
    let socketURL:String!
    private let secure:Bool!
    private var handlers = [EventHandler]()
    private var lastSocketMessage:Event?
    private var pingTimer:NSTimer!
    var connected = false
    var connecting = false
    var io:SRWebSocket?
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
    // If a message contains binary we have to send those
    // seperately.
    func emit(event:String, args:AnyObject? = nil) {
        if !self.connected {
            return
        }
        
        var frame:Event!
        var str:String
        
        if let dict = args as? NSDictionary {
            // Check for binary data
            let (newDict, hadBinary, binaryDatas) = self.parseNSDictionary(dict)
            if hadBinary {
                str = Event.createMessageForEvent(event, withArgs: [newDict], hasBinary: true, withDatas: binaryDatas!.count)
                self.io?.send(str)
                
                for data in binaryDatas! {
                    let sendData = self.createBinaryDataForSend(data)
                    self.io?.send(sendData)
                }
                
                return
            }
        } else if let binaryData = args as? NSData {
            // args is just binary
            str = Event.createMessageForEvent(event, withArgs: [["_placeholder": true, "num": 0]],
                hasBinary: true, withDatas: 1)
            
            self.io?.send(str)
            let sendData = self.createBinaryDataForSend(binaryData)
            self.io?.send(sendData)
            
            return
        } else if let arr = args as? NSArray {
            var hadBinary = false
            var placeholders = [AnyObject](count: arr.count, repeatedValue: 1)
            var datas = [NSData]()
            var placeNum = 0
            
            for i in 0..<arr.count {
                if arr[i] is NSData {
                    hadBinary = true
                    placeholders[i] = ["_placeholder": true, "num": placeNum]
                    datas.append(self.createBinaryDataForSend(arr[i] as NSData))
                    placeNum++
                } else {
                    placeholders[i] = arr[i]
                }
            }
            
            if hadBinary {
                str = Event.createMessageForEvent(event, withArgs: [placeholders],
                    hasBinary: true, withDatas: datas.count)
                
                self.io?.send(str)
                for data in datas {
                    self.io?.send(data)
                }
                return
            }
        }
        
        if args == nil {
            str = "42[\"\(event)\"]"
        } else {
            str = Event.createMessageForEvent(event, withArgs: [args!], hasBinary: false)
        }
        
        // println("Sending: \(str)")
        self.io?.send(str)
    }
    
    // Sends a message with multiple args
    // If a message contains binary we have to send those
    // seperately.
    func emitMultiple(event:String, args:AnyObject...) {
        if !self.connected {
            return
        }
        
        var frame:Event
        var str:String
        var items = [AnyObject](count: args.count, repeatedValue: 1)
        var numberOfPlaceholders = -1
        var hasBinary = false
        var datas = [NSData]()
        
        for i in 0..<args.count {
            if let dict = args[i] as? NSDictionary {
                // Check for binary data
                let (newDict, hadBinary, binaryDatas) = self.parseNSDictionary(dict,
                    placeholders: numberOfPlaceholders + 1)
                if hadBinary {
                    numberOfPlaceholders = binaryDatas!.count
                    
                    for data in binaryDatas! {
                        let sendData = self.createBinaryDataForSend(data)
                        datas.append(sendData)
                    }
                    hasBinary = true
                    items[i] = newDict
                    continue
                }
                items[i] = dict
            } else if let arr = args[i] as? NSArray {
                // arg is array, check for binary
                var replacementArr = [AnyObject](count: arr.count, repeatedValue: 1)
                for g in 0..<arr.count {
                    if arr[g] is NSData {
                        hasBinary = true
                        numberOfPlaceholders++
                        
                        let sendData = self.createBinaryDataForSend(arr[g] as NSData)
                        
                        datas.append(sendData)
                        replacementArr[g] = ["_placeholder": true,
                            "num": numberOfPlaceholders]
                    } else {
                        replacementArr[g] = arr[g]
                    }
                }
                items[i] = replacementArr
            } else if let binaryData = args[i] as? NSData {
                // args is just binary
                hasBinary = true
                let sendData = self.createBinaryDataForSend(binaryData)
                
                numberOfPlaceholders++
                items[i] = ["_placeholder": true, "num": numberOfPlaceholders]
                datas.append(sendData)
            } else {
                items[i] = args[i]
            }
        }
        
        if hasBinary {
            str = Event.createMessageForEvent(event, withArgs: items,
                hasBinary: true, withDatas: datas.count)
            self.io?.send(str)
            for data in datas {
                self.io?.send(data)
            }
        } else {
            str = Event.createMessageForEvent(event, withArgs: items, hasBinary: false)
            self.io?.send(str)
        }
    }
    
    // Handles events
    func handleEvent(#event:String, data:AnyObject?, multipleItems:Bool = false) {
        // println("Should do event: \(event) with data: \(data)")
        
        for handler in self.handlers {
            if handler.event == event && !multipleItems {
                if data == nil {
                    handler.executeCallback(nil)
                    continue
                }
                
                handler.executeCallback(data)
            } else if handler.event == event && multipleItems {
                if let arr = data as? [AnyObject] {
                    handler.executeCallback(arr)
                    continue
                }
            }
        }
    }
    
    // Adds handler for single arg message
    func on(name:String, callback:((data:AnyObject?) -> Void)) {
        let handler = EventHandler(event: name, callback: callback)
        self.handlers.append(handler)
    }
    
    // Adds handler for multiple arg message
    func onMultipleArgs(name:String, callback:((data:[AnyObject]) -> Void)) {
        let handler = EventHandler(event: name, callback: callback)
        self.handlers.append(handler)
    }
    
    // Opens the connection to the socket
    func open() {
        self.connect()
    }
    
    // Parses data for events
    class func parseData(data:String?) -> AnyObject? {
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
    private func parseNSDictionary(dict:NSDictionary, placeholders:Int = 0) -> (NSDictionary, Bool, [NSData]?) {
        var returnDict = NSMutableDictionary()
        var placeholder = placeholders
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
                    
                    // It would be nice if socket.io only allowed one thing
                    // per message, but alas, it doesn't.
                    if let parsed:AnyObject = SocketIOClient.parseData(data) {
                        self.handleEvent(event: event, data: parsed)
                        return
                    } else if let strData = data {
                        // There are multiple items in the message
                        // Turn it into a String and run it through
                        // parseData to try and get an array.
                        let asArray = "[\(strData)]"
                        
                        if let parsed:AnyObject = SocketIOClient.parseData(asArray) {
                            self.handleEvent(event: event, data: parsed, multipleItems: true)
                            return
                        }
                    }
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
    private func parseBinaryMessage(#message:AnyObject) {
        if let stringMessage = message as? String {
            var mutMessage = RegexMutable(stringMessage)
            
            /**
            Begin check for binary placeholders
            **/
            let binaryGroup = mutMessage["(\\d*)-\\[\"(.*)\",(\\{.*\\})\\]$"].groups()
            
            // println(binaryGroup)
            if binaryGroup != nil {
                let messageType = RegexMutable(binaryGroup[1])
                let numberOfPlaceholders = messageType["45"] ~= ""
                let event = binaryGroup[2]
                let mutMessageObject = RegexMutable(binaryGroup[3])
                let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"]
                    ~= "\"~~$2\""
                let mes = Event(event: event, args: placeholdersRemoved,
                    placeholders: numberOfPlaceholders.integerValue)
                self.lastSocketMessage = mes
                return
            } else {
                // There are multiple items in binary message
                let binaryGroups = mutMessage["(\\d*)-\\[(\".*?\"),(.*)\\]$"].groups()
                if binaryGroups != nil {
                    let messageType = RegexMutable(binaryGroups[1])
                    let numberOfPlaceholders = messageType["45"] ~= ""
                    let event = RegexMutable(binaryGroups[2] as String)["\""] ~= ""
                    let mutMessageObject = RegexMutable(binaryGroups[3])
                    let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"]
                        ~= "\"~~$2\""
                    let mes = Event(event: event, args: placeholdersRemoved,
                        placeholders: numberOfPlaceholders.integerValue)
                    self.lastSocketMessage = mes
                    return
                }
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
                self.handleEvent(event: event, data: filledInArgs)
            } else {
                // We have multiple items
                let filledInArgs:AnyObject = self.lastSocketMessage!.fillInPlaceholders()
                self.handleEvent(event: event, data: filledInArgs, multipleItems: true)
                return
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