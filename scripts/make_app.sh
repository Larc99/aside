#!/bin/bash
# Assembles a proper StickyDeck.app bundle from a release SPM build and
# ad-hoc signs it (sandboxed). Usage: scripts/make_app.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="StickyDeck"
BUNDLE_ID="app.stickydeck.StickyDeck"
VERSION="0.2.0"
OUT_DIR="${1:-build}"
APP="$OUT_DIR/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

mkdir -p "$APP/Contents/MacOS"
# Rebuild Resources from scratch: `cp -R` into an existing directory nests
# copies inside it, so re-runs would otherwise accumulate stale duplicates.
rm -rf "$APP/Contents/Resources"
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
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST

cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp -R Sources/StickyDeck/Resources/Fonts "$APP/Contents/Resources/Fonts"

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
