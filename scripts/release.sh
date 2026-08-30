#!/bin/bash
# Builds, signs, notarizes and staples a distributable Aside.app, then leaves a
# zip ready to attach to a GitHub release.
#
#   export ASIDE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   scripts/release.sh
#
# Requires a notarytool credential profile (default name: aside-notary), made
# once with `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASIDE_SIGN_IDENTITY:?Set ASIDE_SIGN_IDENTITY to your Developer ID Application identity}"
PROFILE="${ASIDE_NOTARY_PROFILE:-aside-notary}"
OUT_DIR="${1:-build}"
APP="$OUT_DIR/Aside.app"
ZIP="$OUT_DIR/Aside.zip"

echo "==> Building and signing as: $ASIDE_SIGN_IDENTITY"
ASIDE_SIGN_IDENTITY="$ASIDE_SIGN_IDENTITY" scripts/make_app.sh "$OUT_DIR"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Submitting for notarization (this usually takes a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The ticket attaches to the .app, so the archive people actually download has
# to be built *after* stapling. Shipping the submission zip is the classic way
# to publish a build that still fails on someone else's Mac.
echo "==> Repackaging the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Verifying as an unfamiliar Mac would see it"
spctl --assess --type execute -vv "$APP"

echo
echo "Ready to upload: $ZIP"
