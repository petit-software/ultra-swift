#!/bin/bash
# Build, sign, notarize and package Ultra for release, and update the appcast.
#
# This is the ONLY thing that produces an updatable copy. `build-app.sh` deliberately makes a
# bundle with no feed URL, because that bundle is written into the checkout and an updater
# that offers to replace a developer's own build with a download would overwrite uncommitted
# work. See Updater.swift.
#
# Nothing secret lives here. Credentials come from the environment, so this file is safe to
# read, safe to commit, and safe to paste into a CI log:
#
#   DEVELOPER_ID   "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE name of a notarytool keychain profile, created once with:
#                  xcrun notarytool store-credentials NOTARY_PROFILE \
#                      --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
#   SPARKLE_KEY    OPTIONAL path to an EdDSA private key file. Left unset, Sparkle uses the
#                  key in your login keychain, which is where `generate_keys` puts it and the
#                  safer default. Create it once:  .build/artifacts/.../bin/generate_keys
#                  This is SEPARATE from Developer ID: Apple's signature says the APP is from
#                  you, Sparkle's says the UPDATE is. Lose it and no existing install can ever
#                  be updated again — it belongs in a password manager, not a folder.
#   FEED_URL       where the appcast will live, e.g.
#                  https://github.com/USER/REPO/releases/latest/download/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?set DEVELOPER_ID — see the header of this script}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE — see the header of this script}"
: "${FEED_URL:?set FEED_URL — see the header of this script}"

APP="Ultra.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="dist"
DMG="$OUT/Ultra-$VERSION.dmg"

# Refuse to ship a dirty tree. A release nobody can check out again is not a release.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — commit or stash before releasing" >&2
  exit 1
fi

echo "==> Building Ultra $VERSION ($BUILD_NUMBER)"
scripts/build-app.sh

echo "==> Stamping the update feed"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist" \
  2>/dev/null || /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$APP/Contents/Info.plist"
# SUPublicEDKey is NOT stamped here — it lives in the tracked Resources/Info.plist, which is
# correct twice over: it is a PUBLIC key, so it belongs in the repository, and baking it in
# means a release does not depend on the right private key happening to be in the keychain of
# whoever runs this. A mismatch would produce updates that every installed copy refuses, and
# the failure would appear on users' machines rather than here.
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: Resources/Info.plist has no SUPublicEDKey — run generate_keys" >&2
  exit 1
fi

echo "==> Signing with Developer ID"
# Inner code first, and NOT --deep: --deep re-signs nested code with the OUTER bundle's
# options, which is how an XPC service ends up without the entitlements it needed. Apple
# document it as unsuitable for distribution; each nested item is signed on its own terms.
find "$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 -type d 2>/dev/null | while read -r fw; do
  find "$fw" \( -name "*.xpc" -o -name "*.app" \) -print0 | while IFS= read -r -d '' nested; do
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$nested"
  done
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$fw"
done
# Hardened runtime is required for notarization, and the app spawns login shells and PTYs,
# so it needs the exception that allows them.
codesign --force --options runtime --timestamp \
  --entitlements Resources/Ultra.entitlements \
  --sign "$DEVELOPER_ID" "$APP"

codesign --verify --strict --verbose=2 "$APP"

echo "==> Packaging"
mkdir -p "$OUT"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Ultra $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

echo "==> Notarizing (this waits on Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
# Stapled so a first launch works without a network round-trip — and so it works at all for
# someone offline, who otherwise sees "Ultra is damaged".
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Appcast"
GEN="$(find .build/artifacts -name generate_appcast -type f | head -1)"
if [ -n "${SPARKLE_KEY:-}" ]; then
  "$GEN" --ed-key-file "$SPARKLE_KEY" "$OUT"
else
  "$GEN" "$OUT"   # signs with the key in the login keychain
fi
echo
echo "Built $DMG"
echo "Upload $DMG and $OUT/appcast.xml to the GitHub release for v$VERSION."
echo "The feed must stay at: $FEED_URL"
