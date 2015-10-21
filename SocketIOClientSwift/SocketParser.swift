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

    private static func handleConnect(p: SocketPacket, socket: SocketIOClient) {
        if p.nsp == "/" && socket.nsp != "/" {
            socket.joinNamespace()
        } else if p.nsp != "/" && socket.nsp == "/" {
            socket.didConnect()
        } else {
            socket.didConnect()
        }
    }
    
    private static func handlePacket(pack: SocketPacket, withSocket socket: SocketIOClient) {
        switch pack.type {
        case .Event where isCorrectNamespace(pack.nsp, socket):
            socket.handleEvent(pack.event, data: pack.args ?? [],
                isInternalMessage: false, wantsAck: pack.id)
        case .Ack where isCorrectNamespace(pack.nsp, socket):
            socket.handleAck(pack.id, data: pack.data)
        case .BinaryEvent where isCorrectNamespace(pack.nsp, socket):
            socket.waitingData.append(pack)
        case .BinaryAck where isCorrectNamespace(pack.nsp, socket):
            socket.waitingData.append(pack)
        case .Connect:
            handleConnect(pack, socket: socket)
        case .Disconnect:
            socket.didDisconnect("Got Disconnect")
        case .Error:
            socket.didError(pack.data)
        default:
            Logger.log("Got invalid packet: %@", type: "SocketParser", args: pack.description)
        }
    }
    
    static func parseString(message: String) -> Either<String, SocketPacket> {
        var parser = SocketStringReader(message: message)
        
        guard let type = SocketPacket.PacketType(rawValue: Int(parser.read(1)) ?? -1) else {
            return .Left("Invalid packet type")
        }
        
        if !parser.hasNext {
            return .Right(SocketPacket(type: type, nsp: "/"))
        }
        
        var namespace: String?
        var placeholders = -1
        
        if type == .BinaryEvent || type == .BinaryAck {
            if let holders = Int(parser.readUntilStringOccurence("-")) {
                placeholders = holders
            } else {
               return .Left("Invalid packet")
            }
        }
        
        if parser.currentCharacter == "/" {
            namespace = parser.readUntilStringOccurence(",") ?? parser.readUntilEnd()
        }
        
        if !parser.hasNext {
            return .Right(SocketPacket(type: type, id: -1,
                nsp: namespace ?? "/", placeholders: placeholders))
        }
        
        var idString = ""
        
        if type == .Error {
            parser.advanceIndexBy(-1)
        }
        
        while parser.hasNext && type != .Error {
            if let int = Int(parser.read(1)) {
                idString += String(int)
            } else {
                parser.advanceIndexBy(-2)
                break
            }
        }
        
        let d = message[parser.currentIndex.advancedBy(1)..<message.endIndex]
        let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
        
        switch parseData(noPlaceholders) {
        case .Left(let err):
            // If first you don't succeed, try again
            if case let .Right(data) = parseData("\([noPlaceholders as AnyObject])") {
                return .Right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                    nsp: namespace ?? "/", placeholders: placeholders))
            } else {
                return .Left(err)
            }
        case .Right(let data):
            return .Right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                nsp: namespace ?? "/", placeholders: placeholders))
        }
    }
    
    // Parses data for events
    private static func parseData(data: String) -> Either<String, [AnyObject]> {
        let stringData = data.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
        do {
            if let arr = try NSJSONSerialization.JSONObjectWithData(stringData!,
                options: NSJSONReadingOptions.MutableContainers) as? [AnyObject] {
                    return .Right(arr)
            } else {
                return .Left("Expected data array")
            }
        } catch {
            return .Left("Error parsing data for packet")
        }
    }
    
    // Parses messages recieved
    static func parseSocketMessage(message: String, socket: SocketIOClient) {
        guard !message.isEmpty else { return }
        
        Logger.log("Parsing %@", type: "SocketParser", args: message)
        
        switch parseString(message) {
        case .Left(let err):
            Logger.error("\(err): %@", type: "SocketParser", args: message)
        case .Right(let pack):
            Logger.log("Decoded packet as: %@", type: "SocketParser", args: pack.description)
            handlePacket(pack, withSocket: socket)
        }
    }
    
    static func parseBinaryData(data: NSData, socket: SocketIOClient) {
        guard !socket.waitingData.isEmpty else {
            Logger.error("Got data when not remaking packet", type: "SocketParser")
            return
        }
        
        // Should execute event?
        guard socket.waitingData[socket.waitingData.count - 1].addData(data) else {
            return
        }
        
        var packet = socket.waitingData.removeLast()
        packet.fillInPlaceholders()
        
        if packet.type != .BinaryAck {
            socket.handleEvent(packet.event, data: packet.args ?? [],
                isInternalMessage: false, wantsAck: packet.id)
        } else {
            socket.handleAck(packet.id, data: packet.args)
        }
    }
}
