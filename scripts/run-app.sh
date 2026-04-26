#!/usr/bin/env bash
# Build (if needed) and launch MasterControl as a menu-bar app.
#
# Look for a microphone icon in the menu bar after launch.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="Release"
BIN=".xcode-build/Build/Products/$CONFIG/MasterControl"

if [[ ! -x "$BIN" ]]; then
  echo "[run-app] no binary at $BIN — building first"
  scripts/build.sh "$CONFIG"
fi

# Run in foreground so logs/permission prompts surface here.
# Ctrl-C exits.
exec "$BIN" "$@"
