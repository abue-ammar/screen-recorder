#!/bin/bash
#
#  appcast.sh
#  Scripts
#
#  Created by rit3zh CX on 10/24/26.
#

# Writes dist/appcast.xml, the feed Screen Recorder's updater reads from the latest GitHub release, for the app in
# dist/ScreenRecorder.zip. The archive and the feed are both signed with the EdDSA key in your login keychain, the one
# SUPublicEDKey in project.yml matches. Pass a Markdown file to show as the release notes in the update card.
# Run by dmg.sh and release.sh; run it on its own to change the notes without rebuilding.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="abue-ammar/screen-recorder"
APP_NAME="Screen Recorder"
DIST="dist"
ZIP="$DIST/ScreenRecorder.zip"
NOTES="${1:-}"

BIN=$(find build -type d -path "*/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)
if [ -z "$BIN" ]; then
  echo "Sparkle's tools aren't in build/ yet. Run scripts/dmg.sh (or scripts/release.sh) first." >&2
  exit 1
fi
if [ ! -f "$ZIP" ]; then
  echo "No $ZIP. Run scripts/dmg.sh (or scripts/release.sh) first." >&2
  exit 1
fi
if [ -n "$NOTES" ] && [ ! -f "$NOTES" ]; then
  echo "No release notes at $NOTES." >&2
  exit 1
fi
if ! "$BIN/generate_keys" -p >/dev/null 2>&1; then
  echo "No update signing key in your keychain. Import your backup with:" >&2
  echo "  $BIN/generate_keys -f <backup file>" >&2
  echo "Only make a new one (generate_keys) if the old one is lost: installed copies of the app won't accept updates" >&2
  echo "signed with a new key, and SUPublicEDKey in project.yml has to change." >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q "$ZIP" "$APP_NAME.app/Contents/Info.plist" "$APP_NAME.app/Contents/MacOS/$APP_NAME" -d "$WORK"
PLIST="$WORK/$APP_NAME.app/Contents/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw "$PLIST" 2>/dev/null || echo "15.0")
TAG="v$VERSION"

# An Apple silicon-only build must not be offered to Intel Macs.
HARDWARE=""
if ! lipo -archs "$WORK/$APP_NAME.app/Contents/MacOS/$APP_NAME" | grep -q x86_64; then
  HARDWARE="<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
fi

DESCRIPTION=""
if [ -n "$NOTES" ]; then DESCRIPTION=$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES"); fi
SIGNATURE=$("$BIN/sign_update" "$ZIP")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <link>https://github.com/$REPO/releases</link>
    <item>
      <title>$APP_NAME $VERSION</title>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      $HARDWARE
      <description sparkle:format="markdown"><![CDATA[$DESCRIPTION]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/ScreenRecorder.zip" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
"$BIN/sign_update" "$DIST/appcast.xml"
"$BIN/sign_update" --verify "$DIST/appcast.xml"
echo "Done: $DIST/appcast.xml ($APP_NAME $VERSION, build $BUILD)"
