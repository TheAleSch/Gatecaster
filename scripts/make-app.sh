#!/bin/bash
# Build Gatecaster.app from the SPM executable.
# Usage: scripts/make-app.sh        → dist/Gatecaster.app
set -euo pipefail
cd "$(dirname "$0")/.."

# --- pre-release reminders (see docs/PRE-RELEASE-CHECKLIST.md) ---------------
# These self-clear once you replace the dev stubs. We only WARN here so dev app
# builds keep working; release.sh turns the dev-key case into a hard block.
DEV_KEY='fU82foP+k9x5MzK4CJ104ImU1WhNZ7oxrOAdrXZIgm8='
warn_dev_key=0; warn_url=0
grep -q "$DEV_KEY" Sources/Gatecaster/License.swift && warn_dev_key=1 || true
grep -q 'https://gatecaster.app/buy' Sources/Gatecaster/main.swift && warn_url=1 || true
if [ "$warn_dev_key" = 1 ] || [ "$warn_url" = 1 ]; then
  echo "⚠️  PRE-RELEASE REMINDERS (docs/PRE-RELEASE-CHECKLIST.md):"
  [ "$warn_dev_key" = 1 ] && echo "   • License.swift still uses the DEV signing key — regenerate: swift scripts/gen-keypair.swift" || true
  [ "$warn_url" = 1 ] && echo "   • main.swift purchaseURL is still the placeholder — set your real checkout URL" || true
  echo ""
fi

APP=dist/Gatecaster.app

echo "▸ swift build (release)"
swift build -c release

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Gatecaster "$APP/Contents/MacOS/Gatecaster"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: use a prebuilt .icns if present, else build one from icon-1024.png.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [ -f Resources/icon-1024.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign with a REAL certificate when one exists: TCC keys permissions on the
# signing identity, so grants survive rebuilds. Ad-hoc (-) changes identity
# on every build and forces re-granting each time — last resort only.
#   Override: SIGN_IDENTITY="Apple Development: you@x.com (TEAM)" scripts/make-app.sh
# Select by SHA-1 hash, not name: duplicate certificates with the same
# name (common after Xcode re-issues one) make name-based signing ambiguous.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Developer ID Application|Apple Development' \
    | head -1 | awk '{print $2}')
fi
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "▸ signing as: $SIGN_IDENTITY"
  codesign --force --deep --identifier com.gatecaster.app \
    --sign "$SIGN_IDENTITY" "$APP"
else
  echo "▸ WARNING: no signing certificate found — ad-hoc signing."
  echo "  Permissions will need re-granting after every rebuild."
  codesign --force --deep --identifier com.gatecaster.app --sign - "$APP"
fi

echo "✓ $APP"
echo "  (unsigned — run it locally, or use scripts/release.sh to sign + notarize)"
