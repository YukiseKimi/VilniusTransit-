#!/bin/bash
# Wraps the SwiftPM executable into a real .app bundle.
#
# `swift run` works for quick iteration, but an unbundled process gets no Info.plist,
# so it cannot activate properly, own a menu bar, or carry entitlements. MapKit and
# MenuBarExtra both want a bundle.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product VilniusTransitApp
BIN="$(swift build -c "$CONFIG" --product VilniusTransitApp --show-bin-path)"

APP="$ROOT/build/VilniusTransit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/VilniusTransitApp" "$APP/Contents/MacOS/VilniusTransit"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vilnius Transit</string>
    <key>CFBundleDisplayName</key><string>Vilnius Transit</string>
    <key>CFBundleIdentifier</key><string>lt.vilnius.transit.spike</string>
    <key>CFBundleExecutable</key><string>VilniusTransit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>Transit data © Vilniaus miesto savivaldybė / stops.lt</string>
</dict>
</plist>
PLIST

# Sandboxed, network-client only. Nothing here touches the filesystem or location.
cat > "$ROOT/build/VilniusTransit.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
ENT

codesign --force --sign - \
    --entitlements "$ROOT/build/VilniusTransit.entitlements" \
    "$APP" >/dev/null 2>&1

echo "Built $APP"
