//
//  SocketPacket.swift
//  Socket.IO-Client-Swift
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
//

import Foundation

struct SocketPacket {
    private let placeholders: Int
    private var currentPlace = 0
    
    private static let logType = "SocketPacket"

    let nsp: String
    let id: Int
    let type: PacketType
    
    enum PacketType: Int {
        case Connect, Disconnect, Event, Ack, Error, BinaryEvent, BinaryAck
    }
    
    var args: [AnyObject] {
        if type == .Event || type == .BinaryEvent && data.count != 0 {
            return Array(data.dropFirst())
        } else {
            return data
        }
    }
    
    var binary: [NSData]
    var data: [AnyObject]
    var description: String {
        return "SocketPacket {type: \(String(type.rawValue)); data: " +
            "\(String(data)); id: \(id); placeholders: \(placeholders); nsp: \(nsp)}"
    }
    
    var event: String {
        return String(data[0])
    }
    
    var packetString: String {
        return createPacketString()
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
        currentPlace += 1
        
        if placeholders == currentPlace {
            fillInPlaceholders()
            return true
        } else {
            return false
        }
    }
    
    private func completeMessage(message: String, ack: Bool) -> String {
        var restOfMessage = ""
        
        if data.count == 0 {
            return message + "]"
        }
        
        for arg in data {
            if arg is NSDictionary || arg is [AnyObject] {
                do {
                    let jsonSend = try NSJSONSerialization.dataWithJSONObject(arg,
                        options: NSJSONWritingOptions(rawValue: 0))
                    let jsonString = String(data: jsonSend, encoding: NSUTF8StringEncoding)
                    
                    restOfMessage += jsonString! + ","
                } catch {
                    DefaultSocketLogger.Logger.error("Error creating JSON object in SocketPacket.completeMessage",
                        type: SocketPacket.logType)
                }
            } else if let str = arg as? String {
                restOfMessage += "\"" + ((str["\n"] ~= "\\\\n")["\r"] ~= "\\\\r") + "\","
            } else if arg is NSNull {
                restOfMessage += "null,"
            } else {
                restOfMessage += "\(arg),"
            }
        }
        
        if restOfMessage != "" {
            restOfMessage.removeAtIndex(restOfMessage.endIndex.predecessor())
        }
        
        return message + restOfMessage + "]"
    }
    
    private func createAck() -> String {
        let message: String
        
        if type == .Ack {
            if nsp == "/" {
                message = "3\(id)["
            } else {
                message = "3\(nsp),\(id)["
            }
        } else {
            if nsp == "/" {
                message = "6\(binary.count)-\(id)["
            } else {
                message = "6\(binary.count)-\(nsp),\(id)["
            }
        }
        
        return completeMessage(message, ack: true)
    }

    
    private func createMessageForEvent() -> String {
        let message: String
        
        if type == .Event {
            if nsp == "/" {
                if id == -1 {
                    message = "2["
                } else {
                    message = "2\(id)["
                }
            } else {
                if id == -1 {
                    message = "2\(nsp),["
                } else {
                    message = "2\(nsp),\(id)["
                }
            }
        } else {
            if nsp == "/" {
                if id == -1 {
                    message = "5\(binary.count)-["
                } else {
                    message = "5\(binary.count)-\(id)["
                }
            } else {
                if id == -1 {
                    message = "5\(binary.count)-\(nsp),["
                } else {
                    message = "5\(binary.count)-\(nsp),\(id)["
                }
            }
        }
        
        return completeMessage(message, ack: false)
    }
    
    private func createPacketString() -> String {
        let str: String
        
        if type == .Event || type == .BinaryEvent {
            str = createMessageForEvent()
        } else {
            str = createAck()
        }
        
        return str
    }
    
    private mutating func fillInPlaceholders() {
        data = data.map({_fillInPlaceholders($0)})
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
        } else if let arr = data as? [AnyObject] {
            return arr.map({_fillInPlaceholders($0)})
        } else {
            return data
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
    
    static func packetFromEmit(items: [AnyObject], id: Int, nsp: String, ack: Bool) -> SocketPacket {
        let (parsedData, binary) = deconstructData(items)
        let packet = SocketPacket(type: findType(binary.count, ack: ack), data: parsedData,
            id: id, nsp: nsp, placeholders: -1, binary: binary)
        
        return packet
    }
}

private extension SocketPacket {
    static func shred(data: AnyObject, inout binary: [NSData]) -> AnyObject {
        if let bin = data as? NSData {
            let placeholder = ["_placeholder": true, "num": binary.count]
            
            binary.append(bin)
            
            return placeholder
        } else if let arr = data as? [AnyObject] {
            return arr.map({shred($0, binary: &binary)})
        } else if let dict = data as? NSDictionary {
            let mutDict = NSMutableDictionary(dictionary: dict)
            
            for (key, value) in dict {
                mutDict[key as! NSCopying] = shred(value, binary: &binary)
            }
            
            return mutDict
        } else {
            return data
        }
    }
    
    static func deconstructData(data: [AnyObject]) -> ([AnyObject], [NSData]) {
        var binary = [NSData]()
        
        return (data.map({shred($0, binary: &binary)}), binary)
    }
}
