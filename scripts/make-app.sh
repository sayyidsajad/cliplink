#!/bin/bash
# Builds a release Swift package and assembles a proper ClipLink.app bundle.
# Usage: scripts/make-app.sh [path/to/ClipLink.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/build/ClipLink.app}"
APP_NAME="ClipLink"
VERSION="0.3.1"

# 1. Release build
swift build -c release --package-path "$ROOT/macapp" 2>&1 | sed 's/^/  /'
BIN="$ROOT/macapp/.build/release/ClipLink"
[ -f "$BIN" ] || { echo "release binary not found at $BIN"; exit 1; }

# 2. Icon
ICONS_DIR="$ROOT/scripts/resources"
mkdir -p "$ICONS_DIR"
if [ ! -f "$ICONS_DIR/AppIcon.icns" ]; then
    swift "$ROOT/scripts/make-icon.swift" "$ICONS_DIR/AppIcon.icns"
fi

# 3. Bundle layout
rm -rf "$DEST" "$DEST.tmp"
mkdir -p "$DEST.tmp/Contents/MacOS" "$DEST.tmp/Contents/Resources"
cp "$BIN" "$DEST.tmp/Contents/MacOS/$APP_NAME"
cp "$ICONS_DIR/AppIcon.icns" "$DEST.tmp/Contents/Resources/"

cat > "$DEST.tmp/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClipLink</string>
    <key>CFBundleDisplayName</key><string>ClipLink</string>
    <key>CFBundleIdentifier</key><string>app.cliplink.ClipLink</string>
    <key>CFBundleExecutable</key><string>ClipLink</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleMinimumSystemVersion</key><string>13.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License — see LICENSE</string>
</dict>
</plist>
EOF

mv "$DEST.tmp" "$DEST"

# 4. Ad-hoc sign so macOS considers the bundle coherent.
#    (NOT a Developer-ID signature: users still get a Gatekeeper warning for
#     downloaded builds — documented in README.)
codesign --force --deep -s - "$DEST" 2>/dev/null || echo "codesign failed (ad-hoc only, continuing)"

echo "App bundle: $DEST"
