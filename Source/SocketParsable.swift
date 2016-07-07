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

protocol SocketParsable : SocketIOClientSpec {
    func parseBinaryData(data: NSData)
    func parseSocketMessage(message: String)
}

extension SocketParsable {
    private func isCorrectNamespace(nsp: String) -> Bool {
        return nsp == self.nsp
    }
    
    private func handleConnect(p: SocketPacket) {
        if p.nsp == "/" && nsp != "/" {
            joinNamespace(namespace: nsp)
        } else {
            didConnect()
        }
    }
    
    private func handlePacket(pack: SocketPacket) {
        switch pack.type {
        case .Event where isCorrectNamespace(nsp: pack.nsp):
            handleEvent(event: pack.event, data: pack.args, isInternalMessage: false, withAck: pack.id)
        case .Ack where isCorrectNamespace(nsp: pack.nsp):
            handleAck(ack: pack.id, data: pack.data)
        case .BinaryEvent where isCorrectNamespace(nsp: pack.nsp):
            waitingPackets.append(pack)
        case .BinaryAck where isCorrectNamespace(nsp: pack.nsp):
            waitingPackets.append(pack)
        case .Connect:
            handleConnect(p: pack)
        case .Disconnect:
            didDisconnect(reason: "Got Disconnect")
        case .Error:
            handleEvent(event: "error", data: pack.data, isInternalMessage: true, withAck: pack.id)
        default:
            DefaultSocketLogger.Logger.log(message:  "Got invalid packet: %@", type: "SocketParser", args: pack.description)
        }
    }
    
    /// Parses a messsage from the engine. Returning either a string error or a complete SocketPacket
    func parseString(message: String) -> Either<String, SocketPacket> {
        var parser = SocketStringReader(message: message)
        
        guard let type = SocketPacket.PacketType(rawValue: Int(parser.read(readLength: 1)) ?? -1) else {
            return .Left("Invalid packet type")
        }
        
        if !parser.hasNext {
            return .Right(SocketPacket(type: type, nsp: "/"))
        }
        
        var namespace = "/"
        var placeholders = -1
        
        if type == .BinaryEvent || type == .BinaryAck {
            if let holders = Int(parser.readUntilStringOccurence(string: "-")) {
                placeholders = holders
            } else {
                return .Left("Invalid packet")
            }
        }
        
        if parser.currentCharacter == "/" {
            namespace = parser.readUntilStringOccurence(string: ",") ?? parser.readUntilEnd()
        }
        
        if !parser.hasNext {
            return .Right(SocketPacket(type: type, nsp: namespace, placeholders: placeholders))
        }
        
        var idString = ""
        
        if type == .Error {
            parser.advanceIndexBy(n: -1)
        } else {
            while parser.hasNext {
                if let int = Int(parser.read(readLength: 1)) {
                    idString += String(int)
                } else {
                    parser.advanceIndexBy(n: -2)
                    break
                }
            }
        }
        
        let d = message[message.index(parser.currentIndex, offsetBy: 1)..<message.endIndex]
        
        switch parseData(data: d) {
        case let .Left(err):
            // Errors aren't always enclosed in an array
            if case let .Right(data) = parseData(data: "\([d as AnyObject])") {
                return .Right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                    nsp: namespace, placeholders: placeholders))
            } else {
                return .Left(err)
            }
        case let .Right(data):
            return .Right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                nsp: namespace, placeholders: placeholders))
        }
    }
    
    // Parses data for events
    private func parseData(data: String) -> Either<String, [AnyObject]> {
        let stringData = data.data(using: String.Encoding.utf8, allowLossyConversion: false)
        
        do {
            if let arr = try JSONSerialization.jsonObject(with: stringData!, options: JSONSerialization.ReadingOptions.mutableContainers) as? [AnyObject]{
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
        
        DefaultSocketLogger.Logger.log(message:  "Parsing %@", type: "SocketParser", args: message)
        
        switch parseString(message: message) {
        case let .Left(err):
            DefaultSocketLogger.Logger.error(message: "\(err): %@", type: "SocketParser", args: message)
        case let .Right(pack):
            DefaultSocketLogger.Logger.log(message: "Decoded packet as: %@", type: "SocketParser", args: pack.description)
            handlePacket(pack: pack)
        }
    }
    
    func parseBinaryData(data: NSData) {
        guard !waitingPackets.isEmpty else {
            DefaultSocketLogger.Logger.error(message: "Got data when not remaking packet", type: "SocketParser")
            return
        }
        
        // Should execute event?
        guard waitingPackets[waitingPackets.count - 1].addData(data: data) else { return }
        
        let packet = waitingPackets.removeLast()
        
        if packet.type != .BinaryAck {
            handleEvent(event: packet.event, data: packet.args ?? [],
                isInternalMessage: false, withAck: packet.id)
        } else {
            handleAck(ack: packet.id, data: packet.args)
        }
    }
}
