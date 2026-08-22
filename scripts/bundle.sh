#!/bin/bash
# 把 SwiftPM 产物组装成一个可双击的 .app。
#
# 本机只有 Command Line Tools 没有完整 Xcode，用不了 xcodebuild，
# 所以 bundle 手工拼。菜单栏应用需要的就是一个 Info.plist（LSUIElement=1
# 让它不出现在 Dock 里）加一个可执行文件。
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AI Usage Bar"
BUNDLE_ID="dev.popring.ai-usage-bar"
VERSION="0.4.0"
OUT="${1:-build}"
APP="$OUT/$APP_NAME.app"

echo "==> 编译 release"
swift build -c release

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIUsageBar "$APP/Contents/MacOS/AIUsageBar"

# 图标：从 docs/ 的 PNG 现场生成 .icns（sips/iconutil 都是系统自带）。
ICON_SRC="docs/ai-usage-bar-icon.png"
if [ -f "$ICON_SRC" ]; then
    echo "==> 生成图标"
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
    <!-- 菜单栏应用：不进 Dock、不进 Cmd-Tab -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# 本地自签，省得每次打开都被 Gatekeeper 拦。
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (自签跳过，不影响本机运行)"

echo "==> 好了：$APP"
echo "   试运行：open '$APP'"
echo "   装到应用目录：cp -R '$APP' ~/Applications/"
