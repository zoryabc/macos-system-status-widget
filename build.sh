#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

HOST_ARCH="$(uname -m)"
ARCHS="${SYSTEMWIDGET_ARCHS:-arm64 x86_64}"
BUILD_DIR="build"
APP_NAME="SystemWidget.app"
APP_DIR="$BUILD_DIR/$APP_NAME"

echo "==> 构建 $APP_NAME ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

BIN="$APP_DIR/Contents/MacOS/SystemWidget"
app_binaries=()
for arch in $ARCHS; do
  case "$arch" in
    arm64|x86_64) ;;
    *) echo "不支持的架构: $arch" >&2; exit 1 ;;
  esac
  slice="$BUILD_DIR/SystemWidget-$arch"
  xcrun swiftc -swift-version 6 -O -parse-as-library \
    -target "${arch}-apple-macosx15.0" \
    Sources/Stats.swift Sources/WidgetPanel.swift Sources/AppEntry.swift \
    -o "$slice"
  app_binaries+=("$slice")
done
xcrun lipo -create "${app_binaries[@]}" -output "$BIN"
rm -f "${app_binaries[@]}"

cp Info.plist "$APP_DIR/Contents/Info.plist"
cp assets/SystemWidget.icns "$APP_DIR/Contents/Resources/SystemWidget.icns"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 构建命令行验证工具 statscli ..."
mkdir -p "$BUILD_DIR"
xcrun swiftc -swift-version 6 -O -target "${HOST_ARCH}-apple-macosx15.0" \
  Sources/Stats.swift Sources/main.swift \
  -o "$BUILD_DIR/statscli"

echo
echo "完成！"
echo "  小组件:   open \"$APP_DIR\""
echo "  数据预览: \"$BUILD_DIR/statscli\""
