#!/usr/bin/env bash
# Build mc-spike via xcodebuild.
#
# We use Xcode rather than `swift build` because mlx-swift's Metal shaders
# can only be compiled to .metallib by Xcode — SwiftPM CLI builds work for
# every other module but mlx-swift fails at runtime with
# "Failed to load the default metallib".

set -euo pipefail

CONFIG="${1:-Release}"

xcodebuild \
  -scheme mc-spike \
  -destination 'platform=macOS' \
  -configuration "$CONFIG" \
  -derivedDataPath .xcode-build \
  -skipMacroValidation \
  build \
  | tail -50

BIN=".xcode-build/Build/Products/$CONFIG/mc-spike"
if [[ -x "$BIN" ]]; then
  echo
  echo "Built: $BIN"
fi
