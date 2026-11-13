#!/bin/bash
#
#  sign-app.sh
#  Scripts
#
#  Created by abue-ammar on 11/14/26.
#

# Makes a built app Apple silicon only, then signs it inside out. The app itself is built for arm64 alone, but Sparkle
# comes universal with ad-hoc signed helpers: its Intel half is removed and each piece is signed again, then the app.
# Usage: scripts/sign-app.sh APP IDENTITY [--timestamp]
set -euo pipefail

APP=$1
IDENTITY=$2
TIMESTAMP=${3:-}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

while IFS= read -r -d '' file; do
  if lipo -archs "$file" 2>/dev/null | grep -q x86_64; then lipo -remove x86_64 "$file" -output "$file"; fi
done < <(find "$APP" -type f -perm -u+x -print0)

sign() { codesign -f -s "$IDENTITY" -o runtime ${TIMESTAMP:+"$TIMESTAMP"} "$@"; }
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --preserve-metadata=entitlements,requirements,flags "$APP"
codesign --verify --deep --strict "$APP"
