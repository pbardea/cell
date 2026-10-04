#!/bin/bash
set -euo pipefail

NAME="Cell"
BUNDLE_ID="com.pbardea.cell"
VERSION="${VERSION:-1.0.0}"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$NAME.app"
SRC="$(cd "$(dirname "$0")" && pwd)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Cell reads the battery level your Bluetooth device reports over GATT.</string>
</dict>
</plist>
PLIST

swiftc -O -target arm64-apple-macos13.0 \
    -framework AppKit -framework CoreBluetooth -framework ServiceManagement \
    "$SRC/Sources/main.swift" -o "$APP/Contents/MacOS/$NAME"

# Stable ad-hoc signature so macOS keeps the granted Bluetooth permission
# across rebuilds instead of re-prompting every time.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "Built $APP"
