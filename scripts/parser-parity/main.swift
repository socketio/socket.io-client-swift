import Foundation
func normal(_ value: Any) -> Any {
    if let d = value as? Data { return ["__bytes": [UInt8](d)] }
    if let a = value as? [Any] { return a.map(normal) }
    if let d = value as? JSON { return d.mapValues(normal) }
    return value
}
/// Inverse of `normal`: the generator marks attachments as `{"__bytes": [...]}`
/// so binary can sit anywhere in an encode vector's payload.
func denormal(_ value: Any) -> Any {
    if let d = value as? JSON {
        if d.count == 1, let bytes = d["__bytes"] as? [Int] {
            return Data(bytes.map { UInt8(truncatingIfNeeded: $0) })
        }
        return d.mapValues(denormal)
    }
    if let a = value as? [Any] { return a.map(denormal) }
    return value
}
/// Encode direction: build the packet the client would send and hand the wire
/// string plus its attachments back, for the pinned JavaScript decoder to read.
func encode(_ spec: JSON) throws -> JSON {
    guard let rawType = spec["type"] as? Int,
          let type = SocketPacket.PacketType(rawValue: rawType),
          let nsp = spec["nsp"] as? String else { throw NSError(domain: "encode", code: 1) }
    let id = spec["id"] as? Int ?? -1
    let payload = spec["data"].map(denormal)
    let packet: SocketPacket
    if type.carriesArgumentArray {
        guard let items = payload as? [Any] else { throw NSError(domain: "encode", code: 2) }
        // The same normalization every emit goes through before a packet exists.
        let safe = try SocketPacket.jsonSafeEmitData(items, allowBinary: true)
        packet = SocketPacket.packetFromEmit(safe, id: id, nsp: nsp, ack: type == .ack, checkForBinary: true)
    } else {
        packet = SocketPacket(type: type, data: payload.map { [$0] } ?? [], id: id, nsp: nsp)
    }
    return ["status": "ok", "header": try packet.encodedPacketString(),
            "binaries": packet.binary.map { [UInt8]($0) }]
}
let parser = Parser()
while let line = readLine() {
    var result: JSON
    do {
        guard let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else {
            throw NSError(domain: "input", code: 1)
        }
        if let spec = input["encode"] as? JSON {
            result = try encode(spec)
        } else {
            guard let header = input["header"] as? String else { throw NSError(domain: "input", code: 1) }
            var packet = try parser.parseString(header)
            var completed = !packet.type.isBinary
            for bytes in input["binaries"] as? [[UInt8]] ?? [] {
                if !packet.type.isBinary || completed { throw NSError(domain: "probe", code: 1) }
                completed = packet.addData(Data(bytes))
                if packet.reconstructionFailed { throw NSError(domain: "probe", code: 2) }
            }
            if !completed { result = ["status": "pending"] }
            else {
                var type = packet.type.rawValue
                if type == 5 { type = 2 }; if type == 6 { type = 3 }
                let payload: Any = type == 0 || type == 4 ? (packet.data.first ?? NSNull()) : (type == 1 ? NSNull() as Any : packet.data as Any)
                result = ["status": "ok", "type": type, "id": packet.id, "nsp": packet.nsp, "data": normal(payload)]
            }
        }
    } catch { result = ["status": "error"] }
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed])
    print(String(data: data, encoding: .utf8)!)
}
