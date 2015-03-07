//
//  Event.swift
//  Socket.IO-Swift
//
//  Created by Erik Little on 1/18/15.
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

class SocketEvent {
    let justAck:Bool!
    var ack:Int?
    var args:AnyObject!
    lazy var currentPlace = 0
    lazy var datas = [NSData]()
    var event:String!
    var placeholders:Int!
    
    init(event:String, args:AnyObject?, placeholders:Int = 0, ackNum:Int? = nil, justAck:Bool = false) {
        self.event = event
        self.args = args
        self.placeholders = placeholders
        self.ack = ackNum
        self.justAck = justAck
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
    
    class func createMessageForEvent(event:String, withArgs args:[AnyObject],
        hasBinary:Bool, withDatas datas:Int = 0, toNamespace nsp:String?, wantsAck ack:Int? = nil) -> String {
            
            var message:String
            var jsonSendError:NSError?
            
            if !hasBinary {
                if nsp == nil {
                    if ack == nil {
                        message = "2[\"\(event)\""
                    } else {
                        message = "2\(ack!)[\"\(event)\""
                    }
                } else {
                    if ack == nil {
                        message = "2/\(nsp!),[\"\(event)\""
                    } else {
                        message = "2/\(nsp!),\(ack!)[\"\(event)\""
                    }
                }
            } else {
                if nsp == nil {
                    if ack == nil {
                        message = "5\(datas)-[\"\(event)\""
                    } else {
                        message = "5\(datas)-\(ack!)[\"\(event)\""
                    }
                } else {
                    if ack == nil {
                        message = "5\(datas)-/\(nsp!),[\"\(event)\""
                    } else {
                        message = "5\(datas)-/\(nsp!),\(ack!)[\"\(event)\""
                    }
                }
            }
            
            return self.completeMessage(message, args: args)
    }
    
    class func createAck(ack:Int, withArgs args:[AnyObject], withAckType ackType:Int,
        withNsp nsp:String, withBinary binary:Int = 0) -> String {
            var msg:String
            
            if ackType == 3 {
                if nsp == "/" {
                    msg = "3\(ack)["
                } else {
                    msg = "3/\(nsp),\(ack)["
                }
            } else {
                if nsp == "/" {
                    msg = "6\(binary)-\(ack)["
                } else {
                    msg = "6\(binary)-/\(nsp),\(ack)["
                }
            }
            
            return self.completeMessage(msg, args: args, ack: true)
    }
    
    private class func completeMessage(var message:String, args:[AnyObject], ack:Bool = false) -> String {
        var err:NSError?
        
        if args.count == 0 {
            return message + "]"
        } else if !ack {
            message += ","
        }
        
        for arg in args {
            
            if arg is NSDictionary || arg is [AnyObject] {
                let jsonSend = NSJSONSerialization.dataWithJSONObject(arg,
                    options: NSJSONWritingOptions(0), error: &err)
                let jsonString = NSString(data: jsonSend!, encoding: NSUTF8StringEncoding)
                
                message += jsonString! as String
                message += ","
                continue
            }
            
            if arg is String {
                message += "\"\(arg)\""
                message += ","
                continue
            }
            
            message += "\(arg)"
            message += ","
        }
        
        if message != "" {
            message.removeAtIndex(message.endIndex.predecessor())
        }
        
        return message + "]"
    }
    
    private func fillInArray(arr:NSArray) -> NSArray {
        var newArr = [AnyObject](count: arr.count, repeatedValue: 0)
        // println(arr)
        
        for i in 0..<arr.count {
            if let nest = arr[i] as? NSArray {
                newArr[i] = self.fillInArray(nest)
            } else if let dict = arr[i] as? NSDictionary {
                newArr[i] = self.fillInDict(dict)
            } else if let str = arr[i] as? String {
                let mut = RegexMutable(str)
                if let num = mut["~~(\\d)"].groups() {
                    newArr[i] = self.datas[num[1].toInt()!]
                } else {
                    newArr[i] = arr[i]
                }
            } else {
                newArr[i] = arr[i]
            }
        }
        
        return newArr
    }
    
    private func fillInDict(dict:NSDictionary) -> NSDictionary {
        var newDict = [String: AnyObject]()
        
        for (key, value) in dict {
            newDict[key as String] = value
            
            // If the value is a string we need to check
            // if it is a placeholder for data
            if let str = value as? String {
                let mut = RegexMutable(str)
                
                if let num = mut["~~(\\d)"].groups() {
                    newDict[key as String] = self.datas[num[1].toInt()!]
                } else {
                    newDict[key as String] = str
                }
            } else if let nestDict = value as? NSDictionary {
                newDict[key as String] = self.fillInDict(nestDict)
            } else if let arr = value as? NSArray {
                newDict[key as String] = self.fillInArray(arr)
            }
        }
        
        return newDict
    }
    
    func fillInPlaceholders(_ args:AnyObject = true) -> AnyObject {
        if let dict = args as? NSDictionary {
            return self.fillInDict(dict)
        } else if let arr = args as? NSArray {
            return self.fillInArray(args as NSArray)
        } else if let string = args as? String {
            if string == "~~\(self.currentPlace)" {
                return self.datas[0]
            }
        } else if args is Bool {
            // We have multiple items
            // Do it live
            let argsAsArray = "[\(self.args)]"
            if let parsedArr = SocketIOClient.parseData(argsAsArray) as? NSArray {
                var returnArr = [AnyObject](count: parsedArr.count, repeatedValue: 0)
                
                for i in 0..<parsedArr.count {
                    if let str = parsedArr[i] as? String {
                        let mut = RegexMutable(str)
                        
                        if let num = mut["~~(\\d)"].groups() {
                            returnArr[i] = self.datas[num[1].toInt()!]
                        } else {
                            returnArr[i] = str
                        }
                    } else if let arr = parsedArr[i] as? NSArray {
                        returnArr[i] = self.fillInArray(arr)
                    } else if let dict = parsedArr[i] as? NSDictionary {
                        returnArr[i] = self.fillInDict(dict)
                    } else {
                        returnArr[i] = parsedArr[i]
                    }
                }
                return returnArr
            }
        }
        
        return false
    }
}