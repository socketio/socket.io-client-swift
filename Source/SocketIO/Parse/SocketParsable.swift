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

/// Bounds retained protocol data independently of individual WebSocket messages.
/// Configure before connecting; the same policy applies to polling and WebSocket.
///
/// The defaults decode everything the JavaScript decoder decodes. `maximumAttachments`
/// is the only limit JS itself has (`Decoder`'s `maxAttachments`, default 10); the
/// byte limits are opt-in hardening and default to unlimited. `maximumNestingDepth`
/// is a deliberate deviation: `JSONSerialization` can overflow the stack on deeply
/// nested input, so the pre-check stays with a default no real payload reaches.
public struct SocketParserOptions {
    /// Maximum binary attachments declared by one packet. Matches the JS decoder default.
    public var maximumAttachments: Int
    /// Maximum combined bytes retained while reconstructing a binary packet.
    /// `Int.max` (the default) imposes no limit, like JS.
    public var maximumBinaryPacketBytes: Int
    /// Maximum UTF-8 bytes in a Socket.IO text packet, including its JSON payload.
    /// `Int.max` (the default) imposes no limit, like JS.
    public var maximumTextPacketBytes: Int
    /// Maximum JSON array/object nesting before Foundation is asked to decode it.
    /// Crash guard only; JS has no such limit.
    public var maximumNestingDepth: Int

    public init(maximumAttachments: Int = 10,
                maximumBinaryPacketBytes: Int = .max,
                maximumTextPacketBytes: Int = .max,
                maximumNestingDepth: Int = 512) {
        self.maximumAttachments = maximumAttachments
        self.maximumBinaryPacketBytes = maximumBinaryPacketBytes
        self.maximumTextPacketBytes = maximumTextPacketBytes
        self.maximumNestingDepth = maximumNestingDepth
    }

    internal var isValid: Bool {
        maximumAttachments > 0 && maximumBinaryPacketBytes > 0 &&
        maximumTextPacketBytes > 0 && (1...1024).contains(maximumNestingDepth)
    }
}

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
        let limits = parserOptions
        guard limits.isValid, !message.isEmpty,
              message.utf8.count <= limits.maximumTextPacketBytes else {
            throw SocketParsableError.invalidPacket
        }
        // The wire grammar is ASCII; the namespace and JSON remain UTF-8. A
        // forward-only byte cursor never creates an invalid UTF-16/string index.
        let bytes = Array(message.utf8)
        guard bytes[0] >= 48, bytes[0] <= 54,
              let type = SocketPacket.PacketType(rawValue: Int(bytes[0] - 48)) else {
            throw SocketParsableError.invalidPacketType
        }
        var cursor = 1
        /// Consumes a run of ASCII digits and advances past it. `nil` means there
        /// was no run, or one too long for `Int`; both callers treat those alike.
        func readDigits() -> Int? {
            let start = cursor
            while cursor < bytes.count && bytes[cursor] >= 48 && bytes[cursor] <= 57 { cursor += 1 }
            guard cursor > start else { return nil }
            return Int(String(decoding: bytes[start..<cursor], as: UTF8.self))
        }
        var placeholders = 0
        if type.isBinary {
            // An attachment count that overflows `Int` is "too many attachments"
            // in JS as well, so it stays a parse error.
            guard let count = readDigits(), count > 0, count <= limits.maximumAttachments,
                  cursor < bytes.count, bytes[cursor] == 45 else {
                throw SocketParsableError.invalidPacket
            }
            placeholders = count
            cursor += 1
        }
        var namespace = "/"
        if cursor < bytes.count && bytes[cursor] == 47 {
            let start = cursor
            while cursor < bytes.count && bytes[cursor] != 44 { cursor += 1 }
            namespace = String(decoding: bytes[start..<cursor], as: UTF8.self)
            if cursor < bytes.count { cursor += 1 }
        }
        // JS reads the id with `Number(...)`, which never fails: an id too large
        // for `Int` becomes a float no registered handler can match. The packet
        // stays valid — the ACK is dropped ("bad ack") and the EVENT is delivered
        // without an acknowledgement — so overflow yields the no-ack sentinel.
        let id = readDigits() ?? -1
        guard cursor < bytes.count else {
            // JS `decodeString` only parses a payload `if (str.charAt(++i))`, so
            // "2", "2/nsp,", "2123", "3" and "399" decode with `data === undefined`:
            // `onevent` uses `packet.data || []` and emits nothing (only onAny
            // listeners see the empty event), `onack` logs "bad ack". Binary
            // headers still require a payload — their placeholders cannot exist
            // without one.
            guard type == .connect || type == .disconnect || type == .event || type == .ack else {
                throw SocketParsableError.invalidDataArray
            }
            return SocketPacket(type: type, id: id, nsp: namespace)
        }
        let payload = bytes[cursor...]
        guard jsonNestingIsBounded(payload, maximum: limits.maximumNestingDepth) else {
            throw SocketParsableError.invalidDataArray
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(payload), options: .fragmentsAllowed) }
        catch { throw SocketParsableError.invalidDataArray }
        let data: [Any]
        switch type {
        case .connect:
            guard let dictionary = object as? JSON else { throw SocketParsableError.invalidDataArray }
            data = [dictionary]
        case .disconnect:
            throw SocketParsableError.invalidDataArray
        case .error:
            guard object is String || object is JSON else {
                throw SocketParsableError.invalidDataArray
            }
            data = (object as? [Any]) ?? [object]
        case .event, .binaryEvent:
            guard let array = object as? [Any], let event = array.first else {
                throw SocketParsableError.invalidDataArray
            }
            if let name = event as? String {
                guard !SocketReservedEvent.names.contains(name) else { throw SocketParsableError.invalidDataArray }
            } else if !SocketPacket.isJSONNumber(event) {
                throw SocketParsableError.invalidDataArray
            }
            data = array
        case .ack, .binaryAck:
            guard let array = object as? [Any] else { throw SocketParsableError.invalidDataArray }
            data = array
        }
        if type.isBinary && !SocketPacket.validPlaceholders(in: data, count: placeholders) {
            throw SocketParsableError.invalidPacket
        }
        return SocketPacket(type: type, data: data, id: id, nsp: namespace, placeholders: placeholders)
    }

    /// Reject excessive nesting before JSONSerialization can allocate a deeply
    /// recursive object graph. Quoted brackets and escaped quotes do not count.
    private func jsonNestingIsBounded(_ bytes: ArraySlice<UInt8>, maximum: Int) -> Bool {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in bytes {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 91 || byte == 123 {
                depth += 1
                if depth > maximum { return false }
            } else if byte == 93 || byte == 125 {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0 && !quoted
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

        // One binary header owns the stream until all of its attachments arrive.
        guard waitingPackets.count == 1, parserOptions.isValid,
              data.count <= parserOptions.maximumBinaryPacketBytes,
              waitingPackets[0].receivedBinaryBytes <= parserOptions.maximumBinaryPacketBytes - data.count else {
            waitingPackets.removeAll()
            return nil
        }
        let complete = waitingPackets[0].addData(data)
        if waitingPackets[0].reconstructionFailed {
            waitingPackets.removeAll()
            return nil
        }
        return complete ? waitingPackets.removeFirst() : nil
    }
}
