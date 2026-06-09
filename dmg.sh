#!/usr/bin/env bash
# Ship FastCleanup end-to-end:  build → Developer ID sign → DMG → notarize → staple → verify
#
# Credentials for notarization come from an env file (gitignored) or the environment.
# Point SHIP_ENV at a file that exports either:
#   Apple ID:  APPLE_ID, APPLE_PASSWORD (app-specific password), APPLE_TEAM_ID
#   …or key:   APPLE_API_KEY_PATH (.p8), APPLE_API_KEY (Key ID), APPLE_API_ISSUER
#   Optional:  APPLE_SIGNING_IDENTITY (else first "Developer ID Application" is used)
#
#   SHIP_ENV defaults to scripts/.ship.env. To reuse another project's creds without
#   copying secrets, e.g.:  SHIP_ENV=~/projects/gitui/scripts/.ship.env ./dmg.sh
#
# Without notarization creds it still builds + signs (just not notarized).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FastCleanup"
VERSION="${VERSION:-1.0}"
APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME-$VERSION.dmg"
STAGE="dist/dmg-stage"

# --- load gitignored credentials if present ---
SHIP_ENV="${SHIP_ENV:-scripts/.ship.env}"
if [ -f "$SHIP_ENV" ]; then
  echo "▶ Loading credentials from $SHIP_ENV"
  set -a; . "$SHIP_ENV"; set +a
fi

# --- resolve signing identity (prefer Developer ID Application) ---
if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
  APPLE_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')
fi
[ -n "${APPLE_SIGNING_IDENTITY:-}" ] || { echo "✖ No Developer ID Application identity found." >&2; exit 1; }
echo "▶ Signing identity: $APPLE_SIGNING_IDENTITY"

# --- decide notarization method ---
NOTARGS=()
if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
  NOTARGS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")
  echo "▶ Notarization: App Store Connect API key"
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  NOTARGS=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
  echo "▶ Notarization: Apple ID ($APPLE_ID)"
else
  echo "⚠ No notarization credentials — DMG will be SIGNED but NOT notarized."
fi

# 1. Build + sign the app.
echo "▶ Building + signing app…"
SIGN_ID="$APPLE_SIGNING_IDENTITY" ./build.sh >/dev/null
echo "  ✓ $APP"

# 2. Stage app + drag-to-Applications symlink, then build a compressed DMG.
echo "▶ Creating $DMG …"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 3. Sign the DMG itself.
echo "▶ Signing DMG…"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

# 4. Notarize + staple.
if [ "${#NOTARGS[@]}" -gt 0 ]; then
  echo "▶ Submitting to Apple notary service (waits for result)…"
  xcrun notarytool submit "$DMG" "${NOTARGS[@]}" --wait
  echo "▶ Stapling ticket…"
  xcrun stapler staple "$DMG"
fi

# 5. Verify.
echo ""
echo "▶ Verification:"
codesign --verify --deep --strict "$APP" 2>/dev/null && echo "  ✓ codesign valid ($APPLE_SIGNING_IDENTITY)"
if [ "${#NOTARGS[@]}" -gt 0 ]; then
  xcrun stapler validate "$DMG" >/dev/null 2>&1 && echo "  ✓ notarization ticket stapled"
  spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  spctl: /' || true
fi

echo ""
if [ "${#NOTARGS[@]}" -gt 0 ]; then
  echo "✅ Shipped (signed + notarized + stapled — runs warning-free on any Mac):"
else
  echo "✅ Built + signed (NOT notarized — right-click → Open on other Macs):"
fi
echo "   $DMG"
ls -lh "$DMG"
