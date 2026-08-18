#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/SystemWidget.app/Contents/Info.plist)}"
APP="build/SystemWidget.app"
VOLUME="SystemWidget"
STAGING="dist/dmg-staging"
DMG_TMP="dist/${VOLUME}-${VERSION}-tmp.dmg"
DMG_OUT="dist/${VOLUME}-${VERSION}.dmg"
MOUNT_POINT="/Volumes/$VOLUME"
BG="assets/dmg-background.png"

if [ ! -d "$APP" ]; then
    echo "未找到 $APP，请先运行 ./build.sh" >&2
    exit 1
fi

if [ ! -f "$BG" ]; then
    echo "==> 生成 DMG 背景图 ..."
    mkdir -p assets
    CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/modcache}" \
        xcrun swiftc scripts/make-dmg-background.swift -o /tmp/make-dmg-background
    /tmp/make-dmg-background "$BG"
fi

echo "==> 准备 DMG 内容 ..."
rm -rf "$STAGING"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$BG" "$STAGING/.background/background.png"

echo "==> 创建 DMG ..."
rm -f "$DMG_TMP" "$DMG_OUT"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -ov -format UDRW "$DMG_TMP" >/dev/null

hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
hdiutil attach "$DMG_TMP" -mountpoint "$MOUNT_POINT" >/dev/null

echo "==> 设置窗口布局（无 Finder 时跳过） ..."
osascript <<'APPLESCRIPT' || echo "  跳过布局设置（当前环境无 Finder 会话）"
tell application "Finder"
    tell disk "SystemWidget"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 860, 620}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set background picture of viewOptions to file ".background:background.png"
        set position of item "SystemWidget.app" of container window to {130, 195}
        set position of item "Applications" of container window to {500, 195}
        close
    end tell
end tell
APPLESCRIPT

SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true
rm -rf "$MOUNT_POINT/.fseventsd"
sleep 2
hdiutil detach "$MOUNT_POINT" >/dev/null

echo "==> 压缩 DMG ..."
hdiutil convert "$DMG_TMP" -format UDZO -o "$DMG_OUT" >/dev/null
hdiutil verify "$DMG_OUT" >/dev/null
rm -f "$DMG_TMP"
rm -rf "$STAGING"

echo "完成！"
echo "  DMG: $DMG_OUT"
