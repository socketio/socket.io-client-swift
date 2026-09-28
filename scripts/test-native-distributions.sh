#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if grep -R -n 'import Starscream\|CertificatePinning\|Starscream.xcframework' Source Tests --include='*.swift'; then
  echo 'Removed dependency remains in source or tests' >&2; exit 1
fi
if grep -n Starscream Package.swift; then
  echo 'Removed dependency remains in package metadata' >&2; exit 1
fi
echo 'Resolving Swift package schemes'
xcodebuild -list
for DESTINATION in \
  'platform=macOS' \
  'generic/platform=iOS Simulator' \
  'generic/platform=tvOS Simulator' \
  'generic/platform=watchOS Simulator'
do
  echo "Building Swift package for $DESTINATION"
  xcodebuild -quiet -scheme SocketIO -destination "$DESTINATION" \
    -derivedDataPath "${RUNNER_TEMP:-/tmp}/socketio-native-distributions" \
    CODE_SIGNING_ALLOWED=NO build
done
