#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
swift build -c release

APP="$ROOT/build/CopilotMonitor.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
mkdir -p "$MACOS"
cp "$ROOT/.build/release/CopilotMonitor" "$MACOS/CopilotMonitor"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CopilotMonitor</string>
    <key>CFBundleIdentifier</key><string>local.copilotmonitor</string>
    <key>CFBundleName</key><string>Copilot Monitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSUserNotificationsUsageDescription</key>
    <string>O Copilot Monitor avisa sobre o consumo da quota do Copilot.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Aplicativo criado em $APP"
