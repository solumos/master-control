#!/usr/bin/env bash
# Build (if needed) and run mc-spike with arguments.
#
# Usage: scripts/run.sh [--iterations N] [--no-llm]

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="Release"
BIN=".xcode-build/Build/Products/$CONFIG/mc-spike"

if [[ ! -x "$BIN" ]]; then
  echo "[run] no binary at $BIN — building first"
  scripts/build.sh "$CONFIG"
fi

exec "$BIN" "$@"
