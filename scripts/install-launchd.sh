#!/bin/bash
# Installs Aiguillage as a root LaunchDaemon: starts at boot/login with no password prompt,
# auto-recovers on crash. One sudo needed (this script). Stop cleanly from the menu bar; to
# remove the service entirely, run scripts/uninstall-launchd.sh.
set -euo pipefail

LABEL="com.qdequelen.aiguillage"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
BIN="/usr/local/bin/aiguillage"
LOG="/var/log/aiguillage.log"

[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash scripts/install-launchd.sh"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.build/release/aiguillage"
[ -x "$SRC" ] || SRC="/Applications/Aiguillage.app/Contents/MacOS/aiguillage"
[ -x "$SRC" ] || { echo "daemon binary not found — run 'swift build -c release' or scripts/make-dmg.sh first"; exit 1; }

# Stop any running (menu-started) instance so launchd can own the tunnel, and unload a prior service.
if pgrep -f '/aiguillage up' >/dev/null 2>&1; then
  echo "stopping existing instance…"
  pkill -INT -f '/aiguillage up' 2>/dev/null || true
  sleep 2
fi
launchctl bootout system "$PLIST" 2>/dev/null || true

install -d -m 0755 /usr/local/bin
install -m 0755 "$SRC" "$BIN"
echo "installed daemon -> $BIN"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>up</string>
  </array>
  <key>RunAtLoad</key><true/>
  <!-- Restart only on an abnormal exit (crash): a clean stop from the menu bar stays stopped. -->
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
echo "wrote $PLIST"

launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL" 2>/dev/null || true
sleep 2

echo "---"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  launchctl print "system/$LABEL" | grep -E '^\s*(state|pid) ' | head -2 || true
fi
echo "done. Service starts automatically at boot/login. Log: $LOG"
echo "Stop it from the menu bar (stays stopped); uninstall with scripts/uninstall-launchd.sh."
