#!/bin/bash
# Assembles a proper StickyDeck.app bundle from a release SPM build and
# ad-hoc signs it (sandboxed). Usage: scripts/make_app.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="StickyDeck"
BUNDLE_ID="app.stickydeck.StickyDeck"
# Both version numbers come from git so they cannot drift from the release
# they were cut for. Tag first, then build.
#
# CFBundleShortVersionString is the nearest tag with its leading "v" removed.
# CFBundleVersion is the commit count, which increases monotonically on a
# linear history — updaters compare it numerically to decide what is newer,
# so it must never go backwards.
#
# A shallow clone can do neither: it has no tags and cannot count commits.
# That is fine for CI and local builds, which only need well-formed values;
# release.sh refuses to publish from a tree where these would be wrong.
RAW_VERSION_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ "$RAW_VERSION_TAG" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
else
    # Local/CI builds from an untagged or non-release-tagged history still need
    # an Apple-valid CFBundleShortVersionString (three period-separated ints).
    VERSION="0.0.0"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUT_DIR="${1:-build}"
APP="$OUT_DIR/$APP_NAME.app"

if [ "${STICKYDECK_UNIVERSAL:-0}" = "1" ]; then
    ARM_TRIPLE="arm64-apple-macosx15.0"
    INTEL_TRIPLE="x86_64-apple-macosx15.0"
    swift build -c release --triple "$ARM_TRIPLE"
    swift build -c release --triple "$INTEL_TRIPLE"
    ARM_BIN="$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)"
    INTEL_BIN="$(swift build -c release --triple "$INTEL_TRIPLE" --show-bin-path)"
    BIN="$ARM_BIN"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>StickyDeck</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST

if [ "${STICKYDECK_UNIVERSAL:-0}" = "1" ]; then
    lipo -create \
        "$ARM_BIN/$APP_NAME" \
        "$INTEL_BIN/$APP_NAME" \
        -output "$APP/Contents/MacOS/$APP_NAME"
else
    cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
fi
cp -R Sources/StickyDeck/Resources/Fonts "$APP/Contents/Resources/Fonts"

# The icon is generated art, not a checked-in blob you cannot edit: run
# scripts/make_icon.swift to regenerate it from source. StickyDeck is an
# LSUIElement app, so this never reaches the Dock — it is what Finder, Get
# Info, Spotlight, the About panel and the release disk image show.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SPM resource bundle must ship next to the executable's resources, otherwise
# the generated Bundle.module accessor aborts the process on first touch.
if [ -d "$BIN/${APP_NAME}_StickyDeck.bundle" ]; then
    cp -R "$BIN/${APP_NAME}_StickyDeck.bundle" "$APP/Contents/Resources/"
fi

# Release builds export STICKYDECK_SIGN_IDENTITY (a Developer ID Application
# identity) so the result can be notarized; the hardened runtime and a secure
# timestamp are both required for that and cannot be added afterwards. Without
# it we ad-hoc sign, which runs fine locally and in CI but will not pass
# Gatekeeper on anyone else's Mac.
if [ -n "${STICKYDECK_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$STICKYDECK_SIGN_IDENTITY" \
        --entitlements scripts/StickyDeck.entitlements \
        "$APP"
else
    codesign --force --sign - \
        --entitlements scripts/StickyDeck.entitlements \
        "$APP"
fi

echo "Built $APP"
