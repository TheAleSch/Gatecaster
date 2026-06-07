#!/bin/bash
# Sign, notarize, and package Gatecaster for distribution.
#
# One-time setup:
#   1. Xcode → Settings → Accounts: ensure your Developer ID certificate exists
#      (Certificates → "Developer ID Application").
#   2. Store notary credentials once:
#        xcrun notarytool store-credentials gatecaster \
#          --apple-id YOU@example.com --team-id TEAMID
#
# Usage:
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=gatecaster \
#   scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IDENTITY:?Set IDENTITY='Developer ID Application: Name (TEAMID)'}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE=<notarytool keychain profile>}"

scripts/make-app.sh
APP=dist/Gatecaster.app
DMG=dist/Gatecaster.dmg

echo "▸ codesign (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ packaging DMG"
rm -f "$DMG"
hdiutil create -volname Gatecaster -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "▸ notarizing (waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ stapling"
xcrun stapler staple "$DMG"

echo "✓ release ready: $DMG"
