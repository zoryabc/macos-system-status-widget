#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
BUILD_DIR="build"
APP_NAME="SystemWidget.app"
APP_DIR="$BUILD_DIR/$APP_NAME"

echo "==> 构建 $APP_NAME ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

xcrun swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macosx15.0" \
  Sources/Stats.swift Sources/AppEntry.swift \
  -o "$APP_DIR/Contents/MacOS/SystemWidget"

cp Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 构建命令行验证工具 statscli ..."
mkdir -p "$BUILD_DIR"
xcrun swiftc -O Sources/Stats.swift Sources/main.swift \
  -o "$BUILD_DIR/statscli"

echo
echo "完成！"
echo "  小组件:   open \"$APP_DIR\""
echo "  数据预览: \"$BUILD_DIR/statscli\""
