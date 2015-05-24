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

final class SocketPacket: Printable {
    var binary = ContiguousArray<NSData>()
    var currentPlace = 0
    var data:[AnyObject]?
    var description:String {
        var better = "SocketPacket {type: ~~0; data: ~~1; " +
        "id: ~~2; placeholders: ~~3;}"
        
        better = better["~~0"] ~= (type != nil ? String(type!.rawValue) : "nil")
        better = better["~~1"] ~= (data != nil ? "\(data!)" : "nil")
        better = better["~~2"] ~= (id != nil ? String(id!) : "nil")
        better = better["~~3"] ~= (placeholders != nil ? String(placeholders!) : "nil")
        
        return better
    }
    var id:Int?
    var justAck = false
    var nsp = ""
    var placeholders:Int?
    var type:PacketType?
    
    enum PacketType:Int {
        case CONNECT = 0
        case DISCONNECT = 1
        case EVENT = 2
        case ACK = 3
        case ERROR = 4
        case BINARY_EVENT = 5
        case BINARY_ACK = 6
        
        init?(str:String) {
            if let int = str.toInt(), raw = PacketType(rawValue: int) {
                self = raw
            } else {
                return nil
            }
        }
    }
    
    init(type:PacketType?, data:[AnyObject]? = nil, nsp:String = "",
        placeholders:Int? = nil, id:Int? = nil) {
            self.type = type
            self.data = data
            self.nsp = nsp
            self.placeholders = placeholders
            self.id = id
    }
    
    func getEvent() -> String {
        return data?.removeAtIndex(0) as! String
    }
    
    func addData(data:NSData) -> Bool {
        if placeholders == currentPlace {
            return true
        }
        
        binary.append(data)
        currentPlace++
        
        if placeholders == currentPlace {
            currentPlace = 0
            return true
        } else {
            return false
        }
    }
    
    func createMessageForEvent(event:String) -> String {
        let message:String
        
        if binary.count == 0 {
            type = PacketType.EVENT
            
            if nsp == "/" {
                if id == nil {
                    message = "2[\"\(event)\""
                } else {
                    message = "2\(id!)[\"\(event)\""
                }
            } else {
                if id == nil {
                    message = "2/\(nsp),[\"\(event)\""
                } else {
                    message = "2/\(nsp),\(id!)[\"\(event)\""
                }
            }
        } else {
            type = PacketType.BINARY_EVENT
            
            if nsp == "/" {
                if id == nil {
                    message = "5\(binary.count)-[\"\(event)\""
                } else {
                    message = "5\(binary.count)-\(id!)[\"\(event)\""
                }
            } else {
                if id == nil {
                    message = "5\(binary.count)-/\(nsp),[\"\(event)\""
                } else {
                    message = "5\(binary.count)-/\(nsp),\(id!)[\"\(event)\""
                }
            }
        }
        
        return completeMessage(message)
    }
    
    func createAck() -> String {
        var msg:String
        
        if binary.count == 0 {
            type = PacketType.ACK
            
            if nsp == "/" {
                msg = "3\(id!)["
            } else {
                msg = "3/\(nsp),\(id!)["
            }
        } else {
            type = PacketType.BINARY_ACK
            
            if nsp == "/" {
                msg = "6\(binary.count)-\(id!)["
            } else {
                msg = "6\(binary.count)-/\(nsp),\(id!)["
            }
        }
        
        return completeMessage(msg, ack: true)
    }
    
    private func completeMessage(var message:String, ack:Bool = false) -> String {
        var err:NSError?
        
        if data == nil || data!.count == 0 {
            return message + "]"
        } else if !ack {
            message += ","
        }
        
        for arg in data! {
            if arg is NSDictionary || arg is [AnyObject] {
                let jsonSend = NSJSONSerialization.dataWithJSONObject(arg,
                    options: NSJSONWritingOptions(0), error: &err)
                let jsonString = NSString(data: jsonSend!, encoding: NSUTF8StringEncoding)
                
                message += jsonString! as String + ","
            } else if var str = arg as? String {
                str = str["\n"] ~= "\\\\n"
                str = str["\r"] ~= "\\\\r"
                
                message += "\"\(str)\","
            } else if arg is NSNull {
                message += "null,"
            } else {
                message += "\(arg),"
            }
        }
        
        if message != "" {
            message.removeAtIndex(message.endIndex.predecessor())
        }
        
        return message + "]"
    }
    
    func fillInPlaceholders() {
        var newArr = NSMutableArray(array: data!)
        
        for i in 0..<data!.count {
            if let str = data?[i] as? String, num = str["~~(\\d)"].groups() {
                newArr[i] = binary[num[1].toInt()!]
            } else if data?[i] is NSDictionary || data?[i] is NSArray {
                newArr[i] = _fillInPlaceholders(data![i])
            }
        }
        
        data = newArr as [AnyObject]
    }
    
    private func _fillInPlaceholders(data:AnyObject) -> AnyObject {
        if let str = data as? String {
            if let num = str["~~(\\d)"].groups() {
                return binary[num[1].toInt()!]
            } else {
                return str
            }
        } else if let dict = data as? NSDictionary {
            var newDict = NSMutableDictionary(dictionary: dict)
            
            for (key, value) in dict {
                newDict[key as! NSCopying] = _fillInPlaceholders(value)
            }
            
            return newDict
        } else if let arr = data as? NSArray {
            var newArr = NSMutableArray(array: arr)
            
            for i in 0..<arr.count {
                newArr[i] = _fillInPlaceholders(arr[i])
            }
            
            return newArr
        } else {
            return data
        }
    }
}
