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
    private static let shredder = SocketParser.PacketShredder()
    
    // Translation of socket.io-parser#deconstructPacket
    private final class PacketShredder {
        var buf = ContiguousArray<NSData>()
        
        func shred(data:AnyObject) -> AnyObject {
            if let bin = data as? NSData {
                let placeholder = ["_placeholder" :true, "num": buf.count]
                
                buf.append(bin)
                
                return placeholder
            } else if let arr = data as? NSArray {
                var newArr = NSMutableArray(array: arr)
                
                for i in 0..<arr.count {
                    newArr[i] = shred(arr[i])
                }
                
                return newArr
            } else if let dict = data as? NSDictionary {
                var newDict = NSMutableDictionary(dictionary: dict)
                
                for (key, value) in newDict {
                    newDict[key as! NSCopying] = shred(value)
                }
                
                return newDict
            } else {
                return data
            }
        }
        
        func deconstructPacket(packet:SocketPacket) {
            if packet.data == nil {
                return
            }
            
            var data = packet.data!
            
            for i in 0..<data.count {
                if data[i] is NSArray || data[i] is NSDictionary {
                    data[i] = shred(data[i])
                } else if let bin = data[i] as? NSData {
                    data[i] = ["_placeholder" :true, "num": buf.count]
                    buf.append(bin)
                }
            }
            
            packet.data = data
            packet.binary = buf
            buf.removeAll(keepCapacity: true)
        }
    }
    
    // Translation of socket.io-client#decodeString
    static func parseString(str:String) -> SocketPacket? {
        let arr = Array(str)
        let type = String(arr[0])
        
        if arr.count == 1 {
            return SocketPacket(type: SocketPacket.PacketType(str: type))
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
            
            if let holders = buf.toInt() where arr[i] == "-" {
                placeholders = holders
            } else {
                NSLog("Error parsing \(str)")
                return nil
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
            return SocketPacket(type: SocketPacket.PacketType(str: type),
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
        
        if ++i < arr.count {
            let d = String(arr[i...arr.count-1])
            let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
            let data = SocketParser.parseData(noPlaceholders) as? [AnyObject] ?? [noPlaceholders]
            
            return SocketPacket(type: SocketPacket.PacketType(str: type), data: data,
                nsp: nsp, placeholders: placeholders, id: id)
        }
        
        return nil
    }
    
    // Parses data for events
    static func parseData(data:String) -> AnyObject? {
        var err:NSError?
        let stringData = data.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
        let parsed:AnyObject? = NSJSONSerialization.JSONObjectWithData(stringData!,
            options: NSJSONReadingOptions.MutableContainers, error: &err)
        
        if err != nil {
            // println(err)
            return nil
        }
        
        return parsed
    }
    
    static func parseForEmit(packet:SocketPacket) {
        shredder.deconstructPacket(packet)
    }
    
    // Parses messages recieved
    static func parseSocketMessage(stringMessage:String, socket:SocketIOClient) {
        if stringMessage == "" {
            return
        }
        
        func checkNSP(nsp:String) -> Bool {
            return nsp == "" && socket.nsp != "/"
        }
        
        SocketLogger.log("Parsing \(stringMessage)", client: socket, altType: "SocketParser")
        
        let p:SocketPacket
        
        if let pack = parseString(stringMessage) {
            p = pack
        } else {
            socket.didError("Error parsing packet")
            return
        }
        
        // Don't call SocketPacket.description unless we need to
        if socket.log {
            SocketLogger.log("Decoded packet as: \(p)", client: socket, altType: "SocketParser")
        }
        
        if p.type == SocketPacket.PacketType.EVENT {
            if checkNSP(p.nsp) {
                return
            }
            
            socket.handleEvent(p.getEvent(), data: p.data,
                isInternalMessage: false, wantsAck: p.id)
        } else if p.type == SocketPacket.PacketType.ACK {
            if checkNSP(p.nsp) {
                return
            }
            
            socket.handleAck(p.id!, data: p.data)
        } else if p.type == SocketPacket.PacketType.BINARY_EVENT {
            if checkNSP(p.nsp) {
                return
            }
            
            socket.waitingData.append(p)
        } else if p.type == SocketPacket.PacketType.BINARY_ACK {
            if checkNSP(p.nsp) {
                return
            }
            
            p.justAck = true
            socket.waitingData.append(p)
        } else if p.type == SocketPacket.PacketType.CONNECT {
            if p.nsp == "" && socket.nsp != "/" {
                socket.joinNamespace()
            } else if p.nsp != "" && socket.nsp == "/" {
                socket.didConnect()
            } else {
                socket.didConnect()
            }
        } else if p.type == SocketPacket.PacketType.DISCONNECT {
            socket.didDisconnect("Got Disconnect")
        } else if p.type == SocketPacket.PacketType.ERROR {
            socket.didError(p.data == nil ? "Error" : p.data!)
        }
    }
    
    static func parseBinaryData(data:NSData, socket:SocketIOClient) {
        if socket.waitingData.count == 0 {
            SocketLogger.err("Got data when not remaking packet", client: socket, altType: "SocketParser")
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
                wantsAck: packet.id)
        } else {
            socket.handleAck(packet.id!, data: packet.data)
        }
    }
}
