#!/usr/bin/env bash
# Pre-fetch every FluidAudio model the runtime needs into ./build/Models so
# that scripts/package-pkg.sh can ship them inside the .pkg installer.
#
# Output layout:
#   build/Models/parakeet-tdt-0.6b-v2/
#   build/Models/silero-vad/
#   build/Models/kokoro/
#
# Idempotent: re-runs skip files that already exist on disk (FluidAudio's
# loaders verify-then-load), so this is cheap to call from packaging.
#
# Usage:
#   scripts/fetch-models.sh           # populate build/
#   scripts/fetch-models.sh path/to   # populate path/to/Models/...

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-build}"
mkdir -p "$OUT_DIR"
ABS_OUT="$(cd "$OUT_DIR" && pwd)"

echo "==> Fetching models into $ABS_OUT"
swift run -c release FetchModels "$ABS_OUT"

echo
echo "==> Sizes"
du -sh "$ABS_OUT/Models"/* 2>/dev/null || true
