#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONSUMER="$(mktemp -d "${RUNNER_TEMP:-/tmp}/socketio-docs.XXXXXX")"
trap 'rm -rf "$CONSUMER"' EXIT
export SOCKETIO_DOCS_ROOT="$ROOT"
export SOCKETIO_DOCS_CONSUMER="$CONSUMER"
python3 - <<'PY'
import json
import os
from pathlib import Path
import re

repository = Path(os.environ['SOCKETIO_DOCS_ROOT'])
consumer = Path(os.environ['SOCKETIO_DOCS_CONSUMER'])
readme = (repository / 'README.md').read_text(encoding='utf-8')
start, end = '<!-- quick-start:begin -->', '<!-- quick-start:end -->'
if readme.count(start) != 1 or readme.count(end) != 1:
    raise SystemExit('README must contain exactly one marked quick-start example')
example = readme.split(start)[1].split(end)[0].strip()
match = re.fullmatch(r'```swift\n(.*?)\n```', example, re.S)
if not match:
    raise SystemExit('Marked quick start must contain exactly one Swift code fence')
(consumer / 'Package.swift').write_text('''// swift-tools-version:6.4
import PackageDescription
let package = Package(
    name: "DocumentationSmoke",
    platforms: [.macOS(.v12)],
    dependencies: [.package(name: "socket.io-client-swift", path: PATH)],
    targets: [.executableTarget(name: "DocumentationSmoke", dependencies: [
        .product(name: "SocketIO", package: "socket.io-client-swift")
    ])],
    swiftLanguageModes: [.v6]
)
'''.replace('PATH', json.dumps(str(repository))))
source = consumer / 'Sources' / 'DocumentationSmoke'
source.mkdir(parents=True)
(source / 'RealtimeClient.swift').write_text(match[1] + '\n')
(source / 'Smoke.swift').write_text('''import Foundation
@main
struct DocumentationSmoke {
    @MainActor
    static func main() {
        let client = RealtimeClient(url: URL(string: "https://localhost")!)
        withExtendedLifetime(client) {
            print("README quick start compiled and initialized; no network connection attempted")
        }
    }
}
''')
PY
swift run --package-path "$CONSUMER" DocumentationSmoke
