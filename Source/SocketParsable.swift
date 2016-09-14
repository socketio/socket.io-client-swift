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
    func parseBinaryData(_ data: Data)
    func parseSocketMessage(_ message: String)
}

extension SocketParsable {
    private func isCorrectNamespace(_ nsp: String) -> Bool {
        return nsp == self.nsp
    }
    
    private func handleConnect(_ packetNamespace: String) {
        if packetNamespace == "/" && nsp != "/" {
            joinNamespace(nsp)
        } else {
            didConnect()
        }
    }
    
    private func handlePacket(_ pack: SocketPacket) {
        switch pack.type {
        case .event where isCorrectNamespace(pack.nsp):
            handleEvent(pack.event, data: pack.args, isInternalMessage: false, withAck: pack.id)
        case .ack where isCorrectNamespace(pack.nsp):
            handleAck(pack.id, data: pack.data)
        case .binaryEvent where isCorrectNamespace(pack.nsp):
            waitingPackets.append(pack)
        case .binaryAck where isCorrectNamespace(pack.nsp):
            waitingPackets.append(pack)
        case .connect:
            handleConnect(pack.nsp)
        case .disconnect:
            didDisconnect(reason: "Got Disconnect")
        case .error:
            handleEvent("error", data: pack.data, isInternalMessage: true, withAck: pack.id)
        default:
            DefaultSocketLogger.Logger.log("Got invalid packet: %@", type: "SocketParser", args: pack.description)
        }
    }
    
    /// Parses a messsage from the engine. Returning either a string error or a complete SocketPacket
    func parseString(_ message: String) -> Either<String, SocketPacket> {
        var reader = SocketStringReader(message: message)
        
		guard let type = Int(reader.read(count: 1)).flatMap({ SocketPacket.PacketType(rawValue: $0) }) else {
            return .left("Invalid packet type")
        }
        
        if !reader.hasNext {
            return .right(SocketPacket(type: type, nsp: "/"))
        }
        
        var namespace = "/"
        var placeholders = -1
        
        if type == .binaryEvent || type == .binaryAck {
            if let holders = Int(reader.readUntilOccurence(of: "-")) {
                placeholders = holders
            } else {
                return .left("Invalid packet")
            }
        }
        
        if reader.currentCharacter == "/" {
            namespace = reader.readUntilOccurence(of: ",") 
        }
        
        if !reader.hasNext {
            return .right(SocketPacket(type: type, nsp: namespace, placeholders: placeholders))
        }
        
        var idString = ""
        
        if type == .error {
            reader.advance(by: -1)
        } else {
            while reader.hasNext {
                if let int = Int(reader.read(count: 1)) {
                    idString += String(int)
                } else {
                    reader.advance(by: -2)
                    break
                }
            }
        }
        
        
        
        var dataArray = message[message.characters.index(reader.currentIndex, offsetBy: 1)..<message.endIndex]
        
        if type == .error && !dataArray.hasPrefix("[") && !dataArray.hasSuffix("]") {
            dataArray = "[" + dataArray + "]"
        }
        
        switch parseData(dataArray) {
        case let .left(err):
            return .left(err)
        case let .right(data):
            return .right(SocketPacket(type: type, data: data, id: Int(idString) ?? -1,
                nsp: namespace, placeholders: placeholders))
        }
    }
    
    // Parses data for events
    private func parseData(_ data: String) -> Either<String, [Any]> {
        do {
            return .right(try data.toArray())
        } catch {
            return .left("Error parsing data for packet")
        }
    }
    
    // Parses messages recieved
    func parseSocketMessage(_ message: String) {
        guard !message.isEmpty else { return }
        
        DefaultSocketLogger.Logger.log("Parsing %@", type: "SocketParser", args: message)
        
        switch parseString(message) {
        case let .left(err):
            DefaultSocketLogger.Logger.error("\(err): %@", type: "SocketParser", args: message)
        case let .right(pack):
            DefaultSocketLogger.Logger.log("Decoded packet as: %@", type: "SocketParser", args: pack.description)
            handlePacket(pack)
        }
    }
    
    func parseBinaryData(_ data: Data) {
        guard !waitingPackets.isEmpty else {
            DefaultSocketLogger.Logger.error("Got data when not remaking packet", type: "SocketParser")
            return
        }
        
        // Should execute event?
        guard waitingPackets[waitingPackets.count - 1].addData(data) else { return }
        
        let packet = waitingPackets.removeLast()
        
        if packet.type != .binaryAck {
            handleEvent(packet.event, data: packet.args, isInternalMessage: false, withAck: packet.id)
        } else {
            handleAck(packet.id, data: packet.args)
        }
    }
}
