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
    class func parseData(data:String) -> AnyObject? {
        var err:NSError?
        let stringData = data.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
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
    class func parseSocketMessage(var stringMessage:String, socket:SocketIOClient) {
        if stringMessage == "" {
            return
        }
        
        // NSLog(stringMessage)
        
        let type = stringMessage.removeAtIndex(stringMessage.startIndex)
        
        if type == "2" {
            if let groups = stringMessage["(\\/(\\w*))?,?(\\d*)?\\[\"(.*?)\",?(.*?)?\\]$",
                NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                    let namespace = groups[2]
                    let ackNum = groups[3]
                    let event = groups[4]
                    let data = "[\(groups[5])]"
                    
                    if namespace == "" && socket.nsp != nil {
                        return
                    }
                    
                    if let parsed:AnyObject? = self.parseData(data) {
                        if ackNum == "" {
                            socket.handleEvent(event, data: parsed as? NSArray)
                        } else {
                            socket.currentAck = ackNum.toInt()!
                            socket.handleEvent(event, data: parsed as? NSArray, wantsAck: ackNum.toInt(), withAckType: 3)
                        }
                    }
            }
        } else if type == "3" {
            if let ackGroup = stringMessage["(\\/(\\w*))?,?(\\d*)?\\[(.*?)?\\]$",
                NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                    let nsp = ackGroup[2]
                    let ackNum = ackGroup[3]
                    let ackData:AnyObject? = self.parseData("[\(ackGroup[4])]")
                    
                    if nsp == "" && socket.nsp != nil {
                        return
                    }
                    
                    socket.handleAck(ackNum.toInt()!, data: ackData)
            }
        } else if type == "4" {
            NSLog("Got Error packet")
        } else if type == "5" {
            self.parseBinaryMessage(stringMessage, socket: socket, type: "5")
        } else if type == "6" {
            self.parseBinaryMessage(stringMessage, socket: socket, type: "6")
        } else if type == "0" {
            if socket.nsp != nil {
                // Join namespace
                socket.joinNamespace()
                return
            } else if socket.nsp != nil && stringMessage == "/\(socket.nsp!)" {
                socket.didConnect()
                return
            } else {
                socket.didConnect()
                return
            }
        } else if type == "1" {
            socket.didForceClose(message: "Got disconnect")
        } else {
            NSLog("Error in parsing message: %s", stringMessage)
        }
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
            
            if let args:AnyObject = self.parseData(socketEvent.args as String) {
                let filledInArgs = socketEvent.fillInPlaceholders()
                
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
                let filledInArgs = socketEvent.fillInPlaceholders()
                
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
    class func parseBinaryMessage(stringMessage:String, socket:SocketIOClient, type:String) {
        // NSLog(message)
        
        if type == "5" {
            if let groups = stringMessage["^(\\d*)-(\\/(\\w*))?,?(\\d*)?\\[\"(.*?)\",?(.*)?\\]$",
                NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                    let numberOfPlaceholders = groups[1]
                    let namespace = groups[3]
                    let ackNum = groups[4]
                    let event = groups[5]
                    let mutMessageObject = groups[6]
                    
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
            }
        } else if type == "6" {
            if let groups = stringMessage["^(\\d*)-(\\/(\\w*))?,?(\\d*)?\\[(.*?)?\\]$",
                NSRegularExpressionOptions.DotMatchesLineSeparators].groups() {
                    let numberOfPlaceholders = groups[1]
                    let namespace = groups[3]
                    let ackNum = groups[4]
                    let mutMessageObject = groups[5]
                    
                    if namespace == "" && socket.nsp != nil {
                        return
                    }
                    let placeholdersRemoved = mutMessageObject["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"]
                        ~= "\"~~$2\""
                    
                    let event = SocketEvent(event: "", args: placeholdersRemoved,
                        placeholders: numberOfPlaceholders.toInt()!, ackNum: ackNum.toInt(), justAck: true)
                    
                    socket.waitingData.append(event)
            }
        } else {
            NSLog("Error in parsing binary message: %s", stringMessage)
            return
        }
    }
}
