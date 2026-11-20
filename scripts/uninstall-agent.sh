#!/usr/bin/env bash
set -euo pipefail
LABEL="io.github.kesginfurkan.copy-memory"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/CopyMemory.app"
echo "✓ agent removed (history in ./data is kept)"
