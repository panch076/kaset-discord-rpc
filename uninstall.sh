#!/bin/zsh
# Stops and removes the bridge. Remove the extension in Kaset → Settings → Extensions.
LABEL="com.kaset.discord-presence"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/KasetDiscordPresence"
echo "Bridge removed. Also remove \"Kaset Discord Presence\" in Kaset → Settings → Extensions."
