#!/bin/bash
# Builds the downloadable ClipB: arm64 release, Developer ID signed with the
# hardened runtime, packed into a DMG, notarized by Apple and stapled.
#
#   make dist                               # auto-picks your "Developer ID Application" cert
#   make dist DIST_IDENTITY="Developer ID Application: Name (TEAMID)"
#   make dist DIST_MODEL=~/path/ggml-large-v3-turbo.bin   # bundle the speech model (~600 MB DMG)
#   make dist DIST_IDENTITY=-               # ad-hoc test build: no notarization, other Macs will block it
#
# One-time notarization setup (an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials clipb --apple-id you@example.com --team-id TEAMID
set -euo pipefail

IDENTITY="${DIST_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-clipb}"
MODEL="${DIST_MODEL:-}"
OUT=bin/dist
APP="$OUT/ClipB.app"
BUNDLE_ID=com.productmind.clipb
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' appInfo/Info.plist)
DMG="$OUT/ClipB-$VERSION-arm64.dmg"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'dist: %s\n' "$*" >&2; exit 1; }

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
    [ -n "$IDENTITY" ] || die 'no "Developer ID Application" certificate in your keychain.
  Join the Apple Developer Program, create one in Xcode > Settings > Accounts >
  Manage Certificates, then run make dist again. To test the packaging now:
  make dist DIST_IDENTITY=-'
fi
ADHOC=0; [ "$IDENTITY" = "-" ] && ADHOC=1
if [ -n "$MODEL" ]; then
    MODEL="${MODEL/#\~/$HOME}"
    [ -f "$MODEL" ] || die "DIST_MODEL not found: $MODEL"
fi

say "Building ClipB $VERSION (arm64, release)"
swift build -c release --arch arm64 --scratch-path .build-dist
BUILD=$(swift build -c release --arch arm64 --scratch-path .build-dist --show-bin-path)
[ -f "$BUILD/clipb" ] || die "no binary at $BUILD/clipb"
# History must never touch disk in a shipped build (CLAUDE.md invariant 1).
SYMBOLS=$(nm "$BUILD/clipb") || die "nm failed on $BUILD/clipb"
if grep -q DevPersistence <<<"$SYMBOLS"; then die "DevPersistence is linked into the release binary"; fi

say "Assembling $APP"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp appInfo/Info.plist "$APP/Contents/Info.plist"
cp "$BUILD/clipb" "$APP/Contents/MacOS/clipb"
ditto "$BUILD/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
if [ -n "$MODEL" ]; then
    say "Bundling the speech model ($(du -h "$MODEL" | cut -f1))"
    cp "$MODEL" "$APP/Contents/Resources/ggml-large-v3-turbo.bin"
fi

say "Signing with: $IDENTITY"
SIGN=(codesign --force --sign "$IDENTITY")
[ $ADHOC = 1 ] || SIGN+=(--options runtime --timestamp)
# Inside out: nested code first, the app last.
"${SIGN[@]}" "$APP/Contents/Frameworks/whisper.framework"
if [ $ADHOC = 1 ]; then
    # Same identifier-only requirement as `make bundle`, so the Accessibility grant survives rebuilds.
    "${SIGN[@]}" --entitlements appInfo/ClipB.entitlements -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
else
    "${SIGN[@]}" --entitlements appInfo/ClipB.entitlements "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

say "Packing $DMG"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/clipb-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/ClipB.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ClipB $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
"${SIGN[@]}" "$DMG"

if [ $ADHOC = 1 ]; then
    say "Ad-hoc build: skipping notarization. Fine on this Mac; Gatekeeper blocks it elsewhere."
else
    say "Notarizing (profile: $PROFILE) — usually a few minutes"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

say "Done: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
