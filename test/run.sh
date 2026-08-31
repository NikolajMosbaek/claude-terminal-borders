#!/bin/bash
# Run the headless test suite against the INSTALLED spoon
# (~/.hammerspoon/Spoons/ClaudeBorder.spoon) inside the live Hammerspoon.
#
# The test file is copied to /tmp first: Hammerspoon reading anything under
# ~/Documents without a Documents TCC grant freezes its main thread in an
# un-cancellable open() while tccd waits for a consent dialog. /tmp is safe.
#
# Works with the screen locked -- the AX/AppleScript layer is stubbed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v hs >/dev/null || { echo "hs CLI not found (brew install --cask hammerspoon)"; exit 1; }

cp "$here/border-test.lua" /tmp/claude-border-test.lua
out="$(hs -q -c 'return dofile("/tmp/claude-border-test.lua")')"
rm -f /tmp/claude-border-test.lua

echo "$out"
if echo "$out" | grep -qE '^(FAIL|ERROR)'; then
  echo; echo "FAILURES above."; exit 1
fi
echo; echo "All $(echo "$out" | grep -c '^PASS') checks passed."
