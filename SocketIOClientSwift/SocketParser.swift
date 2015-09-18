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
    
    private static func handleEvent(p: SocketPacket, socket: SocketIOClient) {
        guard isCorrectNamespace(p.nsp, socket) else { return }
        
        socket.handleEvent(p.event, data: p.args,
            isInternalMessage: false, wantsAck: p.id)
    }
    
    private static func handleAck(p: SocketPacket, socket: SocketIOClient) {
        guard isCorrectNamespace(p.nsp, socket) else { return }
        
        socket.handleAck(p.id, data: p.data)
    }
    
    private static func handleBinary(p: SocketPacket, socket: SocketIOClient) {
        guard isCorrectNamespace(p.nsp, socket) else { return }
        
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
    
    static func parseString(message: String) -> SocketPacket? {
        var parser = SocketStringReader(message: message)
        
        guard let type = SocketPacket.PacketType(str: parser.read(1))
            else {return nil}
        
        if !parser.hasNext {
            return SocketPacket(type: type, nsp: "/")
        }
        
        var namespace: String?
        var placeholders = -1
        
        if type == .BinaryEvent || type == .BinaryAck {
            if let holders = Int(parser.readUntilStringOccurence("-")) {
                placeholders = holders
            } else {
               return nil
            }
        }
        
        if parser.currentCharacter == "/" {
            namespace = parser.readUntilStringOccurence(",") ?? parser.readUntilEnd()
        }
        
        if !parser.hasNext {
            return SocketPacket(type: type, id: -1,
                nsp: namespace ?? "/", placeholders: placeholders)
        }
        
        var idString = ""
        
        while parser.hasNext {
            if let int = Int(parser.read(1)) {
                idString += String(int)
            } else {
                parser.advanceIndexBy(-2)
                break
            }
        }
        
        let d = message[parser.currentIndex.advancedBy(1)..<message.endIndex]
        let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] ~= "\"~~$2\""
        let data = parseData(noPlaceholders) as? [AnyObject] ?? [noPlaceholders]
        
        return SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
            nsp: namespace ?? "/", placeholders: placeholders)
    }
    
    // Parses data for events
    static func parseData(data: String) -> AnyObject? {
        let stringData = data.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
        do {
            return try NSJSONSerialization.JSONObjectWithData(stringData!,
                        options: NSJSONReadingOptions.MutableContainers)
        } catch {
            Logger.error("Parsing JSON: %@", type: "SocketParser", args: data)
            return nil
        }
    }
    
    // Parses messages recieved
    static func parseSocketMessage(message: String, socket: SocketIOClient) {
        guard !message.isEmpty else { return }
        
        Logger.log("Parsing %@", type: "SocketParser", args: message)
        
        guard let pack = parseString(message) else {
            Logger.error("Parsing message: %@", type: "SocketParser", args: message)
            return
        }
        
        Logger.log("Decoded packet as: %@", type: "SocketParser", args: pack.description)
        
        switch pack.type {
        case .Event:
            handleEvent(pack, socket: socket)
        case .Ack:
            handleAck(pack, socket: socket)
        case .BinaryEvent:
            handleBinary(pack, socket: socket)
        case .BinaryAck:
            handleBinary(pack, socket: socket)
        case .Connect:
            handleConnect(pack, socket: socket)
        case .Disconnect:
            socket.didDisconnect("Got Disconnect")
        case .Error:
            socket.didError("Error: \(pack.data)")
        }

    }
    
    static func parseBinaryData(data: NSData, socket: SocketIOClient) {
        guard !socket.waitingData.isEmpty else {
            Logger.error("Got data when not remaking packet", type: "SocketParser")
            return
        }
        
        let shouldExecute = socket.waitingData[socket.waitingData.count - 1].addData(data)
        
        guard shouldExecute else {
            return
        }
        
        var packet = socket.waitingData.removeLast()
        packet.fillInPlaceholders()
        
        if packet.type != .BinaryAck {
            socket.handleEvent(packet.event, data: packet.args,
                isInternalMessage: false, wantsAck: packet.id)
        } else {
            socket.handleAck(packet.id, data: packet.args)
        }
    }
}
