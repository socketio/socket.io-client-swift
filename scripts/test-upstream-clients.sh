#!/usr/bin/env bash
# The original Node-executed client suites, unmodified, at the pinned commit.
# Server packages are built solely as fixtures, not counted as client tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${1:?Usage: test-upstream-clients.sh /path/to/socket.io output-directory}"
OUTPUT="${2:?Missing output directory}"
mkdir -p "$OUTPUT"
test "$(git -C "$UPSTREAM" rev-parse HEAD)" = aaf2af36ec8ad05910f357a788e0e358bad32738
cd "$UPSTREAM"
git rev-parse HEAD > "$OUTPUT/upstream-sha.txt"
node --version > "$OUTPUT/node-version.txt"
npm ci --ignore-scripts --no-audit --no-fund 2>&1 | tee "$OUTPUT/install.log"
npm run compile -w engine.io-parser -w engine.io -w engine.io-client -w socket.io-adapter -w socket.io-parser -w socket.io-client -w socket.io 2>&1 | tee "$OUTPUT/compile.log"
npm run test:node -w socket.io-client 2>&1 | tee "$OUTPUT/socket.io-client.log"
npm run test:node -w socket.io-parser 2>&1 | tee "$OUTPUT/socket.io-parser.log"
npm run test:node -w engine.io-parser 2>&1 | tee "$OUTPUT/engine.io-parser.log"
# The separately declared webtransport.mjs suite and browser runners are not
# executed here. This core invocation otherwise preserves the upstream hooks.
run_engine_client() {
  local mode="$1"
  shift
  (cd packages/engine.io-client && env "$@" ../../node_modules/.bin/mocha --bail --require test/support/hooks.js test/index.js) \
    2>&1 | tee "$OUTPUT/engine.io-client-$mode.log"
}
run_engine_client default
run_engine_client fetch USE_FETCH=1
run_engine_client builtin-ws USE_BUILTIN_WS=1
NODE_PATH="$UPSTREAM/node_modules" node "$ROOT/scripts/inventory-upstream-tests.cjs" "$UPSTREAM" "$OUTPUT"
python3 "$ROOT/scripts/check-parity-contracts.py" --upstream-inventory "$OUTPUT/javascript-test-inventory.json"
