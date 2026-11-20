#!/usr/bin/env bash
# Builds the agent, wraps it in a small .app bundle and registers a LaunchAgent
# so it starts automatically at login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="io.github.kesginfurkan.copy-memory"
APP="$HOME/Applications/CopyMemory.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/copy-memory-agent.log"

: "${COPY_MEMORY_API:=http://127.0.0.1:5050}"
: "${COPY_MEMORY_HOTKEY:=cmd+shift+v}"
: "${COPY_MEMORY_AUTO_PASTE:=1}"
: "${COPY_MEMORY_IGNORE_APPS:=}"

echo "▸ building (release)"
(cd "$ROOT/agent" && swift build -c release -q)

echo "▸ installing $APP"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/agent/.build/release/copy-memory-agent" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>CopyMemory</string>
  <key>CFBundleExecutable</key><string>copy-memory-agent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLISTEOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "▸ registering LaunchAgent $LABEL"
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/copy-memory-agent</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>COPY_MEMORY_API</key><string>$COPY_MEMORY_API</string>
    <key>COPY_MEMORY_HOTKEY</key><string>$COPY_MEMORY_HOTKEY</string>
    <key>COPY_MEMORY_AUTO_PASTE</key><string>$COPY_MEMORY_AUTO_PASTE</string>
    <key>COPY_MEMORY_IGNORE_APPS</key><string>$COPY_MEMORY_IGNORE_APPS</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLISTEOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ agent running (hotkey: $COPY_MEMORY_HOTKEY, log: $LOG)"
