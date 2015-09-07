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

struct GenericParser {
    let message: String
    var currentIndex:Int
    var messageCharacters: Array<Character> {
        get {
            return Array(message.characters)
        }
    }
    var currentCharacter: String? {
        get{
            if currentIndex >= messageCharacters.count {
                return nil
            }
            return String(messageCharacters[currentIndex])
        }
    }
    
    mutating func read(characterLength:Int) -> String? {
        let startIndex = message.startIndex.advancedBy(currentIndex)
        let range = Range<String.Index>(start: startIndex, end: startIndex.advancedBy(characterLength))
        currentIndex = currentIndex + characterLength
        
        return message.substringWithRange(range)
    }
    
    mutating func readUntilStringOccurence(string:String) -> String? {
        let startIndex = message.startIndex.advancedBy(currentIndex)
        let range = Range<String.Index>(start: startIndex, end: message.endIndex)
        let subString = message.substringWithRange(range) as NSString
        let foundRange = subString.rangeOfString(string)
        if foundRange.location == Int.max {
            return nil
        }
        currentIndex = foundRange.location + 1
        
        return subString.substringToIndex(foundRange.location)
    }
}

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
        
        socket.handleEvent(p.event, data: p.args,
            isInternalMessage: false, wantsAck: p.id)
    }
    
    // Translation of socket.io-client#decodeString
    static func parseString(str: String) -> SocketPacket? {
        var parser = GenericParser(message: str, currentIndex: 0)
        let messageCharacters = Array(str.characters)
        guard let typeString = parser.read(1), let type = SocketPacket.PacketType(str: typeString) else {
            NSLog("Error parsing \(str)")
            return nil}
        
        if messageCharacters.count == 1 {
            return SocketPacket(type: type, nsp: "/")
        }
        
        var id: Int?
        var nsp:String?
        var i = 0
        var placeholders = -1
        
        if type == .BinaryEvent || type == .BinaryAck {
            if let buffer = parser.readUntilStringOccurence("-"), let holders = Int(buffer) where parser.read(1) == "-" {
                placeholders = holders
            } else {
                NSLog("Error parsing \(str)")
                return nil
            }

            i = parser.currentIndex - 1
        }
        
        if messageCharacters[i + 1] == "/" {
            nsp = ""
            
            while ++i < messageCharacters.count {
                let c = messageCharacters[i]
                
                if c == "," {
                    break
                }
                
                nsp! += String(c)
            }
        }
        
        if i + 1 >= messageCharacters.count {
            return SocketPacket(type: type, id: id ?? -1,
                nsp: nsp ?? "/", placeholders: placeholders)
        }
        
        let next = String(messageCharacters[i + 1])
        
        if Int(next) != nil {
            var c = ""
            while ++i < messageCharacters.count {
                if let int = Int(String(messageCharacters[i])) {
                    c += String(int)
                } else {
                    --i
                    break
                }
            }
            
            id = Int(c)
        }
        
        if ++i < messageCharacters.count {
            let d = str[str.startIndex.advancedBy(i)...str.startIndex.advancedBy(str.characters.count-1)]
            let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
            let data = SocketParser.parseData(noPlaceholders) as? [AnyObject] ?? [noPlaceholders]
            
            return SocketPacket(type: type, data: data, id: id ?? -1,
                nsp: nsp ?? "/", placeholders: placeholders)
        }
        
        return nil
    }
    
    // Parses data for events
    static func parseData(data: String) -> AnyObject? {
        let stringData = data.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
        do {
            return try NSJSONSerialization.JSONObjectWithData(stringData!,
                        options: NSJSONReadingOptions.MutableContainers)
        } catch let error as NSError {
            //TODO Log error
            return nil
        }
    }
    
    // Parses messages recieved
    static func parseSocketMessage(stringMessage: String, socket: SocketIOClient) {
        guard !stringMessage.isEmpty else { return }
        
        Logger.log("Parsing %@", type: "SocketParser", args: stringMessage)
        
        guard let pack = parseString(stringMessage) else {
            socket.didError("Error parsing packet")
            return
        }
        
        Logger.log("Decoded packet as: %@", type: "SocketParser", args: pack.description)
        
        switch pack.type {
        case .Event:
            handleEvent(pack, socket: socket)
        case .Ack:
            handleAck(pack, socket: socket)
        case .BinaryEvent:
            handleBinaryEvent(pack, socket: socket)
        case .BinaryAck:
            handleBinaryAck(pack, socket: socket)
        case .Connect:
            handleConnect(pack, socket: socket)
        case .Disconnect:
            socket.didDisconnect("Got Disconnect")
        case .Error:
            socket.didError("Error: \(pack.data)")
        }
    }
    
    static func parseBinaryData(data: NSData, socket: SocketIOClient) {
        if socket.waitingData.count == 0 {
            Logger.error("Got data when not remaking packet", type: "SocketParser")
            return
        }
        
        let shouldExecute = socket.waitingData[0].addData(data)
        
        if !shouldExecute {
            return
        }
        
        var packet = socket.waitingData.removeAtIndex(0)
        packet.fillInPlaceholders()
        
        if packet.type != SocketPacket.PacketType.BinaryAck {
            socket.handleEvent(packet.event, data: packet.args,
                isInternalMessage: false, wantsAck: packet.id)
        } else {
            socket.handleAck(packet.id, data: packet.args)
        }
    }
}
