#!/bin/zsh
# Draws Resources/AppIcon.icns from the wordmark (run tools/make-wordmark.js first if the lockup changed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/icon
cp tools/make-icon.swift build/icon/main.swift  # top-level code must live in main.swift
swiftc -O build/icon/main.swift Sources/WordmarkPaths.swift -o build/icon/make-icon
build/icon/make-icon build/icon/icon.png
I=build/icon/AppIcon.iconset; rm -rf "$I"; mkdir "$I"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon/icon.png --out "$I/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon/icon.png --out "$I/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$I" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
