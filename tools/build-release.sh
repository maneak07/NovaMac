#!/bin/bash
# Builds NovaMac.app (Release) and NovaMac-<version>.zip without opening Xcode.
# Needs Xcode installed (xcodebuild). Usage:  ./tools/build-release.sh
# Result: build/Release/NovaMac.app and build/NovaMac-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building NovaMac (Release)…"
xcodebuild -project NovaMac.xcodeproj -target NovaMac -configuration Release \
  SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
  -quiet build

APP="build/Release/NovaMac.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0")
ZIP="build/NovaMac-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "App: $PWD/$APP"
echo "Zip: $PWD/$ZIP   (upload this to GitHub Releases)"
echo "Install: drag NovaMac.app to /Applications (first start of an unsigned build: right-click → Open)."
open "build/Release"
