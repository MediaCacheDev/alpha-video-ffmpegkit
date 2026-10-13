#!/bin/bash
# Runs the Swift package's XCTests on an iOS simulator: the booted iPhone if there is one,
# otherwise the first available. SIMULATOR_ID overrides the choice.
set -euo pipefail
cd "$(dirname "$0")/.."

pick() { xcrun simctl list devices available | grep -m1 "$1" | grep -oE '[0-9A-F-]{36}' || true; }
id="${SIMULATOR_ID:-$(pick 'iPhone.*(Booted)')}"
id="${id:-$(pick 'iPhone')}"
if [ -z "$id" ]; then
  echo "No iPhone simulator available; install one in Xcode, or set SIMULATOR_ID." >&2
  exit 1
fi

xcodebuild test -scheme AlphaVideoFFmpegKit -destination "platform=iOS Simulator,id=$id" \
  -derivedDataPath ios/build/swift-tests -quiet
