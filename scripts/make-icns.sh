#!/usr/bin/env bash
# Generates AppIcon.icns from the programmatic artwork in AppIcon.swift.
# Requires only the macOS toolchain (swift, sips, iconutil).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="$(mktemp -d)/icon-1024.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
OUT="AppIcon.icns"

echo "▸ Rendering 1024×1024 artwork…"
swift scripts/AppIcon.swift "$SRC"

echo "▸ Building iconset…"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
# Retina (@2x) variants expected by iconutil.
cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"

echo "▸ Packing ${OUT}…"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ Wrote ${OUT}"
