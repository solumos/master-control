#!/usr/bin/env bash
# Build the .app bundle and install it to /Applications/.
#
# After install:
#   - Double-click MasterControl in /Applications, or
#   - `open /Applications/MasterControl.app`
#
# First launch will prompt for Microphone permission (and Apple Events
# the first time you ask MasterControl to control Chrome / Spotify /
# Terminal / Mail).

set -euo pipefail

cd "$(dirname "$0")/.."

scripts/package-app.sh

DEST="/Applications/MasterControl.app"
SRC="build/MasterControl.app"

if [[ -d "$DEST" ]]; then
  echo "==> Replacing existing $DEST"
  rm -rf "$DEST"
fi

cp -R "$SRC" "$DEST"

# Clear quarantine so Gatekeeper doesn't show "downloaded from internet"
# for an ad-hoc-signed local build.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
echo "Installed: $DEST"
echo "Launch with: open '$DEST'"
echo
echo "On first launch macOS will prompt for Microphone access. Grant it."
echo "Drop your Anthropic key into ~/Downloads/.env to enable LLM responses:"
echo "  echo 'ANTHROPIC_API_KEY=sk-ant-...' >> ~/Downloads/.env"
