#!/usr/bin/env bash
# Build a flat macOS .pkg installer that drops both the .app and the
# pre-fetched FluidAudio models into the right places, so the installed
# app launches without a network round-trip.
#
# Layout the .pkg writes:
#   /Applications/MasterControl.app
#   /Library/Application Support/MasterControl/Models/parakeet-tdt-0.6b-v2/
#   /Library/Application Support/MasterControl/Models/silero-vad/
#   /Library/Application Support/MasterControl/Models/kokoro/
#
# Usage:
#   scripts/package-pkg.sh                 # builds + fetches + packages
#   scripts/package-pkg.sh --no-build      # reuse existing .app + models
#
# Output: build/MasterControl-<version>.pkg
#
# Signing: ad-hoc by default. Set DEVELOPER_ID_INSTALLER to a
# Developer-ID Installer cert name to produce a signed/notarizable .pkg.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_DIR="build/MasterControl.app"
MODELS_DIR="build/Models"
STAGING="build/pkg-staging"
SCRIPTS_DIR="build/pkg-scripts"
INFO_PLIST="App/Info.plist"
IDENTIFIER="com.solumos.MasterControl"

DO_BUILD=1
for arg in "$@"; do
  if [[ "$arg" == "--no-build" ]]; then DO_BUILD=0; fi
done

if [[ $DO_BUILD -eq 1 ]]; then
  scripts/package-app.sh
  scripts/fetch-models.sh build
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "[package-pkg] missing $APP_DIR — run without --no-build" >&2
  exit 1
fi
if [[ ! -d "$MODELS_DIR" ]]; then
  echo "[package-pkg] missing $MODELS_DIR — run without --no-build" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST")"
PKG_OUT="build/MasterControl-${VERSION}.pkg"

echo "==> Staging install tree"
rm -rf "$STAGING" "$SCRIPTS_DIR"
mkdir -p "$STAGING/Applications"
mkdir -p "$STAGING/Library/Application Support/MasterControl/Models"

# Copy the app (preserves signature/entitlements applied by package-app.sh)
cp -R "$APP_DIR" "$STAGING/Applications/"

# Copy the models payload
cp -R "$MODELS_DIR/." "$STAGING/Library/Application Support/MasterControl/Models/"

# Postinstall: clear any quarantine xattr Gatekeeper would otherwise nag
# about, and make sure the models dir is world-readable so every user on
# the machine can launch the app.
mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -e
xattr -dr com.apple.quarantine "/Applications/MasterControl.app" 2>/dev/null || true
chmod -R a+rX "/Library/Application Support/MasterControl" 2>/dev/null || true
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

echo "==> Building $PKG_OUT (version $VERSION)"
SIGN_ARGS=()
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
  SIGN_ARGS=(--sign "$DEVELOPER_ID_INSTALLER")
  echo "    Signing with: $DEVELOPER_ID_INSTALLER"
else
  echo "    (no DEVELOPER_ID_INSTALLER — building unsigned .pkg)"
fi

pkgbuild \
  --root "$STAGING" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  --scripts "$SCRIPTS_DIR" \
  "${SIGN_ARGS[@]}" \
  "$PKG_OUT"

echo
echo "Built: $PKG_OUT"
echo "Install with: sudo installer -pkg $PKG_OUT -target /"
