#!/bin/bash
# Assemble the SwiftPM build products into a double-clickable .app.
#
# This machine only has Command Line Tools, not full Xcode, so xcodebuild is
# unavailable and the bundle is assembled by hand. A menu bar app only needs an
# Info.plist (LSUIElement=1 keeps it out of the Dock) plus the executable.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AI Usage Bar"
BUNDLE_ID="dev.popring.ai-usage-bar"
VERSION="0.5.0"
OUT="${1:-build}"
APP="$OUT/$APP_NAME.app"

echo "==> Building release"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIUsageBar "$APP/Contents/MacOS/AIUsageBar"

# Icon: generate .icns on the fly from the PNG in docs/ (sips/iconutil ship with macOS).
ICON_SRC="docs/ai-usage-bar-icon.png"
if [ -f "$ICON_SRC" ]; then
    echo "==> Generating icon"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key>        <string>AIUsageBar</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menu bar app: no Dock icon, no Cmd-Tab entry -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# Local ad-hoc signing so Gatekeeper doesn't block every launch.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (ad-hoc signing skipped; local runs unaffected)"

echo "==> Done: $APP"
echo "   Try it: open '$APP'"
echo "   Install: cp -R '$APP' ~/Applications/"
