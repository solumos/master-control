#!/usr/bin/env bash
# Build a SwiftPM scheme via xcodebuild.
#
# We use Xcode rather than `swift build` because mlx-swift's Metal shaders
# can only be compiled to .metallib by Xcode — SwiftPM CLI builds work for
# every other module but mlx-swift fails at runtime with
# "Failed to load the default metallib".
#
# Usage:
#   scripts/build.sh                       # default: Release of mc-spike + MasterControl
#   scripts/build.sh Debug                 # Debug config, both schemes
#   scripts/build.sh Release MasterControl # build a single scheme
#   scripts/build.sh Release mc-spike

set -euo pipefail

CONFIG="${1:-Release}"
shift || true

if [[ $# -gt 0 ]]; then
  SCHEMES=("$@")
else
  SCHEMES=(mc-spike MasterControl)
fi

for SCHEME in "${SCHEMES[@]}"; do
  echo "==> Building $SCHEME ($CONFIG)"
  xcodebuild \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -configuration "$CONFIG" \
    -derivedDataPath .xcode-build \
    -skipMacroValidation \
    build \
    | tail -10

  BIN=".xcode-build/Build/Products/$CONFIG/$SCHEME"
  if [[ -x "$BIN" ]]; then
    echo "    Built: $BIN"
  fi
done
