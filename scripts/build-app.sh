#!/usr/bin/env bash
# Builds a release binary and wraps it in "build/OrbitBar.app" (ad-hoc signed).
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

# Local settings (not committed): .env may set ORBITBAR_IMAGE_PROXY, ORBITBAR_IMAGE_PROXY_KEY, ORBITBAR_SIGN_IDENTITY.
# Variables already in the environment win, so CI is unaffected.
if [ -f .env ]; then
  while IFS='=' read -r name value; do
    case "$name" in ''|\#*) continue ;; esac
    if [ -z "${!name:-}" ]; then export "$name=$value"; fi
  done < .env
fi

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/OrbitBar"
[ -x "$BIN" ] || BIN="$(find .build -path '*release*' -type f -name OrbitBar -perm -111 | head -1)"

APP="build/OrbitBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OrbitBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The image proxy (worker/image-proxy) is configured from the environment, so its URL is not committed:
#   ORBITBAR_IMAGE_PROXY      the worker's URL (from .env locally, a GitHub secret of the same name in the release workflow)
#   ORBITBAR_IMAGE_PROXY_KEY  optional, the worker's PROXY_KEY
# Without a URL, images from other sites show a "Load Image" button instead of loading on their own.
if [ -n "${ORBITBAR_IMAGE_PROXY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :OrbitBarImageProxy string $ORBITBAR_IMAGE_PROXY" "$APP/Contents/Info.plist"
  if [ -n "${ORBITBAR_IMAGE_PROXY_KEY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :OrbitBarImageProxyKey string $ORBITBAR_IMAGE_PROXY_KEY" "$APP/Contents/Info.plist"
  fi
  echo "Image proxy: $ORBITBAR_IMAGE_PROXY"
else
  echo "Image proxy: none (set ORBITBAR_IMAGE_PROXY to use one)"
fi
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
