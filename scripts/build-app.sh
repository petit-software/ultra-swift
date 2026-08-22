#!/bin/bash
# Build Ultra.app from the current checkout.
#
# A release build plus a bundle: SwiftPM produces a bare executable, and a bare executable
# has no Info.plist, so it cannot own a bundle identifier, an icon, or a Settings window
# that remembers its size.
#
# Everything the bundle needs lives in Resources/ and is tracked, so this works from a clean
# clone. It used to read the version out of the previously built Ultra.app, which meant the
# app could only be rebuilt on a machine that had already built it once.
#
# Ad-hoc signed. Developer ID signing and notarization are a later milestone.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="Ultra.app"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

echo "Building Ultra $VERSION ($BUILD_NUMBER) — release…"
swift build -c release --product Ultra

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Copied to a temp name and moved into place: replacing the binary of a RUNNING app in
# place fails, and a half-written executable is worse than an old one.
cp ".build/release/Ultra" "$APP/Contents/MacOS/Ultra.new"
mv -f "$APP/Contents/MacOS/Ultra.new" "$APP/Contents/MacOS/Ultra"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# The build number tracks the commit count, so About can tell two builds apart.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# --- Icon -------------------------------------------------------------------------------
# Built from the single 1024pt master rather than checking in eleven PNGs that can drift
# apart. macOS does NOT round an app icon for you: the squircle is part of the artwork, so
# the master is used as-is.
ICONSET="$(mktemp -d)/Ultra.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" Resources/AppIcon.png --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Ultra.icns"
rm -rf "$(dirname "$ICONSET")"

# Re-sign after every change; a stale signature makes the bundle refuse to launch.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "signature OK"

# Finder and the Dock cache icons per bundle path, so a changed icon can keep showing the
# old one until the bundle's mtime moves.
touch "$APP"

echo "Built $APP — version $VERSION ($BUILD_NUMBER)"
echo "Quit any running Ultra, then: open $APP"
