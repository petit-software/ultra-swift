#!/bin/bash
# Build Ultra.app from the current checkout.
#
# A release build plus a bundle: SwiftPM produces a bare executable, and a bare executable
# has no Info.plist, so it cannot own a bundle identifier, a Settings window that remembers
# its size, or the "regular app" activation policy without asking for it at runtime.
#
# Ad-hoc signed. Developer ID signing and notarization are a later milestone; ad-hoc is
# enough to run locally and keeps the bundle from being quarantined as unsigned.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="Ultra.app"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1)"

echo "Building Ultra $VERSION ($BUILD_NUMBER) — release…"
swift build -c release --product Ultra

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Copied to a temp name and moved into place: replacing the binary of a RUNNING app in
# place fails, and a half-written executable is worse than an old one.
cp ".build/release/Ultra" "$APP/Contents/MacOS/Ultra.new"
mv -f "$APP/Contents/MacOS/Ultra.new" "$APP/Contents/MacOS/Ultra"

# The build number tracks the commit count, so About can tell two builds apart.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Re-sign after every change; a stale signature makes the bundle refuse to launch.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "signature OK"

echo "Built $APP — version $VERSION ($BUILD_NUMBER)"
echo "Quit any running Ultra, then: open $APP"
