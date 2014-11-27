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

private struct Event {
    var event:String!
    var args:Any!
    var placeholders:Int!
    var currentPlace = 0
    
    init(event:String, args:Any?, placeholders:Int = 0) {
        self.event = event
        self.args = args?
        self.placeholders = placeholders
    }
    
    func createMessage() -> String {
        var array = "42["
        array += "\"" + event + "\""
        if (args? != nil) {
            if (args is NSDictionary) {
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
        if (args? != nil) {
            if (args is NSDictionary) {
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
    
    mutating func fillInPlaceHolder(data:NSData) -> Bool {
        func checkDoEvent() -> Bool {
            if (self.placeholders == self.currentPlace) {
                return true
            } else {
                return false
            }
        }
        
        if (checkDoEvent()) {
            return true
        }
        
        if let stringArgs = args as? String {
            let mutStringArgs = RegexMutable(stringArgs)
            let base64 = data.base64EncodedStringWithOptions(NSDataBase64EncodingOptions.allZeros)
            let placeHolder = "~~" + String(self.currentPlace)
            self.args = mutStringArgs[placeHolder] ~= "\"" + base64 + "\""
            self.currentPlace++
            return checkDoEvent()
        }
        return false
    }
}

class SocketIOClient: NSObject, SRWebSocketDelegate {
    let socketURL:String!
    var connected = false
    var connecting = false
    private var handlers = [EventHandler]()
    var io:SRWebSocket?
    var pingTimer:NSTimer!
    private var lastSocketMessage:Event?
    var secure = false
    
    init(socketURL:String, secure:Bool = false) {
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
    
    // Creates a binary message, ready for sending
    private func createBinaryDataForSend(data:NSData) -> NSData {
        var byteArray = [UInt8](count: 1, repeatedValue: 0x0)
        byteArray[0] = 4
        var mutData = NSMutableData(bytes: &byteArray, length: 1)
        mutData.appendData(data)
        return mutData
    }
    
    // Sends a message
    func emit(event:String, args:Any? = nil) {
        if (!self.connected) {
            return
        }
        var frame:Event!
        var str:String!
        
        if let dict = args as? NSDictionary {
            // Check for binary data
            let (newDict, hadBinary, binaryDatas) = self.parseNSDictionary(dict: dict)
            if (hadBinary) {
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
    func handleEvent(#event:String, data:Any?) {
        // println("Should do event: \(event) with data: \(data)")
        
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
    
    // Parses a NSDictionary, looking for NSData objects
    func parseNSDictionary(#dict:NSDictionary) -> (NSDictionary, Bool, [NSData]?) {
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
        if (containedData) {
            return (returnDict, true, returnDatas)
        } else {
            return (returnDict, false, nil)
        }
    }
    
    // Parses messages recieved
    private func parseSocketMessage(#message:AnyObject?) {
        if (message == nil) {
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
            
            /**
            Begin check for message
            **/
            let messageGroups = mutMessage["(\\d*)(\\[.*\\])?"].groups()
            if (messageGroups.count == 3 && messageGroups[1] == "42") {
                let messagePart = messageGroups[2]
                let messageInternals = RegexMutable(messagePart)["\\[\"(.*?)\",(.*?)?\\]$"].groups()
                if (messageInternals != nil && messageInternals.count > 2) {
                    let event = messageInternals[1]
                    var data:Any!
                    if (messageInternals[2] == "") {
                        data = nil
                    } else {
                        data = messageInternals[2]
                        
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
            if (binaryGroup != nil) {
                let messageType = RegexMutable(binaryGroup[1])
                let numberOfPlaceholders = messageType["45"] ~= ""
                let event = binaryGroup[2]
                let mutMessageObject = RegexMutable(binaryGroup[3])
                let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "~~$2"
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
        if (self.lastSocketMessage == nil) {
            return
        }
        
        let shouldExecute = self.lastSocketMessage?.fillInPlaceHolder(data)
        var event = self.lastSocketMessage!.event
        var args = self.lastSocketMessage!.args
        // println(args)
        if (shouldExecute != nil && shouldExecute!) {
            self.handleEvent(event: event, data: args)
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
    private func startPingTimer(#interval:Int) {
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
        self.pingTimer?.invalidate()
        self.connected = false
        self.connecting = false
        self.handleEvent(event: "disconnect", data: reason)
    }
}