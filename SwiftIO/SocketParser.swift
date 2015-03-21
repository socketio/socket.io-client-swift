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
    // Translation of socket.io-client#decodeString
    class func parseString(str:String) -> SocketPacket? {
        let arr = Array(str)
        let type = String(arr[0])
        
        if arr.count == 1 {
            return SocketPacket(type: SocketPacketType(str: type))
        }
        
        var id = nil as Int?
        var nsp = ""
        var i = 0
        var placeholders = -1
        
        if type == "5" || type == "6" {
            var buf = ""
            
            while arr[++i] != "-" {
                buf += String(arr[i])
                if i == arr.count {
                    break
                }
            }
            
            if buf.toInt() == nil || arr[i] != "-" {
                println(buf)
                NSLog("Error parsing \(str)")
                return nil
            } else {
                placeholders = buf.toInt()!
            }
        }
        
        if arr[i + 1] == "/" {
            while ++i < arr.count {
                let c = arr[i]
                
                if c == "," {
                    break
                }
                
                nsp += String(c)
            }
        }
        
        if i + 1 >= arr.count {
            return SocketPacket(type: SocketPacketType(str: type),
                nsp: nsp, placeholders: placeholders, id: id)
        }
        
        let next = String(arr[i + 1])
        
        if next.toInt() != nil {
            var c = ""
            while ++i < arr.count {
                if let int = String(arr[i]).toInt() {
                    c += String(arr[i])
                } else {
                    --i
                    break
                }
            }
            
            id = c.toInt()
        }
        
        if i + 1 < arr.count {
            let d = String(arr[++i...arr.count-1])
            let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
            
            let data = SocketParser.parseData(noPlaceholders) as [AnyObject]
            
            return SocketPacket(type: SocketPacketType(str: type), data: data,
                nsp: nsp, placeholders: placeholders, id: id)
        }
        
        return nil
    }
    
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
        
        func checkNSP(nsp:String) -> Bool {
            if nsp == "" && socket.nsp != nil {
                return true
            } else {
                return false
            }
        }
        
        var p = parseString(stringMessage) as SocketPacket!
        
        
        if p.type == SocketPacketType.EVENT {
            if checkNSP(p.nsp) {
                return
            }
            
            socket.handleEvent(p.getEvent(), data: p.data, isInternalMessage: false, wantsAck: p.id, withAckType: 3)
        } else if p.type == SocketPacketType.ACK {
            if checkNSP(p.nsp) {
                return
            }
            
            socket.handleAck(p.id!, data: p.data)
        } else if p.type == SocketPacketType.BINARY_EVENT {
            if checkNSP(p.nsp) {
                return
            }
            
            socket.waitingData.append(p)
        } else if p.type == SocketPacketType.BINARY_ACK {
            if checkNSP(p.nsp) {
                return
            }
            
            p.justAck = true
            socket.waitingData.append(p)
        } else if p.type == SocketPacketType.CONNECT {
            if p.nsp == "" && socket.nsp != nil {
                socket.joinNamespace()
            } else if p.nsp != "" && socket.nsp == nil {
                socket.didConnect()
            } else {
                socket.didConnect()
            }
        } else if p.type == SocketPacketType.DISCONNECT {
            socket.didForceClose(message: "Got Disconnect")
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
        
        if !shouldExecute {
            return
        }
        
        let packet = socket.waitingData.removeAtIndex(0)
        packet.fillInPlaceholders()
        
        if !packet.justAck {
            socket.handleEvent(packet.getEvent(), data: packet.data,
                wantsAck: packet.id, withAckType: 6)
        } else {
            socket.handleAck(packet.id!, data: packet.data)
        }
    }
}
