#!/bin/bash
# Install the Conductor companion server as a login LaunchAgent (auto-restart, survives reboots).
# Usage: ./install.sh        Uninstall: ./install.sh --uninstall
set -euo pipefail

LABEL="co.bungy.conductor-companion"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/.conductor-companion"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled."
  exit 0
fi

command -v bun >/dev/null || { echo "Bun not found — installing…"; curl -fsSL https://bun.sh/install | bash; }
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Running via `curl | bash` (no server.ts beside this script)? Download it.
if [[ ! -f "$DIR/server.ts" ]]; then
  DIR="$LOG_DIR"
  echo "Downloading server.ts…"
  curl -fsSL "https://raw.githubusercontent.com/MRL-00/conductor-mobile/main/server/server.ts" -o "$DIR/server.ts"
fi

# caffeinate -s keeps the Mac awake (on AC power) so agents can run while you're away
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-s</string>
    <string>$BUN</string>
    <string>run</string>
    <string>$DIR/server.ts</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/server.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/server.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
: > "$LOG_DIR/server.log"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 3
echo "Installed and running. Logs: $LOG_DIR/server.log"
cat "$LOG_DIR/server.log"   # address, token, and pairing QR (scan with the iPhone camera)
