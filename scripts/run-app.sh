#!/usr/bin/env bash
# Build, package, and launch MasterControl as a real .app bundle.
#
# Running the bundled .app (vs the bare binary) makes the system treat
# MasterControl as a normal app: notifications work, TCC tracks by bundle
# ID rather than by binary path (so permissions don't reset on each
# rebuild), and Activity Monitor shows the proper name.
#
# `--bare` skips packaging and runs the unpackaged binary instead — fast
# iteration when you don't need notifications and don't mind re-granting
# Mic on every rebuild. (Claude task notifications won't fire in this
# mode; the runner falls back to NSLog.)

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="Release"

if [[ "${1:-}" == "--bare" ]]; then
  BIN=".xcode-build/Build/Products/$CONFIG/MasterControl"
  if [[ ! -x "$BIN" ]]; then
    echo "[run-app] no binary at $BIN — building first"
    scripts/build.sh "$CONFIG" MasterControl
  fi
  shift
  exec "$BIN" "$@"
fi

scripts/package-app.sh

APP="build/MasterControl.app"
echo
echo "==> Launching $APP"
exec "$APP/Contents/MacOS/MasterControl" "$@"
