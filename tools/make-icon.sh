#!/bin/sh
# Regenerates Resources/Clippa.icns and Resources/icon.png from the drawing
# in tools/draw-icon.swift. Only needed when the drawing changes;
# then run: sh build.sh --install
set -eu
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
swift tools/draw-icon.swift "$TMP/icon.png"
mkdir "$TMP/Clippa.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon.png" --out "$TMP/Clippa.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$TMP/icon.png" --out "$TMP/Clippa.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/Clippa.iconset" -o Resources/Clippa.icns
cp "$TMP/icon.png" Resources/icon.png
rm -rf "$TMP"
echo "Created Resources/Clippa.icns"
