#!/bin/bash
# Produces build/ClipLink.dmg containing ClipLink.app and an Applications
# symlink (drag-to-install). Uses only free macOS tooling (hdiutil).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG_DIR="$ROOT/build/dmg"
OUT="$ROOT/build/ClipLink-$1.dmg"
VERSION="${1:-0.1.0}"

bash "$ROOT/scripts/make-app.sh" "$ROOT/build/ClipLink.app"

rm -rf "$DMG_DIR" "$OUT"
mkdir -p "$DMG_DIR"
cp -R "$ROOT/build/ClipLink.app" "$DMG_DIR/"
cp "$ROOT/LICENSE" "$DMG_DIR/LICENSE.txt" 2>/dev/null || true
cp "$ROOT/README.md" "$DMG_DIR/README.txt"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create -volname "ClipLink $VERSION" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$OUT"

echo "DMG written to $OUT"
