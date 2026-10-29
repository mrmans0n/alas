#!/bin/zsh
# Installs the Alas VM Guest helper in this VM: copies it to /Applications, runs it at login
# through a LaunchAgent, and opens the Accessibility settings to grant it.
# Safe to run again: it replaces the app and reloads the agent.
set -euo pipefail

label="io.nlopez.vmguest"
source_app="$(cd "$(dirname "$0")" && pwd)/Alas VM Guest.app"
target_app="/Applications/Alas VM Guest.app"
agent_plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

if [[ ! -d "$source_app" ]]; then
  echo "error: Alas VM Guest.app isn't next to this script" >&2
  exit 1
fi

# Stop the running copy before replacing it.
launchctl bootout "$domain/$label" 2>/dev/null || true

echo "==> Copying the helper to /Applications"
rm -rf "$target_app"
ditto "$source_app" "$target_app"
xattr -dr com.apple.quarantine "$target_app" 2>/dev/null || true

echo "==> Writing $agent_plist"
mkdir -p "$(dirname "$agent_plist")"
cat > "$agent_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$target_app/Contents/MacOS/Alas VM Guest</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

echo "==> Starting the helper"
launchctl bootstrap "$domain" "$agent_plist"

echo "==> Grant Accessibility and Screen Recording to Alas VM Guest"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
