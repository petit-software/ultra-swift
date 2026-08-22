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

mkdir -p "$APP/Contents/MacOS"
# Rebuilt from scratch so a renamed or dropped icon cannot linger and be picked up.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources"

# Copied to a temp name and moved into place: replacing the binary of a RUNNING app in
# place fails, and a half-written executable is worse than an old one.
cp ".build/release/Ultra" "$APP/Contents/MacOS/Ultra.new"
mv -f "$APP/Contents/MacOS/Ultra.new" "$APP/Contents/MacOS/Ultra"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# The build number tracks the commit count, so About can tell two builds apart.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# --- Icon -------------------------------------------------------------------------------
scripts/make-iconset.sh "$APP/Contents/Resources"

# Re-sign after every change; a stale signature makes the bundle refuse to launch.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "signature OK"

# Finder and the Dock cache icons per bundle path, so a changed icon can keep showing the
# old one until the bundle's mtime moves.
touch "$APP"

echo "Built $APP — version $VERSION ($BUILD_NUMBER)"
echo "Quit any running Ultra, then: open $APP"
