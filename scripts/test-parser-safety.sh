#!/usr/bin/env bash
# Offline crash-regression smoke test using the actual parser/packet source.
# The shims replace only manager/logging/JSON conveniences, not parsing logic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/Shims.swift" <<'SWIFT'
import Foundation
public typealias JSON = [String: Any]
public protocol SocketManagerSpec: AnyObject {
    var parserOptions: SocketParserOptions { get }
}
enum DefaultSocketLogger { static let Logger = QuietLogger() }
struct QuietLogger {
    func log(_ text: String, type: String) {}
    func error(_ text: String, type: String) {}
}
extension Array { func toJSON() throws -> Data { try JSONSerialization.data(withJSONObject: self) } }
final class Parser: SocketManagerSpec, SocketDataBufferable, SocketParsable {
    let parserOptions = SocketParserOptions()
    var waitingPackets = [SocketPacket]()
}
SWIFT
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
let parser = Parser()
// Everything socket.io-parser's "throw an error upon parsing error" rejects,
// plus the Swift-only binary placeholder and attachment-overflow guards.
let rejected = ["", "5", "6", "51-", "51", "50-[\"x\"]", "5a-", "51.23-", "999",
    "442[\"some\",\"data\"", "0/admin,\"invalid\"", "0[]", "1[]", "1/admin,{}",
    "2/admin,\"invalid", "2/admin,{}", "2[]", "3{}", "2[{\"toString\":\"foo\"}]",
    "2[true,\"foo\"]", "2[null,\"bar\"]", "2[\"connect\"]", "2[\"disconnect\",\"123\"]",
    "51-[\"x\",{\"_placeholder\":true,\"num\":99}]",
    "51-[\"x\",{\"_placeholder\":true,\"num\":-1}]",
    "51-[\"x\",{\"_placeholder\":true}]", "59999999999999999999999-[\"x\"]"]
for message in rejected {
    precondition((try? parser.parseString(message)) == nil, "Accepted invalid packet: \(message)")
}
// JS parses a payload only `if (str.charAt(++i))`: these decode to a packet
// whose data is `undefined`, which the client turns into a no-op.
for message in ["2", "3", "2123", "2/namespace,", "399"] {
    guard let packet = try? parser.parseString(message), packet.data.isEmpty else {
        preconditionFailure("Rejected payload-less packet: \(message)")
    }
}
let numbered = try parser.parseString("2123")
precondition(numbered.id == 123 && numbered.nsp == "/")
let namespaced = try parser.parseString("2/namespace,")
precondition(namespaced.nsp == "/namespace" && namespaced.id == -1)
// An ack id beyond Int is a float in JS: the packet survives, the ack is dropped.
let overflowed = try parser.parseString("29999999999999999999999[\"x\"]")
precondition(overflowed.id == -1 && overflowed.event == "x")
let good = try parser.parseString("2/é🦧,0[\"x\"]")
precondition(good.id == 0 && good.nsp == "/é🦧")
var binary = try parser.parseString("51-[\"x\",{\"_placeholder\":true,\"num\":0}]")
precondition(binary.addData(Data([7])) && binary.args.first as? Data == Data([7]))
var state: UInt64 = 0x51234
let alphabet = Array("0123456789abcdef/-_,:\"[]{} nulltrue🦧é")
for _ in 0..<20000 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    let size = Int((state >> 32) % 96)
    var text = ""
    for _ in 0..<size {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        text.append(alphabet[Int((state >> 32) % UInt64(alphabet.count))])
    }
    if var packet = try? parser.parseString(text) {
        _ = packet.event; _ = packet.args
        if packet.type.isBinary {
            for _ in 0..<parser.parserOptions.maximumAttachments {
                if packet.addData(Data([1])) { break }
            }
        }
    }
}
print("PASS: \(rejected.count) known malformed headers rejected; payload-less/overflowed-id, Unicode and binary valid controls; 20,000 seeded malformed inputs, no crash")
SWIFT
swiftc -swift-version 6 "$TMP/Shims.swift" \
    "$ROOT/Source/SocketIO/Parse/SocketParsable.swift" \
    "$ROOT/Source/SocketIO/Parse/SocketPacket.swift" \
    "$ROOT/Source/SocketIO/Client/SocketReservedEvent.swift" \
    "$TMP/main.swift" -o "$TMP/probe"
"$TMP/probe"
