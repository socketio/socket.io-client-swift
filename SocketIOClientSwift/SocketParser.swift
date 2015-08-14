//
//  SocketParser.swift
//  Socket.IO-Client-Swift
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
    private static func isCorrectNamespace(nsp: String, _ socket: SocketIOClient) -> Bool {
        return nsp == socket.nsp
    }
    
    private static func handleAck(p: SocketPacket, socket: SocketIOClient) {
        if !isCorrectNamespace(p.nsp, socket) {
            return
        }
        
        socket.handleAck(p.id, data: p.data)
    }
    
    private static func handleBinaryAck(p: SocketPacket, socket: SocketIOClient) {
        if !isCorrectNamespace(p.nsp, socket) {
            return
        }
        
        socket.waitingData.append(p)
    }
    
    private static func handleBinaryEvent(p: SocketPacket, socket: SocketIOClient) {
        if !isCorrectNamespace(p.nsp, socket) {
            return
        }
        
        socket.waitingData.append(p)
    }
    
    private static func handleConnect(p: SocketPacket, socket: SocketIOClient) {
        if p.nsp == "/" && socket.nsp != "/" {
            socket.joinNamespace()
        } else if p.nsp != "/" && socket.nsp == "/" {
            socket.didConnect()
        } else {
            socket.didConnect()
        }
    }
    
    private static func handleEvent(p: SocketPacket, socket: SocketIOClient) {
        if !isCorrectNamespace(p.nsp, socket) {
            return
        }
        
        socket.handleEvent(p.getEvent(), data: p.getArgs(),
            isInternalMessage: false, wantsAck: p.id)
    }
    
    // Translation of socket.io-client#decodeString
    static func parseString(str: String) -> SocketPacket? {
        let arr = Array(str.characters)
        let type = String(arr[0])
        
        if arr.count == 1 {
            return SocketPacket(type: SocketPacket.PacketType(str: type)!, nsp: "/")
        }
        
        var id: Int?
        var nsp:String?
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
            
            if let holders = Int(buf) where arr[i] == "-" {
                placeholders = holders
            } else {
                NSLog("Error parsing \(str)")
                return nil
            }
        }
        
        if arr[i + 1] == "/" {
            nsp = ""
            
            while ++i < arr.count {
                let c = arr[i]
                
                if c == "," {
                    break
                }
                
                nsp! += String(c)
            }
        }
        
        if i + 1 >= arr.count {
            return SocketPacket(type: SocketPacket.PacketType(str: type)!, id: id ?? -1,
                nsp: nsp ?? "/", placeholders: placeholders)
        }
        
        let next = String(arr[i + 1])
        
        if Int(next) != nil {
            var c = ""
            while ++i < arr.count {
                if let int = Int(String(arr[i])) {
                    c += String(int)
                } else {
                    --i
                    break
                }
            }
            
            id = Int(c)
        }
        
        if ++i < arr.count {
            let d = str[advance(str.startIndex, i)...advance(str.startIndex, str.characters.count-1)]
            let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
            let data = SocketParser.parseData(noPlaceholders) as? [AnyObject] ?? [noPlaceholders]
            
            return SocketPacket(type: SocketPacket.PacketType(str: type)!, data: data, id: id ?? -1,
                nsp: nsp ?? "/", placeholders: placeholders)
        }
        
        return nil
    }
    
    // Parses data for events
    static func parseData(data: String) -> AnyObject? {
        var err: NSError?
        let stringData = data.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
        let parsed: AnyObject?
        
        do {
            parsed = try NSJSONSerialization.JSONObjectWithData(stringData!,
                        options: NSJSONReadingOptions.MutableContainers)
        } catch let error as NSError {
            err = error
            parsed = nil
        }
        
        if err != nil {
            // println(err)
            return nil
        }
        
        return parsed
    }
    
    // Parses messages recieved
    static func parseSocketMessage(stringMessage: String, socket: SocketIOClient) {
        if stringMessage == "" {
            return
        }
        
        SocketLogger.log("Parsing %@", client: socket, altType: "SocketParser", args: stringMessage)
        
        let p: SocketPacket
        
        if let pack = parseString(stringMessage) {
            p = pack
        } else {
            socket.didError("Error parsing packet")
            return
        }
        
        SocketLogger.log("Decoded packet as: %@", client: socket, altType: "SocketParser", args: p.description)
        
        switch p.type {
        case SocketPacket.PacketType.Event:
            handleEvent(p, socket: socket)
        case SocketPacket.PacketType.Ack:
            handleAck(p, socket: socket)
        case SocketPacket.PacketType.BinaryEvent:
            handleBinaryEvent(p, socket: socket)
        case SocketPacket.PacketType.BinaryAck:
            handleBinaryAck(p, socket: socket)
        case SocketPacket.PacketType.Connect:
            handleConnect(p, socket: socket)
        case SocketPacket.PacketType.Disconnect:
            socket.didDisconnect("Got Disconnect")
        case SocketPacket.PacketType.Error:
            socket.didError("Error: \(p.data)")
        }
    }
    
    static func parseBinaryData(data: NSData, socket: SocketIOClient) {
        if socket.waitingData.count == 0 {
            SocketLogger.err("Got data when not remaking packet", client: socket, altType: "SocketParser")
            return
        }
        
        let shouldExecute = socket.waitingData[0].addData(data)
        
        if !shouldExecute {
            return
        }
        
        var packet = socket.waitingData.removeAtIndex(0)
        packet.fillInPlaceholders()
        
        if packet.type != SocketPacket.PacketType.BinaryAck {
            socket.handleEvent(packet.getEvent(), data: packet.getArgs(),
                isInternalMessage: false, wantsAck: packet.id)
        } else {
            socket.handleAck(packet.id, data: packet.getArgs())
        }
    }
}
