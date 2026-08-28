#!/bin/bash
# Drive this Claude session's Terminal window border (see ~/.hammerspoon/init.lua).
#   paint  - claim the window in this session's /color, solid
#   blink  - Claude is waiting for input
#   solid  - Claude is working
#   clear  - release the window
# Never fails a turn: every path exits 0.
set -u
MODE="${1:-solid}"
payload="$(cat 2>/dev/null || true)"

# The hook runs as a descendant of the claude process; walk up to its tty.
pid=$$; tty=""
for _ in 1 2 3 4 5 6 7 8; do
  t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ -n "$t" ] && [ "$t" != "??" ]; then tty="/dev/$t"; break; fi
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -z "$pid" ] || [ "$pid" = "1" ] && break
done
[ -z "$tty" ] && exit 0

if [ "$MODE" = "clear" ]; then
  open -g "hammerspoon://border?tty=${tty}&color=off" 2>/dev/null
  exit 0
fi

# /color lives in the session transcript, not in settings.
transcript="$(printf '%s' "$payload" | /usr/bin/python3 -c \
  'import sys,json
try: print(json.load(sys.stdin).get("transcript_path",""))
except Exception: print("")' 2>/dev/null)"

color=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  color="$(grep -o '"agentColor":"[a-z]*"' "$transcript" 2>/dev/null \
           | tail -1 | sed 's/.*:"//;s/"//')"
fi
case "$color" in default|reset|none|gray|grey|"") color="cyan" ;; esac

if [ "$MODE" = "paint" ]; then
  open -g "hammerspoon://border?tty=${tty}&color=${color}&mode=solid" 2>/dev/null
else
  # Repaint rather than flip mode: self-heals a window that was never claimed
  # (Hammerspoon restart, session predating the hook) and picks up /color changes.
  open -g "hammerspoon://border?tty=${tty}&color=${color}&mode=${MODE}" 2>/dev/null
fi
exit 0
