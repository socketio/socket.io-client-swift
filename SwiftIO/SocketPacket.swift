//
//  SocketPacket.swift
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

enum SocketPacketType: Int {
    case CONNECT = 0
    case DISCONNECT = 1
    case EVENT = 2
    case ACK = 3
    case ERROR = 4
    case BINARY_EVENT = 5
    case BINARY_ACK = 6
    
    init(str:String) {
        if let int = str.toInt() {
            self = SocketPacketType(rawValue: int)!
        } else {
            self = SocketPacketType(rawValue: 4)!
        }
    }
}

class SocketPacket {
    var binary = [NSData]()
    var currentPlace = 0
    var data:[AnyObject]?
    var id:Int?
    var justAck = false
    var nsp = ""
    var placeholders:Int?
    var type:SocketPacketType?
    
    init(type:SocketPacketType?, data:[AnyObject]? = nil, nsp:String = "",
        placeholders:Int? = nil, id:Int? = nil) {
            self.type = type
            self.data = data
            self.nsp = nsp
            self.placeholders = placeholders
            self.id = id
    }
    
    func getEvent() -> String {
        return data?.removeAtIndex(0) as String
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
        
        self.binary.append(data)
        self.currentPlace++
        
        if checkDoEvent() {
            self.currentPlace = 0
            return true
        } else {
            return false
        }
    }
    
    func createMessageForEvent(event:String) -> String {
            var message:String
            var jsonSendError:NSError?
            
            if self.binary.count == 0 {
                self.type = SocketPacketType.EVENT
                
                if self.nsp == "/" {
                    if self.id == nil {
                        message = "2[\"\(event)\""
                    } else {
                        message = "2\(self.id!)[\"\(event)\""
                    }
                } else {
                    if self.id == nil {
                        message = "2/\(self.nsp),[\"\(event)\""
                    } else {
                        message = "2/\(self.nsp),\(self.id!)[\"\(event)\""
                    }
                }
            } else {
                self.type = SocketPacketType.BINARY_EVENT
                
                if self.nsp == "/" {
                    if self.id == nil {
                        message = "5\(self.binary.count)-[\"\(event)\""
                    } else {
                        message = "5\(self.binary.count)-\(self.id!)[\"\(event)\""
                    }
                } else {
                    if self.id == nil {
                        message = "5\(self.binary.count)-/\(self.nsp),[\"\(event)\""
                    } else {
                        message = "5\(self.binary.count)-/\(self.nsp),\(self.id!)[\"\(event)\""
                    }
                }
            }
            
            return self.completeMessage(message)
    }
    
    func createAck() -> String {
            var msg:String
            
            if self.binary.count == 0 {
                if nsp == "/" {
                    msg = "3\(self.id!)["
                } else {
                    msg = "3/\(self.nsp),\(self.id!)["
                }
            } else {
                if nsp == "/" {
                    msg = "6\(self.binary.count)-\(self.id!)["
                } else {
                    msg = "6\(self.binary.count)-/\(self.nsp),\(self.id!)["
                }
            }
            
            return self.completeMessage(msg, ack: true)
    }
    
    func completeMessage(var message:String, ack:Bool = false) -> String {
        var err:NSError?
        
        if self.data == nil || self.data!.count == 0 {
            return message + "]"
        } else if !ack {
            message += ","
        }
        
        for arg in self.data! {
            
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
                if let num = str["~~(\\d)"].groups() {
                    newArr[i] = self.binary[num[1].toInt()!]
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
                if let num = str["~~(\\d)"].groups() {
                    newDict[key as String] = self.binary[num[1].toInt()!]
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
    
    func fillInPlaceholders() {
        var newArr = [AnyObject](count: self.data!.count, repeatedValue: 0)
        
        for i in 0..<self.data!.count {
            if let str = self.data?[i] as? String {
                if let num = str["~~(\\d)"].groups() {
                    newArr[i] = self.binary[num[1].toInt()!]
                } else {
                    newArr[i] = str
                }
            } else if let arr = self.data?[i] as? NSArray {
                newArr[i] = self.fillInArray(arr)
            } else if let dict = self.data?[i] as? NSDictionary {
                newArr[i] = self.fillInDict(dict)
            } else {
                newArr[i] = self.data![i]
            }
        }
        
        self.data = newArr
    }
}
