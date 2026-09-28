#!/bin/sh
# Installs the Discord presence for DaVinci Resolve as a per-user launch agent.
# It starts at login, sleeps while Resolve is closed, and shows your activity
# on Discord whenever Resolve is open.
set -eu

LABEL="io.github.bet3rd.resolve-discord-rpc"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/resolve-discord-rpc"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

FUSCRIPT="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"

if [ ! -x "$FUSCRIPT" ]; then
  echo "DaVinci Resolve not found at /Applications/DaVinci Resolve" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents"

# Remove files from the older Perl-based version.
rm -f "$INSTALL_DIR/resolve-rpc.pl" "$INSTALL_DIR/collector.lua" "$INSTALL_DIR/resolve-rpc.log"
cp "$SOURCE_DIR/presence.lua" "$SOURCE_DIR/discord_ipc.lua" "$INSTALL_DIR/"

if [ ! -f "$INSTALL_DIR/config.json" ]; then
  cp "$SOURCE_DIR/config.example.json" "$INSTALL_DIR/config.json"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$FUSCRIPT</string>
    <string>-l</string>
    <string>lua</string>
    <string>$INSTALL_DIR/presence.lua</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/presence.log</string>
</dict>
</plist>
EOF

# Restart it if an older version is already loaded.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed. Settings: $INSTALL_DIR/config.json"
echo "Log: $INSTALL_DIR/presence.log"
