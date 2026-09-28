import Foundation

/// Engine.IO packet framing is independent of transport lifecycle: a decoded
/// CLOSE does not stop the parser, but does stop subsequent engine dispatch.
struct SocketEnginePacket: Equatable {
    let type: SocketEnginePacketType
    var data: EngineWebSocketMessage? = nil
}

enum SocketEnginePacketCodecError: Error { case parserError }

enum SocketEnginePacketCodec {
    static func encode(_ packet: SocketEnginePacket, supportsBinary: Bool) -> EngineWebSocketMessage {
        switch packet.data {
        case .binary(let data):
            return supportsBinary ? .binary(data) : .text("b" + data.base64EncodedString())
        case .text(let text): return .text(String(packet.type.rawValue) + text)
        case nil: return .text(String(packet.type.rawValue))
        }
    }

    static func encodeText(_ text: String, type: SocketEnginePacketType) -> String {
        guard case .text(let encoded) = encode(.init(type: type, data: .text(text)), supportsBinary: false)
        else { preconditionFailure("Text packets encode to text") }
        return encoded
    }

    static func join(_ encodedPackets: [String]) -> String { encodedPackets.joined(separator: "\u{1e}") }

    static func encodePayload(_ packets: [SocketEnginePacket]) -> String {
        join(packets.map {
            guard case .text(let value) = encode($0, supportsBinary: false)
            else { preconditionFailure("Polling packets encode to text") }
            return value
        })
    }

    static func decode(_ encoded: EngineWebSocketMessage) -> Result<SocketEnginePacket, SocketEnginePacketCodecError> {
        switch encoded {
        case .binary: return .success(.init(type: .message, data: encoded))
        case .text(let text):
            let bytes = Array(text.utf8)
            guard let first = bytes.first else { return .failure(.parserError) }
            if first == 98 {
                return .success(.init(type: .message, data: .binary(decodeBase64(text.utf16.dropFirst().map { UInt8(truncatingIfNeeded: $0) }))))
            }
            guard first >= 48, first <= 54,
                  let type = SocketEnginePacketType(rawValue: Int(first - 48)) else { return .failure(.parserError) }
            let data: EngineWebSocketMessage? = bytes.count == 1 ? nil : .text(String(decoding: bytes.dropFirst(), as: UTF8.self))
            return .success(.init(type: type, data: data))
        }
    }

    static func decodePayload(_ payload: String) -> [Result<SocketEnginePacket, SocketEnginePacketCodecError>] {
        var packets = [Result<SocketEnginePacket, SocketEnginePacketCodecError>]()
        for record in payload.components(separatedBy: "\u{1e}") {
            let packet = decode(.text(record))
            packets.append(packet)
            if case .failure = packet { break }
        }
        return packets
    }

    /// Node's Buffer base64 input accepts omitted padding, URL-safe digits and
    /// ignored non-alphabet bytes; residual bits do not produce another byte.
    private static func decodeBase64(_ input: [UInt8]) -> Data {
        var output = Data()
        var bits = 0
        var accumulator = 0
        for byte in input {
            if byte == 61 { break }
            let value: Int
            switch byte {
            case 65...90: value = Int(byte - 65)
            case 97...122: value = Int(byte - 97) + 26
            case 48...57: value = Int(byte - 48) + 52
            case 43, 45: value = 62
            case 47, 95: value = 63
            default: continue
            }
            accumulator = (accumulator << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(accumulator >> bits))
                accumulator &= (1 << bits) - 1
            }
        }
        return output
    }
}
