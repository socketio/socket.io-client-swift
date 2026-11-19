#!/usr/bin/env bash
# Find the oldest installed Xcode whose Swift compiler matches the
# swift-tools-version declared in the root Package.swift.
#
# The manifest's tools version is the oldest toolchain the package admits, so CI
# must build with exactly that compiler; a newer one can accept code the floor
# rejects. Reading the floor from Package.swift keeps CI and manifest in step.
#
# Prints the selected DEVELOPER_DIR and, under GitHub Actions, also writes it to
# the step output `developer_dir`. Fails, listing every installed Xcode, when no
# matching toolchain is installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

floor="$(sed -nE '1s#^// swift-tools-version: *([0-9]+\.[0-9]+).*$#\1#p' "$ROOT/Package.swift")"
if [ -z "$floor" ]; then
  echo "Package.swift must start with a '// swift-tools-version:MAJOR.MINOR' line" >&2
  exit 1
fi
pattern="Swift version ${floor//./\\.}([^0-9]|$)"
echo "Declared swift-tools-version floor: $floor"

selected=""
while IFS= read -r app; do
  developer_dir="$app/Contents/Developer"
  [ -d "$developer_dir" ] || continue
  version="$(DEVELOPER_DIR="$developer_dir" xcrun swift --version 2>&1 | grep -m1 'Swift version' || true)"
  echo "  $app: ${version:-no Swift toolchain}"
  if [ -z "$selected" ] && grep -qE "$pattern" <<<"$version"; then
    selected="$developer_dir"
  fi
done < <(find /Applications -maxdepth 1 -name 'Xcode*.app' -print | sort -V)

if [ -z "$selected" ]; then
  echo "No installed Xcode provides Swift $floor; the declared floor cannot be verified on this runner." >&2
  exit 1
fi

echo "Selected $selected"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "developer_dir=$selected" >>"$GITHUB_OUTPUT"
fi
