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

enum SocketParserError: ErrorType {
    case InvalidMessageType, InvalidBinaryPalceholder
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
    static func parseString(str: String) throws -> SocketPacket {
        var parser = GenericParser(message: str, currentIndex: 0)
        let messageCharacters = Array(str.characters)
        guard let typeString = parser.read(1), let type = SocketPacket.PacketType(str: typeString) else {
            throw SocketParserError.InvalidMessageType
        }
        
        if messageCharacters.count == 1 {
            return SocketPacket(type: type, nsp: "/")
        }
        
        var nsp:String?
        var placeholders = -1
        
        if type == .BinaryEvent || type == .BinaryAck {
            if let buffer = parser.readUntilStringOccurence("-"), let holders = Int(buffer) where parser.read(1)! == "-" {
                placeholders = holders
            } else {
               throw SocketParserError.InvalidBinaryPalceholder
            }
        }
        if parser.currentCharacter == "/" {
            nsp = parser.readUntilStringOccurence(",")
            parser.currentIndex++
        }
        
        if parser.currentIndex >= parser.messageCharacters.count {
            return SocketPacket(type: type, id: -1,
                nsp: nsp ?? "/", placeholders: placeholders)
        }
        
        
        var idString = ""
        while parser.currentIndex < messageCharacters.count {
            if let next = parser.read(1), let int = Int(next) {
                idString += String(int)
            } else {
                parser.currentIndex -= 2
                break
            }
        }
        
        let d = str[str.startIndex.advancedBy(parser.currentIndex + 1)...str.startIndex.advancedBy(str.characters.count - 1)]
        let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
        let data = SocketParser.parseData(noPlaceholders) as? [AnyObject] ?? [noPlaceholders]
        
        return SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
            nsp: nsp ?? "/", placeholders: placeholders)
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
        
        do {
            let pack = try parseString(stringMessage)
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
            
        }catch SocketParserError.InvalidBinaryPalceholder {
            Logger.error("Parsed Invalid Binary Placeholder", type: "SocketParser")
        }
        catch SocketParserError.InvalidMessageType {
            Logger.error("Parsed Invalid Binary Placeholder", type: "SocketParser")
        }
        catch {
            
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
