//
//  SocketParsable.swift
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

protocol SocketParsable: SocketClientSpec {
    func parseBinaryData(data: NSData)
    func parseSocketMessage(message: String)
}

extension SocketParsable {
    private func isCorrectNamespace(nsp: String) -> Bool {
        return nsp == self.nsp
    }
    
    private func handleConnect(p: SocketPacket) {
        if p.nsp == "/" && nsp != "/" {
            joinNamespace(nsp)
        } else if p.nsp != "/" && nsp == "/" {
            didConnect()
        } else {
            didConnect()
        }
    }
    
    private func handlePacket(pack: SocketPacket) {
        switch pack.type {
        case .Event where isCorrectNamespace(pack.nsp):
            handleEvent(pack.event, data: pack.args,
                isInternalMessage: false, withAck: pack.id)
        case .Ack where isCorrectNamespace(pack.nsp):
            handleAck(pack.id, data: pack.data)
        case .BinaryEvent where isCorrectNamespace(pack.nsp):
            waitingData.append(pack)
        case .BinaryAck where isCorrectNamespace(pack.nsp):
            waitingData.append(pack)
        case .Connect:
            handleConnect(pack)
        case .Disconnect:
            didDisconnect("Got Disconnect")
        case .Error:
            handleEvent("error", data: pack.data, isInternalMessage: true, withAck: pack.id)
        default:
            DefaultSocketLogger.Logger.log("Got invalid packet: %@", type: "SocketParser", args: pack.description)
        }
    }
    
    /// Parses a messsage from the engine. Returning either a string error or a complete SocketPacket
    func parseString(message: String) -> Either<String, SocketPacket> {
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
        let noPlaceholders = d["(\\{\"_placeholder\":true,\"num\":(\\d*)\\})"] <~ "\"~~$2\""
        
        switch parseData(noPlaceholders) {
        case let .Left(err):
            // If first you don't succeed, try again
            if case let .Right(data) = parseData("\([noPlaceholders as AnyObject])") {
                return .Right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                    nsp: namespace ?? "/", placeholders: placeholders))
            } else {
                return .Left(err)
            }
        case let .Right(data):
            return .Right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                nsp: namespace ?? "/", placeholders: placeholders))
        }
    }
    
    // Parses data for events
    private func parseData(data: String) -> Either<String, [AnyObject]> {
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
    func parseSocketMessage(message: String) {
        guard !message.isEmpty else { return }
        
        DefaultSocketLogger.Logger.log("Parsing %@", type: "SocketParser", args: message)
        
        switch parseString(message) {
        case let .Left(err):
            DefaultSocketLogger.Logger.error("\(err): %@", type: "SocketParser", args: message)
        case let .Right(pack):
            DefaultSocketLogger.Logger.log("Decoded packet as: %@", type: "SocketParser", args: pack.description)
            handlePacket(pack)
        }
    }
    
    func parseBinaryData(data: NSData) {
        guard !waitingData.isEmpty else {
            DefaultSocketLogger.Logger.error("Got data when not remaking packet", type: "SocketParser")
            return
        }
        
        // Should execute event?
        guard waitingData[waitingData.count - 1].addData(data) else {
            return
        }
        
        let packet = waitingData.removeLast()
        
        if packet.type != .BinaryAck {
            handleEvent(packet.event, data: packet.args ?? [],
                isInternalMessage: false, withAck: packet.id)
        } else {
            handleAck(packet.id, data: packet.args)
        }
    }
}
