#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="build/SystemWidget.app"
APP_DEST="$HOME/Applications/SystemWidget.app"
PLIST_DEST="$HOME/Library/LaunchAgents/local.systemwidget.plist"

if [ ! -d "$APP_SRC" ]; then
    echo "未找到 $APP_SRC，请先运行 ./build.sh"
    exit 1
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

pkill -x SystemWidget 2>/dev/null || true

rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"
xattr -cr "$APP_DEST" 2>/dev/null || true

cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.systemwidget</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DEST/Contents/MacOS/SystemWidget</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DEST" 2>/dev/null || launchctl load "$PLIST_DEST"

echo "已安装到: $APP_DEST"
echo "已注册开机自启: $PLIST_DEST"
open "$APP_DEST"
