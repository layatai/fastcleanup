#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="FastCleanup"
BUNDLE_ID="com.fastcleanup.app"
CONFIG="release"
APP="dist/$APP_NAME.app"

# Optional universal build: ./build.sh --universal
ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling ($CONFIG ${ARCH_FLAGS[*]:-native})…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$APP_NAME"

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# App icon: regenerate if missing, then bundle it.
if [[ ! -f AppIcon.icns ]]; then
  echo "▸ Generating AppIcon.icns…"
  ./scripts/make-icns.sh
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.1</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDownloadsFolderUsageDescription</key><string>FastCleanup scans Downloads for large/old files to remove.</string>
  <key>NSDesktopFolderUsageDescription</key><string>FastCleanup scans your Desktop for large files to remove.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>FastCleanup scans Documents for large files to remove.</string>
</dict></plist>
PLIST

# Signing identity:
#   SIGN_ID="-"  (default)        → ad-hoc, runs locally only
#   SIGN_ID="Developer ID Application: NAME (TEAMID)" → distributable, hardened runtime
SIGN_ID="${SIGN_ID:--}"

if [[ "$SIGN_ID" == "-" ]]; then
  echo "▸ Code signing (ad-hoc)…"
  codesign --force --deep --sign - "$APP"
else
  echo "▸ Code signing (Developer ID, hardened runtime)…"
  codesign --force --deep --options runtime --timestamp \
           --entitlements entitlements.plist \
           --sign "$SIGN_ID" "$APP"
fi

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "✓ Built $APP"
