#!/bin/bash
# Compile AikoRoue.app
#   ./build.sh             → build/AikoRoue.app (architecture de ce Mac)
#   ./build.sh --install   → l'installe dans /Applications et la lance
#   UNIVERSAL=1 ./build.sh → binaire universel Apple Silicon + Intel (pour partager)
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Il manque les outils de développement d'Apple."
  echo "Lance : xcode-select --install   (puis relance ce script)"
  exit 1
fi

APP="build/AikoRoue.app"
BIN="$APP/Contents/MacOS/AikoRoue"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {  # $1 = arm64 | x86_64
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -target "$1-apple-macos13.0" Sources/*.swift -o "$2"
}

if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "→ Compilation universelle (arm64 + x86_64)…"
  compile arm64 build/AikoRoue-arm64
  compile x86_64 build/AikoRoue-x86_64
  lipo -create build/AikoRoue-arm64 build/AikoRoue-x86_64 -output "$BIN"
  rm build/AikoRoue-arm64 build/AikoRoue-x86_64
else
  echo "→ Compilation ($(uname -m))…"
  compile "$(uname -m)" "$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"

ICON="../assets/icon.png"
if [ -f "$ICON" ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ $APP prêt"

if [ "${1:-}" = "--install" ]; then
  pkill -x Mandarine 2>/dev/null || true
  pkill -x AikoRoue 2>/dev/null || true
  rm -rf /Applications/AikoRoue.app
  cp -R "$APP" /Applications/
  open /Applications/AikoRoue.app
  echo "✓ Installé dans /Applications et lancé (icône roue dans la barre des menus)"
fi
