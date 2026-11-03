#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/dist/Office Tabs.app"
BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp/}office-tabs.XXXXXX")"
cleanup() {
    swift -e 'import Foundation; try? FileManager.default.removeItem(atPath: CommandLine.arguments[1])' "$BUILD_TMP"
}
trap cleanup EXIT

swift build --package-path "$PROJECT_ROOT" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_ROOT" -c release --show-bin-path)"

STAGED_APP="$BUILD_TMP/Office Tabs.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/OfficeTabs" "$STAGED_APP/Contents/MacOS/OfficeTabs"

# 图标按每个目标像素尺寸分别绘制，保证菜单和访达中的小尺寸图标清晰。
swift "$PROJECT_ROOT/scripts/make-icon.swift" "$BUILD_TMP/OfficeTabs.iconset"
iconutil -c icns "$BUILD_TMP/OfficeTabs.iconset" -o "$STAGED_APP/Contents/Resources/OfficeTabs.icns"

cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.jason.OfficeTabs</string>
    <key>CFBundleName</key><string>Office Tabs</string>
    <key>CFBundleDisplayName</key><string>Office Tabs</string>
    <key>CFBundleExecutable</key><string>OfficeTabs</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleIconFile</key><string>OfficeTabs.icns</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 固定 bundle 标识并校验本地签名；辅助功能授权仍由 macOS 单独管理。
codesign --force --deep --sign - --identifier local.jason.OfficeTabs "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
plutil -lint "$STAGED_APP/Contents/Info.plist"

mkdir -p "$PROJECT_ROOT/dist"
if [ -e "$APP_PATH" ]; then
    mv "$APP_PATH" "$BUILD_TMP/previous-build.app"
fi
ditto "$STAGED_APP" "$APP_PATH"
printf '\n应用已生成：%s\n' "$APP_PATH"
