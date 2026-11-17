#!/usr/bin/env bash
# Builds the app and packs it into a drag-to-Applications installer: "build/OrbitBar <version>.dmg".
#   scripts/release.sh
#
# Anyone but you can only open the app without a Gatekeeper warning if it is signed with a "Developer ID Application"
# certificate and notarized by Apple (both need a paid Apple Developer account). The script does what it can:
#   - Developer ID identity found (or ORBITBAR_SIGN_IDENTITY set): signs with the hardened runtime and a timestamp.
#   - ORBITBAR_NOTARY_PROFILE set: also notarizes the dmg and staples the ticket. Create the profile once with
#       xcrun notarytool store-credentials <profile> --apple-id <you@example.com> --team-id <TEAMID>
#   - Otherwise: the dmg is not notarized and others see a Gatekeeper warning on first launch (macOS 14: right-click →
#     Open; macOS 15+: System Settings → Privacy & Security → Open Anyway; or run
#       xattr -dr com.apple.quarantine "/Applications/OrbitBar.app"
# The version comes from CFBundleShortVersionString in Resources/Info.plist: bump it before a release.
set -euo pipefail
cd "$(dirname "$0")/.."
# .env (see .env.example) is read here too, so ORBITBAR_SIGN_IDENTITY from it applies to the identity chosen below.
source scripts/load-env.sh

PLIST="Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
APP="build/OrbitBar.app"
DMG="build/OrbitBar $VERSION.dmg"
VOLUME="OrbitBar $VERSION"

# Pick the signing identity: explicit, else Developer ID, else whatever build-app.sh finds.
IDENTITY="${ORBITBAR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ]; then export ORBITBAR_SIGN_IDENTITY="$IDENTITY"; fi

echo "==> Building OrbitBar $VERSION ($BUILD)"
scripts/build-app.sh

SIGNED_WITH_DEVELOPER_ID=0
if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  echo "==> Signing with the hardened runtime: $IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
  SIGNED_WITH_DEVELOPER_ID=1
elif [ -n "$IDENTITY" ]; then
  echo "==> Signed with \"$IDENTITY\", which is not a Developer ID: other Macs will show a Gatekeeper warning"
else
  echo "==> No Developer ID identity: other Macs will show a Gatekeeper warning"
fi
codesign --verify --deep --strict "$APP"

echo "==> Creating $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [ "$SIGNED_WITH_DEVELOPER_ID" = 1 ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if [ -n "${ORBITBAR_NOTARY_PROFILE:-}" ]; then
  if [ "$SIGNED_WITH_DEVELOPER_ID" != 1 ]; then
    echo "error: notarization needs a Developer ID Application identity (set ORBITBAR_SIGN_IDENTITY)" >&2
    exit 1
  fi
  echo "==> Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$ORBITBAR_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "==> Skipping notarization (set ORBITBAR_NOTARY_PROFILE to notarize)"
fi

echo
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
