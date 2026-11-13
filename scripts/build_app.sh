#!/bin/bash
# Compile lockMyMac et assemble build/lockMyMac.app.
#   CODESIGN_IDENTITY="Apple Development: …" ./scripts/build_app.sh   (signature stable, recommandé)
#   ./scripts/build_app.sh                                            (signature ad hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d Models/FaceEmbedding.mlmodelc ] || { echo "Modèle absent : lancez d'abord ./scripts/build_model.sh" >&2; exit 1; }
swift build -c release
APP=build/lockMyMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/LockMyMac" "$APP/Contents/MacOS/lockMyMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Models/FaceEmbedding.mlmodelc "$APP/Contents/Resources/"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Application prête : $APP"
