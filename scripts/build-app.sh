#!/usr/bin/env bash
# Builds a release binary and wraps it in "build/OrbitBar.app" (ad-hoc signed).
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/OrbitBar"
[ -x "$BIN" ] || BIN="$(find .build -path '*release*' -type f -name OrbitBar -perm -111 | head -1)"

APP="build/OrbitBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OrbitBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# A stable signing identity keeps the keychain item trusted across rebuilds. An ad-hoc signature changes with every
# build, so macOS asks for keychain access again each time. ORBITBAR_SIGN_IDENTITY (a name or hash from
# `security find-identity -v -p codesigning`) picks the identity; without it the first "Apple Development" identity
# is used, and without one the app is signed ad-hoc.
SIGN_IDENTITY="${ORBITBAR_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "Signed ad-hoc: macOS will ask for keychain access again after each rebuild (set ORBITBAR_SIGN_IDENTITY to avoid this)"
else
  echo "Signed with: $SIGN_IDENTITY"
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x OrbitBar 2>/dev/null || true
  rm -rf "/Applications/OrbitBar.app" "/Applications/Orbit Bar.app"  # the second is the old name
  cp -R "$APP" /Applications/
  open "/Applications/OrbitBar.app"
  echo "Installed to /Applications/OrbitBar.app"
fi
