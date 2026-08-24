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
# A LOCAL build never gets a feed URL, so it can never offer an update. See Updater.swift:
# this bundle is written into the checkout, and offering to replace a developer's own build
# with a download would overwrite uncommitted work. scripts/release.sh adds the key.
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
# The build number tracks the commit count, so About can tell two builds apart.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# --- SwiftPM resource bundles -----------------------------------------------------------
# A package target with `resources:` compiles them into a `<Package>_<Target>.bundle` left in
# the build directory, and nothing copies it into the .app — SwiftPM has no notion of one.
#
# Contents/Resources, which is where `Bundle.main.resourceURL` points and where a packaged
# app is expected to put these. Contents/MacOS looks right, because that is "beside the
# executable" and it is what SwiftPM's own generated accessor probes first, but the accessor
# also calls `fatalError` when it misses — SwiftTerm avoids it for exactly that reason and
# searches `resourceURL` itself.
#
# Missing, the failure is narrow and silent: everything that does not touch a resource still
# works, so the app looks fine. SwiftTerm's Metal renderer loads its shader source this way,
# and without the bundle it threw "Failed to load Metal shader source" and fell back to
# CoreGraphics — the GPU setting appeared to be doing nothing at all.
#
# Copied wholesale rather than by name so a bundle added by any future dependency travels too.
for RESOURCE_BUNDLE in .build/release/*.bundle; do
  [ -e "$RESOURCE_BUNDLE" ] || continue
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
  echo "  embedded $(basename "$RESOURCE_BUNDLE")"
done

# --- Icon -------------------------------------------------------------------------------
scripts/make-iconset.sh "$APP/Contents/Resources"

# --- Frameworks -------------------------------------------------------------------------
# SwiftPM links Sparkle but does not embed it: a bare executable has nowhere to embed it TO.
# The framework has to travel inside the bundle, and the executable needs an rpath that finds
# it there — without one the app launches only on a machine that happens to have Sparkle.
SPARKLE="$(find .build/artifacts -name Sparkle.framework -maxdepth 5 -type d | head -1)"
if [ -n "$SPARKLE" ]; then
  rm -rf "$APP/Contents/Frameworks"
  mkdir -p "$APP/Contents/Frameworks"
  # -R preserves the framework's symlinks; copying it flat produces a bundle that fails to
  # load with an error naming a path that plainly exists.
  cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
  # Already present on a rebuild, and add_rpath fails rather than no-ops on a duplicate.
  if ! otool -l "$APP/Contents/MacOS/Ultra" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Ultra"
  fi
else
  echo "warning: Sparkle.framework not found — run 'swift build' first" >&2
fi

# Re-sign after every change; a stale signature makes the bundle refuse to launch.
# Inner code FIRST: a signature over a bundle is a signature over what it contained at the
# time, so signing the app before its framework leaves the app's seal describing something
# that no longer matches.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  codesign --force --sign - --timestamp=none --deep "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "signature OK"

# Finder and the Dock cache icons per bundle path, so a changed icon can keep showing the
# old one until the bundle's mtime moves.
touch "$APP"

echo "Built $APP — version $VERSION ($BUILD_NUMBER)"
echo "Quit any running Ultra, then: open $APP"
