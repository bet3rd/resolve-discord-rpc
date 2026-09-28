#!/bin/sh
# Removes the launch agent and installed files. Keeps config.json unless
# --purge is given.
set -eu

LABEL="io.github.bet3rd.resolve-discord-rpc"
INSTALL_DIR="$HOME/Library/Application Support/resolve-discord-rpc"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$INSTALL_DIR/resolve-rpc.pl" "$INSTALL_DIR/collector.lua" "$INSTALL_DIR/resolve-rpc.log"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$INSTALL_DIR"
fi

echo "Uninstalled."
