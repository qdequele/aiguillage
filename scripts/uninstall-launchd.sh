#!/bin/bash
# Removes the Aiguillage LaunchDaemon (stops it and deletes the plist). The daemon restores DNS
# and routes on stop. Leaves /usr/local/bin/aiguillage in place; delete it by hand to remove.
set -euo pipefail

LABEL="com.qdequelen.aiguillage"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash scripts/uninstall-launchd.sh"; exit 1; }

launchctl bootout "system/$LABEL" 2>/dev/null || launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "uninstalled launchd service."
echo "binary left at /usr/local/bin/aiguillage (rm it to remove completely)."
