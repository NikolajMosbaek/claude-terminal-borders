#!/bin/bash
# Install the ClaudeBorder Spoon and the Claude Code hook script.
# Does NOT edit ~/.claude/settings.json -- merge examples/claude-code-hooks.json
# yourself, so nothing of yours gets clobbered.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$HOME/.hammerspoon/Spoons" "$HOME/.claude/hooks"
rm -rf "$HOME/.hammerspoon/Spoons/ClaudeBorder.spoon"
cp -R "$here/ClaudeBorder.spoon" "$HOME/.hammerspoon/Spoons/"
cp "$here/hooks/claude-border.sh" "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/claude-border.sh"

echo "Installed:"
echo "  ~/.hammerspoon/Spoons/ClaudeBorder.spoon"
echo "  ~/.claude/hooks/claude-border.sh"
echo
echo "Add to ~/.hammerspoon/init.lua:"
echo '  require("hs.ipc")  -- keep the hs CLI alive even if a Spoon fails to load'
echo '  hs.loadSpoon("ClaudeBorder"):start()'
echo
echo "Then merge examples/claude-code-hooks.json into ~/.claude/settings.json,"
echo "reload Hammerspoon, and start a new Claude Code session."
