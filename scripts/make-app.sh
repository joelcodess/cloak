#!/usr/bin/env bash
#
# make-app.sh — build CloakApp (release) and wrap it in a runnable Cloak.app
# bundle, ad-hoc signed. No Xcode required (Command Line Tools only).
#
#   ./scripts/make-app.sh          # build + bundle into ./Cloak.app
#   open ./Cloak.app               # launch (first run: right-click ▸ Open)

set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PKG_DIR/Cloak.app"
BUNDLE_ID="app.cloak.Cloak"
VERSION="0.1.0"

cd "$PKG_DIR"

echo "▸ swift build -c release"
swift build -c release

BIN="$PKG_DIR/.build/release/CloakApp"
[[ -x "$BIN" ]] || { echo "build did not produce $BIN" >&2; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cloak"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Cloak</string>
    <key>CFBundleDisplayName</key>     <string>Cloak</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>Cloak</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "▸ ad-hoc codesign"
codesign --force --sign - "$APP"
codesign -dvv "$APP" 2>&1 | grep -i 'Signature' || true

echo "✓ built $APP"
echo "  launch:  open \"$APP\"   (first run: right-click ▸ Open, since it's unnotarized)"
