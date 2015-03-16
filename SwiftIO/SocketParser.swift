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
                let sendData = arr[g] as NSData
                
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
                returnDict[key as String] = ["_placeholder": true, "num": currentPlaceholder]
            } else if let arr = value as? NSArray {
                let (replace, hadBinary, arrDatas) = self.parseArray(arr, currentPlaceholder: currentPlaceholder)
                
                if hadBinary {
                    hasBinary = true
                    returnDict[key as String] = replace
                    currentPlaceholder += arrDatas.count
                    returnDatas.extend(arrDatas)
                } else {
                    returnDict[key as String] = arr
                }
            } else if let dict = value as? NSDictionary {
                // Recursive
                let (nestDict, hadBinary, nestDatas) = self.parseNSDictionary(dict, currentPlaceholder: currentPlaceholder)
                
                if hadBinary {
                    hasBinary = true
                    returnDict[key as String] = nestDict
                    currentPlaceholder += nestDatas.count
                    returnDatas.extend(nestDatas)
                } else {
                    returnDict[key as String] = dict
                }
            } else {
                returnDict[key as String] = value
            }
        }
        
        return (returnDict, hasBinary, returnDatas)
    }
    
    // Parses messages recieved
    class func parseSocketMessage(stringMessage:String, socket:SocketIOClient) {
        if stringMessage == "" {
            return
        }
        
        // NSLog(stringMessage)
        
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
        
        if stringMessage.hasPrefix("5") || stringMessage.hasPrefix("6") {
            // Check for message with binary placeholders
            self.parseBinaryMessage(stringMessage, socket: socket)
            return
        }
        
        /**
        Begin check for message
        **/
        var messageGroups:[String]?
        
        if let groups = stringMessage["(\\d*)\\/?(\\w*)?,?(\\d*)?\\[\"(.*?)\",?(.*?)?\\]$",
            NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                messageGroups = groups
        } else if let ackGroup = stringMessage["(\\d*)\\/?(\\w*)?,?(\\d*)?\\[(.*?)?\\]$",
            NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                messageGroups = ackGroup
        } else {
            NSLog("Error parsing message: %s", stringMessage)
            return
        }
        
        if messageGroups![1].hasPrefix("2") {
            var mesNum = messageGroups![1]
            var ackNum:String
            var namespace:String?
            
            if messageGroups![3] != "" {
                ackNum = messageGroups![3]
            } else {
                let range = Range<String.Index>(start: mesNum.startIndex,
                    end: advance(mesNum.startIndex, 1))
                mesNum.replaceRange(range, with: "")
                ackNum = mesNum
            }
            
            namespace = messageGroups![2]
            
            if namespace == "" && socket.nsp != nil {
                return
            }
            
            let event = messageGroups![4]
            let data = "[\(messageGroups![5])]"
            
            if let parsed:AnyObject = self.parseData(data) {
                if ackNum == "" {
                    socket.handleEvent(event, data: parsed)
                } else {
                    socket.currentAck = ackNum.toInt()!
                    socket.handleEvent(event, data: parsed, isInternalMessage: false,
                        wantsAck: ackNum.toInt(), withAckType: 3)
                }
                
                return
            }
        } else if messageGroups![1].hasPrefix("3") {
            let arr = Array(messageGroups![1])
            var ackNum:String
            let nsp = messageGroups![2]
            
            if nsp == "" && socket.nsp != nil {
                return
            }
            
            if nsp == "" {
                ackNum = String(arr[1...arr.count-1])
            } else {
                ackNum = messageGroups![3]
            }
            
            let ackData:AnyObject? = self.parseData(messageGroups![4])
            socket.handleAck(ackNum.toInt()!, data: ackData)
            
            return
        }
        /**
        End Check for message
        **/
    }
    
    // Handles binary data
    class func parseBinaryData(data:NSData, socket:SocketIOClient) {
        // NSLog(data.base64EncodedStringWithOptions(NSDataBase64EncodingOptions.allZeros))
        
        if socket.waitingData.count == 0 {
            NSLog("Got data when not remaking packet")
            return
        }
        
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
        // NSLog(message)
        
        /**
        Begin check for binary placeholders
        **/
        var binaryGroup:[String]?
        
        if let groups = message["^(\\d*)-\\/?(\\w*)?,?(\\d*)?\\[(\".*?\")?,?(.*)?\\]$",
            NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                binaryGroup = groups
        } else if let groups = message["^(\\d*)-\\/?(\\w*)?,?(\\d*)?\\[(.*?)?\\]$",
            NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                binaryGroup = groups
        } else {
            NSLog("Error in parsing binary message: %s", message)
            return
        }
        
        if binaryGroup![1].hasPrefix("5") {
            // println(binaryGroup)
            var ackNum:String
            var event:String
            var mutMessageObject:String
            var namespace:String?
            var numberOfPlaceholders:String
            
            let messageType = binaryGroup![1]
            
            namespace = binaryGroup![2]
            if binaryGroup![3] != "" {
                ackNum = binaryGroup![3] as String
            } else if socket.nsp == nil && binaryGroup![2] != "" {
                ackNum = binaryGroup![2]
            } else {
                ackNum = ""
            }
            
            numberOfPlaceholders = (messageType["5"] ~= "") as String
            event = (binaryGroup![4]["\""] ~= "") as String
            mutMessageObject = binaryGroup![5]
            
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
        } else if binaryGroup![1].hasPrefix("6") {
            let messageType = binaryGroup![1]
            let numberOfPlaceholders = (messageType["6"] ~= "") as String
            var ackNum:String
            var nsp:String
            
            if binaryGroup![3] == "" {
                ackNum = binaryGroup![2]
                nsp = ""
            } else {
                ackNum = binaryGroup![3]
                nsp = binaryGroup![2]
            }
            
            if nsp == "" && socket.nsp != nil {
                return
            }
            var mutMessageObject = binaryGroup![5]
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
