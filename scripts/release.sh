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

# Never ship the throwaway development signing key — anyone could mint Pro
# licenses with its (exposed) private half. See docs/PRE-RELEASE-CHECKLIST.md.
DEV_KEY='fU82foP+k9x5MzK4CJ104ImU1WhNZ7oxrOAdrXZIgm8='
if grep -q "$DEV_KEY" Sources/Gatecaster/License.swift; then
  if [ "${ALLOW_DEV_KEY:-0}" != 1 ]; then
    echo "✖ Refusing to release: License.swift still uses the DEV signing key."
    echo "  Regenerate it first:  swift scripts/gen-keypair.swift"
    echo "  (paste the new public key into License.swift; keep the private key offline)"
    echo "  Override, NOT recommended:  ALLOW_DEV_KEY=1 scripts/release.sh"
    exit 1
  fi
  echo "⚠ ALLOW_DEV_KEY=1 — releasing with the DEV key anyway. You were warned."
fi

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
