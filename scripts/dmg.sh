#!/bin/bash
#
#  dmg.sh
#  Scripts
#
#  Created by rit3zh CX on 10/16/26.
#

# Builds dist/ScreenRecorder.dmg without an Apple Developer account: signed with the self-signed identity from
# Config/Signing.local.xcconfig (see setup-local-signing.sh), not notarized. Keep that certificate: releases signed
# with the same one keep users' Screen Recording, Camera and Microphone permissions across updates.
# Also writes dist/ScreenRecorder.zip and dist/appcast.xml for the in-app updater (see appcast.sh); pass the release notes
# (a Markdown file) to show them in the update card: scripts/dmg.sh notes.md
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Config/Signing.local.xcconfig"
IDENTITY=$(awk -F' = ' '/^CODE_SIGN_IDENTITY/ {print $2}' "$CONFIG" 2>/dev/null || true)
if [ -z "$IDENTITY" ]; then
  echo "No signing identity in $CONFIG. Run scripts/setup-local-signing.sh first." >&2
  exit 1
fi
APP_NAME="Screen Recorder"
ASSET="ScreenRecorder"
DIST="dist"
VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2}' project.yml)

xcodegen generate >/dev/null
rm -rf "$DIST" build/dmg
mkdir -p "$DIST"

echo "Building ${APP_NAME} ${VERSION}…"
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder -configuration Release -derivedDataPath build/dmg \
  clean build | grep -E "error:|BUILD" || true
APP="build/dmg/Build/Products/Release/$APP_NAME.app"
test -d "$APP"
codesign --verify --deep --strict "$APP"

echo "Building DMG…"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$ASSET.dmg" >/dev/null
codesign --sign "$IDENTITY" "$DIST/$ASSET.dmg"

(cd "$DIST" && shasum -a 256 "$ASSET.dmg" > "$ASSET.dmg.sha256")
echo "Done: $DIST/$ASSET.dmg ($VERSION)"
cat "$DIST/$ASSET.dmg.sha256"

echo "Building update…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ASSET.zip"
scripts/appcast.sh "${1:-}"
