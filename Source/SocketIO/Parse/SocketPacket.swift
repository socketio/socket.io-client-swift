//
//  SocketPacket.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/18/15.
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
//

import Foundation
import CoreFoundation

/// A struct that represents a socket.io packet.
public struct SocketPacket : CustomStringConvertible {
    // MARK: Properties

    private static let logType = "SocketPacket"

    /// The namespace for this packet.
    public let nsp: String

    /// If > 0 then this packet is using acking.
    public let id: Int

    /// The type of this packet.
    public let type: PacketType

    /// An array of binary data for this packet.
    public internal(set) var binary: [Data]

    /// The data for this event.
    ///
    /// Note: This includes all data inside of the socket.io packet payload array, which includes the event name for
    /// event type packets.
    public internal(set) var data: [Any]

    /// Returns the payload for this packet, minus the event name if this is an event or binaryEvent type packet.
    public var args: [Any] {
        if type == .event || type == .binaryEvent && data.count != 0 {
            return Array(data.dropFirst())
        } else {
            return data
        }
    }

    private let placeholders: Int
    internal private(set) var receivedBinaryBytes = 0
    internal private(set) var reconstructionFailed = false

    /// A string representation of this packet.
    public var description: String {
        return "SocketPacket {type: \(String(type.rawValue)); data: " +
            "\(String(describing: data)); id: \(id); placeholders: \(placeholders); nsp: \(nsp)}"
    }

    /// The event name for this packet.
    public var event: String {
        return data.first.map { String(describing: $0) } ?? ""
    }

    /// A string representation of this packet.
    ///
    /// **17.0.0**: prefer `encodedPacketString()`. Every emit path in this
    /// client validates its payload and throws before a packet is created, so
    /// the empty-payload fallback below can no longer put a different packet on
    /// the wire; it remains only for code that builds a `SocketPacket` by hand.
    public var packetString: String {
        do {
            return try encodedPacketString()
        } catch {
            DefaultSocketLogger.Logger.error(
                "Error creating JSON object in SocketPacket.packetString: \(error). " +
                "Use encodedPacketString() to handle this instead of encoding an empty payload.",
                type: SocketPacket.logType
            )

            return createHeaderString() + (type.carriesArgumentArray ? "[]" : "")
        }
    }

    /// The wire string for this packet, or a `SocketPacketError` describing why
    /// the payload cannot be represented as JSON.
    ///
    /// JS-aligned with `Encoder.encodeAsString` in `socket.io-parser/lib/index.ts`:
    /// `JSON.stringify` either produces the value or throws — it never silently
    /// substitutes a different payload.
    public func encodedPacketString() throws -> String {
        return try createHeaderString() + (payloadJSON() ?? "")
    }

    init(type: PacketType, data: [Any] = [Any](), id: Int = -1, nsp: String, placeholders: Int = 0,
         binary: [Data] = [Data]()) {
        self.data = data
        self.id = id
        self.nsp = nsp
        self.type = type
        self.placeholders = placeholders
        self.binary = binary
    }

    /// Adds one complete attachment without trusting unvalidated placeholder indices.
    mutating func addData(_ data: Data) -> Bool {
        guard !reconstructionFailed, placeholders > 0, binary.count < placeholders,
              Self.validPlaceholders(in: self.data, count: placeholders) else {
            reconstructionFailed = true
            binary.removeAll()
            return false
        }
        let total = receivedBinaryBytes.addingReportingOverflow(data.count)
        guard !total.overflow else { reconstructionFailed = true; binary.removeAll(); return false }
        receivedBinaryBytes = total.partialValue
        binary.append(data)
        guard binary.count == placeholders else { return false }
        fillInPlaceholders()
        return true
    }

    /// JSON booleans bridge to NSNumber too, but are not numeric event names or indices.
    static func isJSONNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private static func placeholderIndex(_ value: Any?, count: Int) -> Int? {
        guard let value = value, isJSONNumber(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < Double(count),
              let index = Int(exactly: double), index < count else { return nil }
        return index
    }

    /// Iterative validation prevents a malformed binary header from retaining data
    /// until its last attachment, or crashing while recursively replacing a marker.
    static func validPlaceholders(in data: [Any], count: Int) -> Bool {
        var pending = data
        while let object = pending.popLast() {
            if let dictionary = object as? JSON {
                if let marker = dictionary["_placeholder"] as? NSNumber,
                   CFGetTypeID(marker) == CFBooleanGetTypeID(), marker.boolValue {
                    guard placeholderIndex(dictionary["num"], count: count) != nil else { return false }
                } else {
                    // Only the actual JSON Boolean true is a binary marker.
                    // Other ordinary dictionary values remain application data.
                    pending.append(contentsOf: dictionary.values)
                }
            } else if let array = object as? [Any] { pending.append(contentsOf: array) }
        }
        return true
    }

    /// The JSON body JS appends after the header, or `nil` when JS appends
    /// nothing (`if (null != obj.data)` in `Encoder.encodeAsString`).
    ///
    /// CONNECT, DISCONNECT and CONNECT_ERROR carry a single value — an object,
    /// a string, or nothing at all — while EVENT and ACK carry the argument
    /// array. Swift stores both shapes in `data`, so the single-value types
    /// encode `data.first` as a JSON fragment.
    private func payloadJSON() throws -> String? {
        guard type.carriesArgumentArray else {
            guard let first = data.first else { return nil }

            return try SocketPacket.jsonString(from: first, fragmentsAllowed: true)
        }

        return try SocketPacket.jsonString(from: data, fragmentsAllowed: false)
    }

    /// `JSONSerialization` raises an uncatchable Objective-C exception for an
    /// invalid object graph, so validity is checked before encoding.
    ///
    /// Keys are sorted. JS preserves object insertion order, which a Swift
    /// `Dictionary` does not have at all, so the choice is between an arbitrary
    /// order and a reproducible one; JSON object order carries no meaning, and a
    /// reproducible encoder is what makes the wire strings testable and the
    /// encoder differential deterministic.
    static func jsonString(from value: Any, fragmentsAllowed: Bool) throws -> String {
        // This entry also serves hand-built packets and CONNECT auth payloads.
        // Never pass an uninspected Foundation graph into JSONSerialization.
        var normalizer = SocketEmitNormalizer(allowBinary: false)
        let normalized = try normalizer.normalize(value)
        guard JSONSerialization.isValidJSONObject(fragmentsAllowed ? [normalized] : normalized) else {
            throw SocketPacketError.unserializablePayload(String(describing: Swift.type(of: value)))
        }

        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if fragmentsAllowed {
            options.insert(.fragmentsAllowed)
        }

        let json: Data
        do {
            json = try JSONSerialization.data(withJSONObject: normalized, options: options)
        } catch {
            throw SocketPacketError.unserializablePayload(error.localizedDescription)
        }

        guard let string = String(data: json, encoding: .utf8) else {
            throw SocketPacketError.unserializablePayload("the encoded payload is not valid UTF-8")
        }

        return string
    }

    private func createHeaderString() -> String {
        let typeString = String(type.rawValue)
        // Binary count?
        let binaryCountString = typeString + (type.isBinary ? "\(String(binary.count))-" : "")
        // Namespace?
        let nspString = binaryCountString + (nsp != "/" ? "\(nsp)," : "")
        // Ack number?
        return nspString + (id != -1 ? String(id) : "")
    }

    // Called when we have all the binary data for a packet
    // calls _fillInPlaceholders, which replaces placeholders with the
    // corresponding binary
    private mutating func fillInPlaceholders() {
        data = data.map(_fillInPlaceholders)
    }

    // Helper method that looks for placeholders
    // If object is a collection it will recurse
    // Returns the object if it is not a placeholder or the corresponding
    // binary data
    private func _fillInPlaceholders(_ object: Any) -> Any {
        switch object {
        case let dict as JSON:
            if let marker = dict["_placeholder"] as? NSNumber,
               CFGetTypeID(marker) == CFBooleanGetTypeID(), marker.boolValue,
               let index = Self.placeholderIndex(dict["num"], count: binary.count) {
                return binary[index]
            } else {
                return dict.reduce(into: JSON(), {cur, keyValue in
                    cur[keyValue.0] = _fillInPlaceholders(keyValue.1)
                })
            }
        case let arr as [Any]:
            return arr.map(_fillInPlaceholders)
        default:
            return object
        }
    }
}

public extension SocketPacket {
    // MARK: PacketType enum

    /// The type of packets.
    enum PacketType: Int {
        // MARK: Cases

        /// Connect: 0
        case connect

        /// Disconnect: 1
        case disconnect

        /// Event: 2
        case event

        /// Ack: 3
        case ack

        /// Error: 4
        case error

        /// Binary Event: 5
        case binaryEvent

        /// Binary Ack: 6
        case binaryAck

        // MARK: Properties

        /// Whether or not this type is binary
        public var isBinary: Bool {
            return self == .binaryAck || self == .binaryEvent
        }

        /// Whether the wire payload of this type is the argument array.
        /// CONNECT, DISCONNECT and CONNECT_ERROR carry a single value instead
        /// (`Encoder.encodeAsString` in `socket.io-parser/lib/index.ts`).
        public var carriesArgumentArray: Bool {
            switch self {
            case .event, .ack, .binaryEvent, .binaryAck:
                return true
            case .connect, .disconnect, .error:
                return false
            }
        }
    }
}

/// Why an outgoing payload cannot be put on the wire.
///
/// JS `JSON.stringify` never changes the operation: it either produces the
/// value or throws. This client does the same — an emit whose payload cannot
/// be represented fails with one of these before any buffer, retry queue or
/// transport write sees it.
public enum SocketPacketError : Error, LocalizedError, CustomStringConvertible {
    // MARK: Cases

    /// A value with no JSON representation, e.g. a custom class, a `URL`, or
    /// `Data` in an emit made through `rawEmitView` (which does not shred
    /// binary into attachments). `path` locates it inside the emitted items.
    case unsupportedValue(path: String, type: String)

    /// A dictionary whose keys are not strings. JSON objects are string-keyed,
    /// and JS objects always are.
    case nonStringKey(path: String)

    /// The object graph is nested deeper than `SocketPacket.maximumEmitNestingDepth`.
    case nestingTooDeep(path: String, limit: Int)

    /// A Foundation array or dictionary refers to an ancestor in the payload.
    case cyclicPayload(path: String)

    /// The encoder's per-payload traversal budget was exceeded.
    case tooManyNodes(limit: Int)

    /// Escaped JSON plus binary attachment allowance exceeds the payload budget.
    case payloadTooLarge(limit: Int)

    /// `JSONSerialization` rejected the payload after normalization.
    case unserializablePayload(String)

    // MARK: Properties

    /// A description of this error.
    public var description: String {
        switch self {
        case let .unsupportedValue(path, type):
            return "\(path) is a \(type), which has no JSON representation"
        case let .nonStringKey(path):
            return "\(path) is a dictionary with a non-String key; JSON objects are string-keyed"
        case let .nestingTooDeep(path, limit):
            return "\(path) is nested deeper than the \(limit) level encoder limit"
        case let .cyclicPayload(path):
            return "\(path) contains a cyclic Foundation container"
        case let .tooManyNodes(limit):
            return "the payload exceeds the \(limit) node encoder limit"
        case let .payloadTooLarge(limit):
            return "the payload exceeds the \(limit) byte encoder budget"
        case let .unserializablePayload(reason):
            return "the payload cannot be serialized: \(reason)"
        }
    }

    /// :nodoc:
    public var errorDescription: String? {
        return description
    }
}

extension SocketPacket {
    private static func findType(_ binCount: Int, ack: Bool) -> PacketType {
        if binCount == 0 { return ack ? .ack : .event }
        return ack ? .binaryAck : .binaryEvent
    }

    /// Maximum outgoing object-graph depth, matching the decoder's default.
    public static let maximumEmitNestingDepth = 512

    /// Maximum nodes per payload, including repeated values and dictionary keys.
    public static let maximumEmitNodeCount = 1_000_000

    /// Conservative per-payload byte budget: escaped JSON plus binary bytes and
    /// 64 bytes per attachment placeholder. This is not a total queue/RSS limit.
    public static let maximumEmitPayloadBytes = 64 * 1024 * 1024

    /// `Date.prototype.toJSON()` — `toISOString()`, i.e. UTC with exactly three
    /// fractional-second digits and a `Z` suffix (`2024-01-02T03:04:05.678Z`).
    /// Years outside 0000–9999, which JS writes in its expanded `±YYYYYY` form,
    /// are not reproduced.
    ///
    /// Shared: it is configured once here and only ever read afterwards, and
    /// `DateFormatter.string(from:)` is documented as safe to call concurrently.
    private static let iso8601Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"

        return formatter
    }()

    /// The string JS `JSON.stringify(date)` produces for `date`.
    public static func iso8601String(from date: Date) -> String {
        return iso8601Formatter.string(from: date)
    }

    /// Applies JS `JSON.stringify` semantics to the items of an emit, and
    /// throws a `SocketPacketError` for anything that has no JSON form.
    ///
    /// - `Date`/`NSDate` become their ISO-8601 string, at any depth, because
    ///   that is what `Date.prototype.toJSON()` returns.
    /// - Non-finite numbers become `null`, because `JSON.stringify(NaN)` and
    ///   `JSON.stringify(Infinity)` are `"null"`. `JSONSerialization` would
    ///   otherwise reject the whole payload.
    /// - `Data` stays put when `allowBinary` is set (the shredder turns it into
    ///   an attachment placeholder) and is an error otherwise.
    /// - Everything else that JSON cannot represent throws, instead of the
    ///   pre-17.0.0 behaviour of sending an empty payload.
    ///
    /// - parameter items: The emitted items, after `socketRepresentation()`.
    /// - parameter allowBinary: Whether `Data` will be shredded into attachments.
    public static func jsonSafeEmitData(_ items: [Any], allowBinary: Bool) throws -> [Any] {
        var normalizer = SocketEmitNormalizer(allowBinary: allowBinary)
        guard let normalized = try normalizer.normalize(items) as? [Any] else {
            throw SocketPacketError.unserializablePayload("expected an argument array")
        }
        return normalized
    }

    static func packetFromEmit(_ items: [Any], id: Int, nsp: String, ack: Bool, checkForBinary: Bool = true) -> SocketPacket {
        if checkForBinary {
            let (parsedData, binary) = deconstructData(items)

            return SocketPacket(type: findType(binary.count, ack: ack), data: parsedData, id: id, nsp: nsp,
                                binary: binary)
        } else {
            return SocketPacket(type: findType(0, ack: ack), data: items, id: id, nsp: nsp)
        }
    }
}

private extension SocketPacket {
    // Recursive function that looks for NSData in collections
    static func shred(_ data: Any, binary: inout [Data]) -> Any {
        let placeholder = ["_placeholder": true, "num": binary.count] as JSON

        switch data {
        case let bin as Data:
            binary.append(bin)

            return placeholder
        case let arr as [Any]:
            return arr.map({shred($0, binary: &binary)})
        case let dict as JSON:
            // Sorted traversal so attachment numbering is reproducible. JS
            // `deconstructPacket` walks a JS object in insertion order, which a
            // Swift `Dictionary` does not have; without an order the same
            // payload could number its attachments differently on every emit.
            return dict.keys.sorted().reduce(into: JSON(), {cur, key in
                cur[key] = shred(dict[key]!, binary: &binary)
            })
        default:
            return data
        }
    }

    // Removes binary data from emit data
    // Returns a type containing the de-binaryed data and the binary
    static func deconstructData(_ data: [Any]) -> ([Any], [Data]) {
        var binary = [Data]()

        return (data.map({ shred($0, binary: &binary) }), binary)
    }
}


/// Per-encoding traversal state. Foundation containers are visited by identity
/// through CoreFoundation, never by recursively bridging them to Swift values.
/// Only ancestors are retained in `ancestors`, so shared acyclic subgraphs are
/// legal. Counts include repeated occurrences (and object keys), not identities.
internal struct SocketEmitNormalizer {
    private let maximumNodes: Int
    private let maximumBytes: Int
    private var nodesLeft: Int
    private var bytesLeft: Int
    private var ancestors = Set<ObjectIdentifier>()
    let allowBinary: Bool

    init(allowBinary: Bool,
         maximumNodes: Int = SocketPacket.maximumEmitNodeCount,
         maximumBytes: Int = SocketPacket.maximumEmitPayloadBytes) {
        self.allowBinary = allowBinary
        self.maximumNodes = max(0, maximumNodes)
        self.maximumBytes = max(0, maximumBytes)
        self.nodesLeft = max(0, maximumNodes)
        self.bytesLeft = max(0, maximumBytes)
    }

    private mutating func consumeNode() throws {
        guard nodesLeft > 0 else { throw SocketPacketError.tooManyNodes(limit: maximumNodes) }
        nodesLeft -= 1
    }

    private mutating func consumeBytes(_ count: Int) throws {
        guard count >= 0, count <= bytesLeft else {
            throw SocketPacketError.payloadTooLarge(limit: maximumBytes)
        }
        bytesLeft -= count
    }

    private func checkChildren(_ count: Int, dictionary: Bool = false) throws {
        // Check before allocating output capacity or a dictionary's pointer table.
        guard count <= nodesLeft / (dictionary ? 2 : 1) else {
            throw SocketPacketError.tooManyNodes(limit: maximumNodes)
        }
    }

    /// Charges an upper bound for JSONSerialization's escaped UTF-8 spelling,
    /// stopping at the first over-budget scalar, before serializing a whole graph.
    private mutating func string(_ value: String) throws -> String {
        try consumeBytes(2) // quotes
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 8, 9, 10, 12, 13, 34, 47, 92: try consumeBytes(2)
            case 0...31, 0x2028, 0x2029: try consumeBytes(6)
            case 0...0x7F: try consumeBytes(1)
            case 0x80...0x7FF: try consumeBytes(2)
            case 0x800...0xFFFF: try consumeBytes(3)
            default: try consumeBytes(4)
            }
        }
        return value
    }

    private mutating func foundationString(_ value: NSString) throws -> String {
        // UTF-16 length is a lower bound for JSON's UTF-8 spelling. Refuse a
        // huge mutable Foundation string before bridging/copying it into Swift.
        guard value.length <= bytesLeft else {
            throw SocketPacketError.payloadTooLarge(limit: maximumBytes)
        }
        return try string(value as String)
    }

    private mutating func number(_ value: NSNumber) throws -> Any {
        if CFGetTypeID(value) != CFBooleanGetTypeID(), !value.doubleValue.isFinite {
            try consumeBytes(4)
            return NSNull()
        }
        // Leaf-only serialization cannot recurse into a Foundation container.
        // It also accounts for booleans, full-width integers and decimal numbers.
        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        } catch {
            throw SocketPacketError.unserializablePayload(error.localizedDescription)
        }
        try consumeBytes(encoded.count)
        return value
    }

    private mutating func binary(_ value: Data, depth: Int, path: String) throws -> Data {
        guard allowBinary else { throw SocketPacketError.unsupportedValue(path: path, type: "Data") }
        // Reserve the eventual placeholder's two keys and two scalar values now,
        // before ack registration. Its dictionary replaces the already-counted
        // Data node; its children need one further nesting level at serialization.
        guard depth < SocketPacket.maximumEmitNestingDepth else {
            throw SocketPacketError.nestingTooDeep(path: path, limit: SocketPacket.maximumEmitNestingDepth)
        }
        for _ in 0..<4 { try consumeNode() }
        try consumeBytes(value.count)
        // Conservative allowance for the attachment placeholder and index. The
        // node limit bounds the index; 64 bytes exceeds its largest JSON spelling.
        try consumeBytes(64)
        return value
    }

    mutating func normalize(_ value: Any, depth: Int = -1, path: String = "payload") throws -> Any {
        guard depth <= SocketPacket.maximumEmitNestingDepth else {
            throw SocketPacketError.nestingTooDeep(path: path, limit: SocketPacket.maximumEmitNestingDepth)
        }
        try consumeNode()

        // `value is AnyObject` is NOT this check: Swift values bridge to
        // AnyObject too. Inspect the dynamic metatype before any collection cast.
        if Swift.type(of: value) is AnyClass {
            let object = value as AnyObject
            if let array = object as? NSArray {
                return try foundationArray(array, depth: depth, path: path)
            }
            if let dictionary = object as? NSDictionary {
                return try foundationDictionary(dictionary, depth: depth, path: path)
            }
            if object is NSNull { try consumeBytes(4); return NSNull() }
            if let text = object as? NSString { return try foundationString(text) }
            if let numeric = object as? NSNumber { return try number(numeric) }
            if let date = object as? NSDate { return try string(SocketPacket.iso8601String(from: date as Date)) }
            if let data = object as? NSData {
                guard allowBinary else { throw SocketPacketError.unsupportedValue(path: path, type: "Data") }
                guard data.length <= bytesLeft else { throw SocketPacketError.payloadTooLarge(limit: maximumBytes) }
                return try binary(data as Data, depth: depth, path: path)
            }
            throw SocketPacketError.unsupportedValue(path: path, type: String(describing: Swift.type(of: value)))
        }

        // Only native values reach these casts; Foundation collection casts
        // above never bridge their children recursively.
        switch value {
        case let text as String: return try string(text)
        case let date as Date: return try string(SocketPacket.iso8601String(from: date))
        case let data as Data: return try binary(data, depth: depth, path: path)
        case let numeric as NSNumber: return try number(numeric)
        case let array as [Any]:
            try checkChildren(array.count)
            try consumeBytes(2 + max(0, array.count - 1))
            var result = [Any]()
            result.reserveCapacity(array.count)
            for (index, child) in array.enumerated() {
                result.append(try normalize(child, depth: depth + 1, path: "\(path)[\(index)]"))
            }
            return result
        case let dictionary as [String: Any]:
            try checkChildren(dictionary.count, dictionary: true)
            try consumeBytes(2 + max(0, dictionary.count - 1))
            var result = [String: Any](minimumCapacity: dictionary.count)
            for (index, entry) in dictionary.enumerated() {
                try consumeNode()
                let key = try string(entry.key)
                try consumeBytes(1) // colon
                // Do not copy an unbounded key into every error-path string.
                result[key] = try normalize(entry.value, depth: depth + 1, path: "\(path).value[\(index)]")
            }
            return result
        case is [AnyHashable: Any]: throw SocketPacketError.nonStringKey(path: path)
        default: throw SocketPacketError.unsupportedValue(path: path, type: String(describing: Swift.type(of: value)))
        }
    }

    private mutating func foundationArray(_ array: NSArray, depth: Int, path: String) throws -> [Any] {
        let identity = ObjectIdentifier(array)
        guard ancestors.insert(identity).inserted else { throw SocketPacketError.cyclicPayload(path: path) }
        defer { ancestors.remove(identity) }
        return try withExtendedLifetime(array) {
            let cf = unsafeBitCast(array, to: CFArray.self)
            let count = CFArrayGetCount(cf)
            try checkChildren(count)
            try consumeBytes(2 + max(0, count - 1))
            var result = [Any]()
            result.reserveCapacity(count)
            for index in 0..<count {
                guard let pointer = CFArrayGetValueAtIndex(cf, index) else {
                    throw SocketPacketError.unserializablePayload("null Foundation array entry")
                }
                let child = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                result.append(try normalize(child, depth: depth + 1, path: "\(path)[\(index)]"))
            }
            return result
        }
    }

    private mutating func foundationDictionary(_ dictionary: NSDictionary, depth: Int, path: String) throws -> [String: Any] {
        let identity = ObjectIdentifier(dictionary)
        guard ancestors.insert(identity).inserted else { throw SocketPacketError.cyclicPayload(path: path) }
        defer { ancestors.remove(identity) }
        return try withExtendedLifetime(dictionary) {
            let cf = unsafeBitCast(dictionary, to: CFDictionary.self)
            let count = CFDictionaryGetCount(cf)
            try checkChildren(count, dictionary: true)
            try consumeBytes(2 + max(0, count - 1))
            var keys = [UnsafeRawPointer?](repeating: nil, count: count)
            var values = [UnsafeRawPointer?](repeating: nil, count: count)
            CFDictionaryGetKeysAndValues(cf, &keys, &values)
            var result = [String: Any](minimumCapacity: count)
            for index in 0..<count {
                guard let keyPointer = keys[index], let valuePointer = values[index],
                      let keyObject = Unmanaged<AnyObject>.fromOpaque(keyPointer).takeUnretainedValue() as? NSString else {
                    throw SocketPacketError.nonStringKey(path: path)
                }
                try consumeNode()
                let key = try foundationString(keyObject)
                try consumeBytes(1)
                let child = Unmanaged<AnyObject>.fromOpaque(valuePointer).takeUnretainedValue()
                result[key] = try normalize(child, depth: depth + 1, path: "\(path).value[\(index)]")
            }
            return result
        }
    }
}
