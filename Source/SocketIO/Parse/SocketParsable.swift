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

/// Defines that a type will be able to parse socket.io-protocol messages.
public protocol SocketParsable : AnyObject {
    // MARK: Methods

    /// Called when the engine has received some binary data that should be attached to a packet.
    ///
    /// Packets binary data should be sent directly after the packet that expects it, so there's confusion over
    /// where the data should go. Data should be received in the order it is sent, so that the correct data is put
    /// into the correct placeholder.
    ///
    /// - parameter data: The data that should be attached to a packet.
    func parseBinaryData(_ data: Data) -> SocketPacket?

    /// Called when the engine has received a string that should be parsed into a socket.io packet.
    ///
    /// - parameter message: The string that needs parsing.
    /// - returns: A completed socket packet if there is no more data left to collect.
    func parseSocketMessage(_ message: String) -> SocketPacket?
}

/// Errors that can be thrown during parsing.
public enum SocketParsableError : Error {
    // MARK: Cases

    /// Thrown when a packet received has an invalid data array, or is missing the data array.
    case invalidDataArray

    /// Thrown when an malformed packet is received.
    case invalidPacket

    /// Thrown when the parser receives an unknown packet type.
    case invalidPacketType
}

/// Says that a type will be able to buffer binary data before all data for an event has come in.
public protocol SocketDataBufferable : AnyObject {
    // MARK: Properties

    /// A list of packets that are waiting for binary data.
    ///
    /// The way that socket.io works all data should be sent directly after each packet.
    /// So this should ideally be an array of one packet waiting for data.
    ///
    /// **This should not be modified directly.**
    var waitingPackets: [SocketPacket] { get set }
}

public extension SocketParsable where Self: SocketManagerSpec & SocketDataBufferable {
    /// Parses a message from the engine, returning a complete SocketPacket or throwing.
    ///
    /// - parameter message: The message to parse.
    /// - returns: A completed packet, or throwing.
    internal func parseString(_ message: String) throws -> SocketPacket {
        var reader = SocketStringReader(message: message)

        guard let type = Int(reader.read(count: 1)).flatMap({ SocketPacket.PacketType(rawValue: $0) }) else {
            throw SocketParsableError.invalidPacketType
        }

        if !reader.hasNext {
            return SocketPacket(type: type, nsp: "/")
        }

        var namespace = "/"
        var placeholders = -1

        if type.isBinary {
            if let holders = Int(reader.readUntilOccurence(of: "-")) {
                placeholders = holders
            } else {
                throw SocketParsableError.invalidPacket
            }
        }

        if reader.currentCharacter == "/" {
            namespace = reader.readUntilOccurence(of: ",")
        }

        if !reader.hasNext {
            return SocketPacket(type: type, nsp: namespace, placeholders: placeholders)
        }

        var idString = ""

        if type == .error {
            reader.advance(by: -1)
        } else {
            while let int = Int(reader.read(count: 1)) {
                idString += String(int)
            }

            reader.advance(by: -2)
        }

        var dataArray = String(message.utf16[message.utf16.index(reader.currentIndex, offsetBy: 1)...])!

        if type == .error && !dataArray.hasPrefix("[") && !dataArray.hasSuffix("]") {
            dataArray = "[" + dataArray + "]"
        }

        let data = try parseData(dataArray)

        return SocketPacket(type: type, data: data, id: Int(idString) ?? -1, nsp: namespace, placeholders: placeholders)
    }

    // Parses data for events
    private func parseData(_ data: String) throws -> [Any] {
        do {
            return try data.toArray()
        } catch {
            throw SocketParsableError.invalidDataArray
        }
    }

    /// Called when the engine has received a string that should be parsed into a socket.io packet.
    ///
    /// - parameter message: The string that needs parsing.
    /// - returns: A completed socket packet or nil if the packet is invalid.
    func parseSocketMessage(_ message: String) -> SocketPacket? {
        guard !message.isEmpty else { return nil }

        DefaultSocketLogger.Logger.log("Parsing \(message)", type: "SocketParser")

        do {
            let packet = try parseString(message)

            DefaultSocketLogger.Logger.log("Decoded packet as: \(packet.description)", type: "SocketParser")

            return packet
        } catch {
            DefaultSocketLogger.Logger.error("\(error): \(message)", type: "SocketParser")

            return nil
        }
    }

    /// Called when the engine has received some binary data that should be attached to a packet.
    ///
    /// Packets binary data should be sent directly after the packet that expects it, so there's confusion over
    /// where the data should go. Data should be received in the order it is sent, so that the correct data is put
    /// into the correct placeholder.
    ///
    /// - parameter data: The data that should be attached to a packet.
    /// - returns: A completed socket packet if there is no more data left to collect.
    func parseBinaryData(_ data: Data) -> SocketPacket? {
        guard !waitingPackets.isEmpty else {
            DefaultSocketLogger.Logger.error("Got data when not remaking packet", type: "SocketParser")

            return nil
        }

        // Should execute event?
        guard waitingPackets[waitingPackets.count - 1].addData(data) else { return nil }

        return waitingPackets.removeLast()
    }
}
