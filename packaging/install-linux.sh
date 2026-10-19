#!/bin/bash
# Installe AikoRoue pour l'utilisateur courant (pas besoin de sudo)
set -e
cd "$(dirname "$0")"
DEST="$HOME/.local/share/aikoroue"
mkdir -p "$DEST" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
pkill -x AikoRoue 2>/dev/null || true
rm -rf "$DEST/app"
cp -r AikoRoue "$DEST/app"
cp AikoRoue/_internal/assets/icon-256.png "$HOME/.local/share/icons/hicolor/256x256/apps/aikoroue.png" 2>/dev/null || true
cat > "$HOME/.local/share/applications/aikoroue.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=AikoRoue
Comment=Convertir un fichier en le glissant avec Maj
Exec=$DEST/app/AikoRoue
Icon=aikoroue
Categories=Utility;
DESK
echo "✓ AikoRoue installé. Lance-le depuis ton menu d'applications (ou : $DEST/app/AikoRoue)"
if ! ldconfig -p 2>/dev/null | grep -q libxcb-cursor; then
  echo "ℹ Si l'appli ne démarre pas : sudo apt install libxcb-cursor0"
fi
nohup "$DEST/app/AikoRoue" >/dev/null 2>&1 &
