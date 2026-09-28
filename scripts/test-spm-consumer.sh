#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONSUMER="$(mktemp -d "${RUNNER_TEMP:-/tmp}/socketio-consumer.XXXXXX")"
trap 'rm -rf "$CONSUMER"' EXIT
export SOCKETIO_CONSUMER_ROOT="$ROOT"
export SOCKETIO_CONSUMER_DIR="$CONSUMER"
python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ['SOCKETIO_CONSUMER_DIR'])
if os.environ.get('GITHUB_REF_TYPE') == 'tag':
    tag = os.environ['GITHUB_REF_NAME']
    if tag != 'v17.1.0':
        raise SystemExit('Expected release tag v17.1.0, got ' + tag)
    dependency = '.package(url: "https://github.com/kaeferfreund/socket.io-client-swift.git", exact: "17.1.0")'
else:
    dependency = '.package(path: ' + json.dumps(os.environ['SOCKETIO_CONSUMER_ROOT']) + ')'
(root / 'Package.swift').write_text('''// swift-tools-version:6.4
import PackageDescription
let package = Package(
    name: "ReleaseConsumer",
    platforms: [.macOS(.v12)],
    dependencies: [DEPENDENCY],
    targets: [.executableTarget(name: "ReleaseConsumer", dependencies: [
        .product(name: "SocketIO", package: "socket.io-client-swift")
    ])]
)
'''.replace('DEPENDENCY', dependency))
source = root / 'Sources' / 'ReleaseConsumer'
source.mkdir(parents=True)
(source / 'main.swift').write_text('''import Foundation
import SocketIO
let manager = SocketManager(socketURL: URL(string: "https://localhost/admin")!, config: [.requestTimeout(120)])
let socket = manager.defaultSocket
precondition(socket.status == .notConnected)
precondition(socket.nsp == "/admin")
precondition(manager.socket(forNamespace: "/").nsp == "/")
print("SocketIO independent SPM consumer passed")
''')
PY
swift run --package-path "$CONSUMER" ReleaseConsumer
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  python3 - <<'VERIFY'
import json
import os
import subprocess
from pathlib import Path
resolved = json.loads((Path(os.environ['SOCKETIO_CONSUMER_DIR']) / 'Package.resolved').read_text())
pins = [pin for pin in resolved['pins'] if pin['identity'] == 'socket.io-client-swift']
assert len(pins) == 1, 'Expected exactly one SocketIO package pin'
state = pins[0]['state']
expected = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
assert state['version'] == '17.1.0', state
assert state['revision'] == expected, (state, expected)
print('Verified published SocketIO 17.1.0 at ' + expected)
print(json.dumps(resolved, indent=2))
VERIFY
fi
