//
//  SocketParser.swift
//  Socket.IO-Swift
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

class SocketParser {
    // Parse an NSArray looking for binary data
    class func parseArray(arr:NSArray, var currentPlaceholder:Int) -> (NSArray, Bool, [NSData]) {
        var replacementArr = [AnyObject](count: arr.count, repeatedValue: 1)
        var hasBinary = false
        var arrayDatas = [NSData]()
        
        for g in 0..<arr.count {
            if arr[g] is NSData {
                hasBinary = true
                currentPlaceholder++
                let sendData = arr[g] as! NSData
                
                arrayDatas.append(sendData)
                replacementArr[g] = ["_placeholder": true,
                    "num": currentPlaceholder]
            } else if let dict = arr[g] as? NSDictionary {
                let (nestDict, hadBinary, dictArrs) = self.parseNSDictionary(dict,
                    currentPlaceholder: currentPlaceholder)
                
                if hadBinary {
                    hasBinary = true
                    currentPlaceholder += dictArrs.count
                    replacementArr[g] = nestDict
                    arrayDatas.extend(dictArrs)
                } else {
                    replacementArr[g] = dict
                }
            } else if let nestArr = arr[g] as? NSArray {
                // Recursive
                let (nested, hadBinary, nestDatas) = self.parseArray(nestArr,
                    currentPlaceholder: currentPlaceholder)
                
                if hadBinary {
                    hasBinary = true
                    currentPlaceholder += nestDatas.count
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
    
    class func parseEmitArgs(args:[AnyObject]) -> ([AnyObject], Bool, [NSData]) {
        var items = [AnyObject](count: args.count, repeatedValue: 1)
        var currentPlaceholder = -1
        var hasBinary = false
        var emitDatas = [NSData]()
        
        for i in 0..<args.count {
            if let dict = args[i] as? NSDictionary {
                // Check for binary data
                let (newDict, hadBinary, binaryDatas) = self.parseNSDictionary(dict,
                    currentPlaceholder: currentPlaceholder)
                if hadBinary {
                    currentPlaceholder += binaryDatas.count
                    emitDatas.extend(binaryDatas)
                    hasBinary = true
                    items[i] = newDict
                } else {
                    items[i] = dict
                }
            } else if let arr = args[i] as? NSArray {
                // arg is array, check for binary
                let (replace, hadData, newDatas) = self.parseArray(arr,
                    currentPlaceholder: currentPlaceholder)
                
                if hadData {
                    hasBinary = true
                    currentPlaceholder += newDatas.count
                    
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
                
                currentPlaceholder++
                items[i] = ["_placeholder": true, "num": currentPlaceholder]
                emitDatas.append(binaryData)
            } else {
                items[i] = args[i]
            }
        }
        
        return (items, hasBinary, emitDatas)
    }
    
    // Parses a NSDictionary, looking for NSData objects
    class func parseNSDictionary(dict:NSDictionary, var currentPlaceholder:Int) -> (NSDictionary, Bool, [NSData]) {
        var returnDict = NSMutableDictionary()
        var hasBinary = false
        var returnDatas = [NSData]()
        
        for (key, value) in dict {
            if let binaryData = value as? NSData {
                currentPlaceholder++
                hasBinary = true
                returnDatas.append(binaryData)
                returnDict[key as! String] = ["_placeholder": true, "num": currentPlaceholder]
            } else if let arr = value as? NSArray {
                let (replace, hadBinary, arrDatas) = self.parseArray(arr, currentPlaceholder: currentPlaceholder)
                
                if hadBinary {
                    hasBinary = true
                    returnDict[key as! String] = replace
                    currentPlaceholder += arrDatas.count
                    returnDatas.extend(arrDatas)
                } else {
                    returnDict[key as! String] = arr
                }
            } else if let dict = value as? NSDictionary {
                // Recursive
                let (nestDict, hadBinary, nestDatas) = self.parseNSDictionary(dict, currentPlaceholder: currentPlaceholder)
                
                if hadBinary {
                    hasBinary = true
                    returnDict[key as! String] = nestDict
                    currentPlaceholder += nestDatas.count
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
    class func parseSocketMessage(stringMessage:String, socket:SocketIOClient) {
        // println(message!)
        
        // Check for successful namepsace connect
        if socket.nsp != nil {
            if stringMessage == "0/\(socket.nsp!)" {
                socket.didConnect()
                return
            }
        }
        
        if stringMessage == "0" {
            if socket.nsp != nil {
                // Join namespace
                socket.joinNamespace()
                return
            } else {
                socket.didConnect()
                return
            }
        }
        
        var mutMessage = RegexMutable(stringMessage)
        
        /**
        Begin check for message
        **/
        let messageGroups = mutMessage["(\\d*)\\/?(\\w*)?,?(\\d*)?(\\[.*\\])?"].groups()
        
        if messageGroups[1].hasPrefix("2") {
            var mesNum = messageGroups[1]
            var ackNum:String
            var namespace:String?
            var messagePart:String!
            
            if messageGroups[3] != "" {
                ackNum = messageGroups[3]
            } else {
                let range = Range<String.Index>(start: mesNum.startIndex,
                    end: advance(mesNum.startIndex, 1))
                mesNum.replaceRange(range, with: "")
                ackNum = mesNum
            }
            
            namespace = messageGroups[2]
            messagePart = messageGroups[4]
            
            if namespace == "" && socket.nsp != nil {
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
                if let parsed:AnyObject = self.parseData(data) {
                    if ackNum == "" {
                        socket.handleEvent(event, data: parsed)
                    } else {
                        socket.currentAck = ackNum.toInt()!
                        socket.handleEvent(event, data: parsed, isInternalMessage: false,
                            wantsAck: ackNum.toInt(), withAckType: 3)
                    }
                    
                    return
                } else if let strData = data {
                    // There are multiple items in the message
                    // Turn it into a String and run it through
                    // parseData to try and get an array.
                    let asArray = "[\(strData)]"
                    if let parsed:AnyObject = self.parseData(asArray) {
                        if ackNum == "" {
                            socket.handleEvent(event, data: parsed)
                        } else {
                            socket.currentAck = ackNum.toInt()!
                            socket.handleEvent(event, data: parsed, isInternalMessage: false,
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
                    socket.handleEvent(event, data: nil)
                } else {
                    socket.currentAck = ackNum.toInt()!
                    socket.handleEvent(event, data: nil, isInternalMessage: false,
                        wantsAck: ackNum.toInt(), withAckType: 3)
                }
                return
            }
        } else if messageGroups[1].hasPrefix("3") {
            let arr = Array(messageGroups[1])
            var ackNum:String
            let nsp = messageGroups[2]
            
            if nsp == "" && socket.nsp != nil {
                return
            }
            
            if nsp == "" {
                ackNum = String(arr[1...arr.count-1])
            } else {
                ackNum = messageGroups[3]
            }
            
            let ackData:AnyObject? = self.parseData(messageGroups[4])
            socket.handleAck(ackNum.toInt()!, data: ackData)
            
            return
        }
        /**
        End Check for message
        **/
        
        // Check for message with binary placeholders
        self.parseBinaryMessage(stringMessage, socket: socket)
    }
    
    // Handles binary data
    class func parseBinaryData(data:NSData, socket:SocketIOClient) {
        let shouldExecute = socket.waitingData[0].addData(data)
        
        if shouldExecute {
            let socketEvent = socket.waitingData.removeAtIndex(0)
            var event = socketEvent.event
            var parsedArgs:AnyObject? = self.parseData(socketEvent.args as? String)
            
            if let args:AnyObject = parsedArgs {
                let filledInArgs:AnyObject = socketEvent.fillInPlaceholders(args)
                
                if socketEvent.justAck! {
                    // Should handle ack
                    socket.handleAck(socketEvent.ack!, data: filledInArgs)
                    return
                }
                
                // Should do event
                if socketEvent.ack != nil {
                    socket.handleEvent(event, data: filledInArgs, isInternalMessage: false,
                        wantsAck: socketEvent.ack!, withAckType: 6)
                } else {
                    socket.handleEvent(event, data: filledInArgs)
                }
            } else {
                let filledInArgs:AnyObject = socketEvent.fillInPlaceholders()
                
                // Should handle ack
                if socketEvent.justAck! {
                    socket.handleAck(socketEvent.ack!, data: filledInArgs)
                    return
                }
                
                // Should handle ack
                if socketEvent.ack != nil {
                    socket.handleEvent(event, data: filledInArgs, isInternalMessage: false,
                        wantsAck: socketEvent.ack!, withAckType: 6)
                } else {
                    socket.handleEvent(event, data: filledInArgs)
                }
            }
        }
    }
    
    // Tries to parse a message that contains binary
    class func parseBinaryMessage(message:String, socket:SocketIOClient) {
        // println(message)
        var mutMessage = RegexMutable(message)
        
        /**
        Begin check for binary placeholders
        **/
        let binaryGroup = mutMessage["^(\\d*)-\\/?(\\w*)?,?(\\d*)?\\[(\".*?\")?,?(.*)?\\]$"].groups()
        
        if binaryGroup == nil {
            return
        }
        
        if binaryGroup[1].hasPrefix("5") {
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
            } else if socket.nsp == nil && binaryGroup[2] != "" {
                ackNum = binaryGroup[2]
            } else {
                ackNum = ""
            }
            
            numberOfPlaceholders = (messageType["5"] ~= "") as String
            event = (RegexMutable(binaryGroup[4])["\""] ~= "") as String
            mutMessageObject = RegexMutable(binaryGroup[5])
            
            if namespace == "" && socket.nsp != nil {
                return
            }
            
            let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"]
                ~= "\"~~$2\""
            
            var mes:SocketEvent
            if ackNum == "" {
                mes = SocketEvent(event: event, args: placeholdersRemoved,
                    placeholders: numberOfPlaceholders.toInt()!)
            } else {
                socket.currentAck = ackNum.toInt()!
                mes = SocketEvent(event: event, args: placeholdersRemoved,
                    placeholders: numberOfPlaceholders.toInt()!, ackNum: ackNum.toInt())
            }
            
            socket.waitingData.append(mes)
        } else if binaryGroup[1].hasPrefix("6") {
            let messageType = RegexMutable(binaryGroup[1])
            let numberOfPlaceholders = (messageType["6"] ~= "") as String
            var ackNum:String
            var nsp:String
            
            if binaryGroup[3] == "" {
                ackNum = binaryGroup[2]
                nsp = ""
            } else {
                ackNum = binaryGroup[3]
                nsp = binaryGroup[2]
            }
            
            if nsp == "" && socket.nsp != nil {
                return
            }
            var mutMessageObject = RegexMutable(binaryGroup[5])
            let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"]
                ~= "\"~~$2\""
            
            let event = SocketEvent(event: "", args: placeholdersRemoved,
                placeholders: numberOfPlaceholders.toInt()!, ackNum: ackNum.toInt(), justAck: true)
            
            socket.waitingData.append(event)
        }
        /**
        End check for binary placeholders
        **/
    }
}