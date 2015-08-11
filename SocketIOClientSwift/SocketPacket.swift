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

struct SocketPacket {
    let nsp: String
    let id: Int
    let placeholders: Int
    let type: PacketType
    
    enum PacketType: Int {
        case Connect, Disconnect, Event, Ack, Error, BinaryEvent, BinaryAck
        
        init?(str: String) {
            if let int = Int(str), raw = PacketType(rawValue: int) {
                self = raw
            } else {
                return nil
            }
        }
    }
    
    var currentPlace = 0
    var binary: [NSData]
    var data: [AnyObject]
    var description: String {
        var better = "SocketPacket {type: ~~0; data: ~~1; " +
        "id: ~~2; placeholders: ~~3;}"
        
        better = better["~~0"] ~= String(type.rawValue)
        better = better["~~1"] ~= String(data)
        better = better["~~2"] ~= String(id)
        better = better["~~3"] ~= String(placeholders)
        
        return better
    }
    
    init(type: SocketPacket.PacketType, data: [AnyObject] = [AnyObject](), id: Int = -1,
        nsp: String, placeholders: Int = 0, binary: [NSData] = [NSData]()) {
        self.data = data
        self.id = id
        self.nsp = nsp
        self.type = type
        self.placeholders = placeholders
        self.binary = binary
    }
    
    mutating func addData(data: NSData) -> Bool {
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
    
    private func completeMessage(var message: String, ack: Bool) -> String {
        if data.count == 0 {
            return message + "]"
        } else if !ack {
            message += ","
        }
        
        for arg in data {
            if arg is NSDictionary || arg is [AnyObject] {
                do {
                    let jsonSend = try NSJSONSerialization.dataWithJSONObject(arg,
                        options: NSJSONWritingOptions(rawValue: 0))
                    let jsonString = NSString(data: jsonSend, encoding: NSUTF8StringEncoding)
                    
                    message += jsonString! as String + ","
                } catch {
                    print("Error creating JSON object in SocketPacket.completeMessage")
                }
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
    
    func createAck() -> String {
        let msg: String
        
        if type == PacketType.Ack {
            if nsp == "/" {
                msg = "3\(id)["
            } else {
                msg = "3\(nsp),\(id)["
            }
        } else {
            if nsp == "/" {
                msg = "6\(binary.count)-\(id)["
            } else {
                msg = "6\(binary.count)-/\(nsp),\(id)["
            }
        }
        
        return completeMessage(msg, ack: true)
    }

    
    func createMessageForEvent(event: String) -> String {
        let message: String
        
        if type == PacketType.Event {
            if nsp == "/" {
                if id == -1 {
                    message = "2[\"\(event)\""
                } else {
                    message = "2\(id)[\"\(event)\""
                }
            } else {
                if id == -1 {
                    message = "2\(nsp),[\"\(event)\""
                } else {
                    message = "2\(nsp),\(id)[\"\(event)\""
                }
            }
        } else {
            if nsp == "/" {
                if id == -1 {
                    message = "5\(binary.count)-[\"\(event)\""
                } else {
                    message = "5\(binary.count)-\(id)[\"\(event)\""
                }
            } else {
                if id == -1 {
                    message = "5\(binary.count)-\(nsp),[\"\(event)\""
                } else {
                    message = "5\(binary.count)-\(nsp),\(id)[\"\(event)\""
                }
            }
        }
        
        return completeMessage(message, ack: false)
    }
    
    mutating func fillInPlaceholders() {
        let newArr = NSMutableArray(array: data)
        
        for i in 0..<data.count {
            if let str = data[i] as? String, num = str["~~(\\d)"].groups() {
                newArr[i] = binary[Int(num[1])!]
            } else if data[i] is NSDictionary || data[i] is NSArray {
                newArr[i] = _fillInPlaceholders(data[i])
            }
        }
        
        data = newArr as [AnyObject]
    }
    
    private mutating func _fillInPlaceholders(data: AnyObject) -> AnyObject {
        if let str = data as? String {
            if let num = str["~~(\\d)"].groups() {
                return binary[Int(num[1])!]
            } else {
                return str
            }
        } else if let dict = data as? NSDictionary {
            let newDict = NSMutableDictionary(dictionary: dict)
            
            for (key, value) in dict {
                newDict[key as! NSCopying] = _fillInPlaceholders(value)
            }
            
            return newDict
        } else if let arr = data as? NSArray {
            let newArr = NSMutableArray(array: arr)
            
            for i in 0..<arr.count {
                newArr[i] = _fillInPlaceholders(arr[i])
            }
            
            return newArr
        } else {
            return data
        }
    }
    
    func getEvent() -> String {
        return data[0] as! String
    }
    
    func getArgs() -> [AnyObject]? {
        var arr = data

        if data.count == 0 {
            return nil
        } else {
            if type == PacketType.Event || type == PacketType.BinaryEvent {
                arr.removeAtIndex(0)
                return arr
            } else {
                return arr
            }
        }
    }
}

extension SocketPacket {
    private static func findType(binCount: Int, ack: Bool) -> PacketType {
        switch binCount {
        case 0 where !ack:
            return PacketType.Event
        case 0 where ack:
            return PacketType.Ack
        case _ where !ack:
            return PacketType.BinaryEvent
        case _ where ack:
            return PacketType.BinaryAck
        default:
            return PacketType.Error
        }
    }
    
    static func packetFromEmitWithData(data: [AnyObject], id: Int, nsp: String) -> SocketPacket {
        let (parsedData, binary) = deconstructData(data)
        let packet = SocketPacket(type: findType(binary.count, ack: false), data: parsedData,
            id: id, nsp: nsp, placeholders: -1, binary: binary)
        
        return packet
    }
    
    static func packetFromEmitAckWithData(data: [AnyObject], id: Int, nsp: String) -> SocketPacket {
        let (parsedData, binary) = deconstructData(data)
        let packet = SocketPacket(type: findType(binary.count, ack: true), data: parsedData,
            id: id, nsp: nsp, placeholders: -1, binary: binary)
        
        return packet
    }
}

private extension SocketPacket {
    static func shred(data: AnyObject, inout binary: [NSData]) -> AnyObject {
        if let bin = data as? NSData {
            let placeholder = ["_placeholder" :true, "num": binary.count]
            
            binary.append(bin)
            
            return placeholder
        } else if let arr = data as? NSArray {
            let newArr = NSMutableArray(array: arr)
            
            for i in 0..<arr.count {
                newArr[i] = shred(arr[i], binary: &binary)
            }
            
            return newArr
        } else if let dict = data as? NSDictionary {
            let newDict = NSMutableDictionary(dictionary: dict)
            
            for (key, value) in newDict {
                newDict[key as! NSCopying] = shred(value, binary: &binary)
            }
            
            return newDict
        } else {
            return data
        }
    }
    
    static func deconstructData(var data: [AnyObject]) -> ([AnyObject], [NSData]) {
        var binary = [NSData]()
        
        for i in 0..<data.count {
            if data[i] is NSArray || data[i] is NSDictionary {
                data[i] = shred(data[i], binary: &binary)
            } else if let bin = data[i] as? NSData {
                data[i] = ["_placeholder" :true, "num": binary.count]
                binary.append(bin)
            }
        }
        
        return (data, binary)
    }
}
