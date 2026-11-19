#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONSUMER="$(mktemp -d "${RUNNER_TEMP:-/tmp}/socketio-consumer.XXXXXX")"
trap 'rm -rf "$CONSUMER"' EXIT
export SOCKETIO_CONSUMER_ROOT="$ROOT"
export SOCKETIO_CONSUMER_DIR="$CONSUMER"
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  export SOCKETIO_RELEASE_VERSION="${GITHUB_REF_NAME#v}"
fi
python3 - <<'PY'
import json
import os
import re
from pathlib import Path

repository = Path(os.environ['SOCKETIO_CONSUMER_ROOT'])
root = Path(os.environ['SOCKETIO_CONSUMER_DIR'])
# The consumer declares the same tools version as the package, so it checks the
# floor the package manifest admits instead of a separately maintained copy.
tools_version = (repository / 'Package.swift').read_text(encoding='utf-8').splitlines()[0]
if not re.fullmatch(r'// swift-tools-version: *\d+\.\d+(\.\d+)?', tools_version):
    raise SystemExit('Package.swift must start with a swift-tools-version line, got ' + repr(tools_version))
if os.environ.get('GITHUB_REF_TYPE') == 'tag':
    tag = os.environ['GITHUB_REF_NAME']
    version = os.environ['SOCKETIO_RELEASE_VERSION']
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise SystemExit('Release tags must be vMAJOR.MINOR.PATCH, got ' + tag)
    heading = (repository / 'CHANGELOG.md').read_text(encoding='utf-8').splitlines()[0]
    match = re.match(r'## (\d+\.\d+\.\d+) ', heading)
    if not match or match[1] != version:
        raise SystemExit('Tag ' + tag + ' does not match the newest CHANGELOG.md release heading ' + repr(heading))
    dependency = '.package(url: "https://github.com/kaeferfreund/socket.io-client-swift.git", exact: ' + json.dumps(version) + ')'
else:
    dependency = '.package(path: ' + json.dumps(str(repository)) + ')'
(root / 'Package.swift').write_text('''TOOLS_VERSION
import PackageDescription
let package = Package(
    name: "ReleaseConsumer",
    platforms: [.macOS(.v12)],
    dependencies: [DEPENDENCY],
    targets: [.executableTarget(name: "ReleaseConsumer", dependencies: [
        .product(name: "SocketIO", package: "socket.io-client-swift")
    ])]
)
'''.replace('TOOLS_VERSION', tools_version).replace('DEPENDENCY', dependency))
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
version = os.environ['SOCKETIO_RELEASE_VERSION']
assert state['version'] == version, state
assert state['revision'] == expected, (state, expected)
print('Verified published SocketIO ' + version + ' at ' + expected)
print(json.dumps(resolved, indent=2))
VERIFY
fi
