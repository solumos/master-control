#!/usr/bin/env bash
# Wrap the xcodebuild-produced MasterControl binary into a real .app bundle.
#
# Output: ./build/MasterControl.app
# Ad-hoc signed (`codesign --sign -`) so it runs on the developer's Mac.
# Distribution to other users will need Developer ID + notarytool — that's
# Wave 3 W3.1 proper.
#
# Usage:
#   scripts/package-app.sh             # builds + packages
#   scripts/package-app.sh --no-build  # assume the binary is already built

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="Release"
BUILD_DIR=".xcode-build/Build/Products/$CONFIG"
APP_DIR="build/MasterControl.app"
INFO_PLIST="App/Info.plist"
ENTITLEMENTS="App/MasterControl.entitlements"

DO_BUILD=1
for arg in "$@"; do
  if [[ "$arg" == "--no-build" ]]; then DO_BUILD=0; fi
done

if [[ $DO_BUILD -eq 1 ]]; then
  echo "==> Building MasterControl ($CONFIG)"
  scripts/build.sh "$CONFIG" MasterControl
fi

if [[ ! -x "$BUILD_DIR/MasterControl" ]]; then
  echo "[package-app] no binary at $BUILD_DIR/MasterControl — build failed?" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 1) Info.plist
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"

# 2) PkgInfo (8 bytes, "APPL????" — old-school but harmless)
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

# 3) The binary itself
cp "$BUILD_DIR/MasterControl" "$APP_DIR/Contents/MacOS/MasterControl"

# 4) SwiftPM resource bundles (Bundle.module looks for these next to the
#    executable — for example mlx-swift's metallib lives in
#    mlx-swift_Cmlx.bundle, FluidAudio's tokenizer assets in
#    swift-transformers_Hub.bundle, etc.).
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_DIR/Contents/MacOS/"
done
shopt -u nullglob

# 5) Ad-hoc code signature. With our entitlements + hardened-runtime flag
#    so the eventual Developer ID build is byte-compatible.
echo "==> Ad-hoc signing"
codesign --force --sign - \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  --deep \
  "$APP_DIR" 2>&1 | tail -5

echo
echo "Built: $APP_DIR"
echo "Drag this to /Applications, or run: scripts/install.sh"
