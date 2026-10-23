#!/bin/bash
# Builds NovaMac.app (Release) and NovaMac-<version>.zip without opening Xcode.
# Needs Xcode installed (xcodebuild). Usage:  ./tools/build-release.sh
# Result: build/NovaMac.app and build/NovaMac-<version>.zip in the project folder.
#
# The build itself runs in ~/Library/Caches/NovaMac-build: a folder synced by iCloud (Documents, Desktop) adds
# extended attributes that codesign refuses ("resource fork, Finder information, or similar detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT="$PWD"
WORK="$HOME/Library/Caches/NovaMac-build"
mkdir -p "$WORK"

echo "Building NovaMac (Release) in $WORK …"
xcodebuild -project NovaMac.xcodeproj -target NovaMac -configuration Release \
  SYMROOT="$WORK/products" OBJROOT="$WORK/obj" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
  -quiet build

APP="$WORK/products/Release/NovaMac.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0")

mkdir -p "$PROJECT/build"
ZIP="$PROJECT/build/NovaMac-$VERSION.zip"
rm -rf "$PROJECT/build/NovaMac.app" "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"          # zip straight from the clean build folder
ditto "$APP" "$PROJECT/build/NovaMac.app"

echo
echo "App: $PROJECT/build/NovaMac.app"
echo "Zip: $ZIP   (upload this to GitHub Releases)"
echo "Install: drag NovaMac.app to /Applications (first start of an unsigned build: right-click → Open)."
open "$PROJECT/build"
