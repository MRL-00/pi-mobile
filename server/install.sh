#!/bin/bash
# Install the Pi companion server as a login LaunchAgent (auto-restart, survives reboots).
# Usage: ./install.sh        Uninstall: ./install.sh --uninstall
set -euo pipefail

LABEL="co.bungy.pi-companion"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/.pi-companion"
# LaunchAgents don't inherit your shell PATH — include where bun/pi usually live.
AGENT_PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled."
  exit 0
fi

command -v bun >/dev/null || { echo "Bun not found — installing…"; curl -fsSL https://bun.sh/install | bash; }
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Always install into ~/.pi-companion so LaunchAgent has a stable path, and so
# checkout updates (server.ts + approval extension) are picked up on reinstall.
if [[ -f "$DIR/server.ts" ]]; then
  cp "$DIR/server.ts" "$LOG_DIR/server.ts"
  if [[ -d "$DIR/pi-mobile-approval" ]]; then
    rm -rf "$LOG_DIR/pi-mobile-approval"
    cp -R "$DIR/pi-mobile-approval" "$LOG_DIR/pi-mobile-approval"
  fi
else
  echo "Downloading server.ts…"
  curl -fsSL "https://raw.githubusercontent.com/MRL-00/pi-mobile/main/server/server.ts" -o "$LOG_DIR/server.ts"
fi
DIR="$LOG_DIR"

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
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$AGENT_PATH</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/server.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/server.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
: > "$LOG_DIR/server.log"
: > "$LOG_DIR/server.err.log"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# Wait for the server to print its pairing banner (QR + token).
for _ in $(seq 1 20); do
  if grep -q "Auth token:" "$LOG_DIR/server.log" 2>/dev/null; then break; fi
  if grep -q "listening on" "$LOG_DIR/server.log" 2>/dev/null; then break; fi
  sleep 0.5
done

echo "Installed and running. Logs: $LOG_DIR/server.log"
if [[ -s "$LOG_DIR/server.log" ]]; then
  cat "$LOG_DIR/server.log"
else
  echo
  echo "Server didn't print a banner yet — check $LOG_DIR/server.err.log"
  if [[ -f "$LOG_DIR/token" ]]; then
    HOST="$(scutil --get LocalHostName 2>/dev/null || hostname | sed 's/\.local$//')"
    echo
    echo "Pair manually in the iPhone app Settings:"
    echo "  Server address:  http://${HOST}.local:8940"
    echo "  Auth token:      $(cat "$LOG_DIR/token")"
  fi
fi
