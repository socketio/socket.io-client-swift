#!/usr/bin/env bash
# Compare the real Swift decoder against hash-verified, pinned upstream JS source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${1:?Usage: test-parser-parity.sh /path/to/socket.io [result.json]}"
export PARITY_OUTPUT="${2:-$PWD/decoder-differential-results.json}"
PARITY_TEMP="$(mktemp -d)"
export PARITY_TEMP
trap 'rm -rf "$PARITY_TEMP"' EXIT
node "$ROOT/scripts/parser-parity/prepare.cjs" "$UPSTREAM"
swiftc -swift-version 6 "$ROOT/scripts/parser-parity/Shims.swift" \
  "$ROOT/Source/SocketIO/Parse/SocketPacket.swift" \
  "$ROOT/Source/SocketIO/Parse/SocketParsable.swift" \
  "$ROOT/Source/SocketIO/Client/SocketReservedEvent.swift" \
  "$ROOT/scripts/parser-parity/main.swift" -o "$PARITY_TEMP/swift-decoder"
node "$ROOT/scripts/parser-parity/compare.cjs"
