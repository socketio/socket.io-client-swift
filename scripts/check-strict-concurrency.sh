#!/usr/bin/env bash
#
# Review gate R5: build the library with `-strict-concurrency=complete` and fail
# when the number of concurrency warnings grows.
#
# This is a ratchet, not a clean-build requirement: the package builds in the
# Swift 6 language mode, and any remaining diagnostics under
# `-strict-concurrency=complete` are recorded as a baseline instead of being
# silenced by stamping mutable classes `@unchecked Sendable`.
#
# The baseline is per platform, because the Objective-C and Security code paths
# only compile on Apple platforms. A platform with no recorded baseline is
# reported, not failed — the run prints the line to add, so the first CI run on
# a new platform produces the number instead of a red build.
#
# Usage:
#   scripts/check-strict-concurrency.sh              # check against the baseline
#   scripts/check-strict-concurrency.sh --record     # rewrite this platform's entry
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$REPO_ROOT/Documentation/ReviewEvidence/StrictConcurrencyBaseline.json"
LOG="${STRICT_CONCURRENCY_LOG:-${RUNNER_TEMP:-/tmp}/strict-concurrency.log}"
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *)      PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
esac

cd "$REPO_ROOT"
echo "Building with -strict-concurrency=complete on $PLATFORM"
# The build itself must still succeed; only the warning count is ratcheted.
set +e
swift build -Xswiftc -strict-concurrency=complete >"$LOG" 2>&1
BUILD_STATUS=$?
set -e
if [ $BUILD_STATUS -ne 0 ]; then
  echo "Build failed under -strict-concurrency=complete:"
  grep -E "error:" "$LOG" | head -40
  exit 1
fi

# One line per diagnostic; swiftc repeats the text in the annotated source line.
COUNT=$(grep -cE "^[^[:space:]].*:[0-9]+:[0-9]+: warning:" "$LOG" || true)
echo "strict-concurrency warnings on $PLATFORM: $COUNT"
echo "full log: $LOG"

if [ "$RECORD" = "1" ]; then
  python3 - "$BASELINE" "$PLATFORM" "$COUNT" <<'PY'
import json, sys
path, platform, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path) as handle:
    data = json.load(handle)
data.setdefault("baselines", {})[platform] = count
with open(path, "w") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
print("recorded %s = %d in %s" % (platform, count, path))
PY
  exit 0
fi

BASE=$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
value = data.get("baselines", {}).get(sys.argv[2])
print("" if value is None else value)
' "$BASELINE" "$PLATFORM")

if [ -z "$BASE" ]; then
  echo
  echo "No strict-concurrency baseline recorded for '$PLATFORM'."
  echo "Add this to $BASELINE and commit it:"
  echo "    \"$PLATFORM\": $COUNT"
  echo "or run: scripts/check-strict-concurrency.sh --record"
  exit 0
fi

if [ "$COUNT" -gt "$BASE" ]; then
  echo
  echo "FAIL: $((COUNT - BASE)) new strict-concurrency warning(s) (baseline $BASE, now $COUNT)."
  echo "Fix them, or justify and re-record with --record. Do not stamp mutable"
  echo "classes @unchecked Sendable to make this pass."
  grep -E "^[^[:space:]].*:[0-9]+:[0-9]+: warning:" "$LOG" | head -60
  exit 1
fi

if [ "$COUNT" -lt "$BASE" ]; then
  echo "Warnings went down ($BASE -> $COUNT). Re-record the baseline with --record."
fi
echo "OK: $COUNT warnings, baseline $BASE."
