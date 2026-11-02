#!/bin/zsh
# Régénère les PNG et AppIcon.icns à partir de logo.svg. Usage : ./make-icon.sh
set -euo pipefail
cd "$(dirname "$0")"

swift render.swift logo.svg logo 1024 512 256

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    swift render.swift logo.svg "$ICONSET/tmp" $s $((s * 2)) >/dev/null
    mv "$ICONSET/tmp-$s.png" "$ICONSET/icon_${s}x${s}.png"
    mv "$ICONSET/tmp-$((s * 2)).png" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "✅ AppIcon.icns généré"
