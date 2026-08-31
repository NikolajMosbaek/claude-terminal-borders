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

# /color lives in the session transcript, not in settings. One python does both
# jobs: extract the transcript path from the hook payload and URL-encode it.
out="$(printf '%s' "$payload" | /usr/bin/python3 -c \
  'import sys, json, urllib.parse
try: t = json.load(sys.stdin).get("transcript_path", "") or ""
except Exception: t = ""
print(t)
print(urllib.parse.quote(t, safe=""))' 2>/dev/null)"
transcript="$(printf '%s' "$out" | sed -n 1p)"
enc="$(printf '%s' "$out" | sed -n 2p)"

color=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  color="$(grep -o '"agentColor":"[a-z]*"' "$transcript" 2>/dev/null \
           | tail -1 | sed 's/.*:"//;s/"//')"
fi
# "unknown" resolves to no colour in the Spoon: the window is claimed and its
# transcript watched, but nothing is drawn until /color is run. Never fall back
# to one of the eight real colours -- that turns "no colour" into "wrong colour".
case "$color" in default|reset|none|gray|grey|"") color="unknown" ;; esac

url="hammerspoon://border?tty=${tty}&color=${color}"
[ "$MODE" = "paint" ] && url="${url}&mode=solid" || url="${url}&mode=${MODE}"
[ -n "$enc" ] && url="${url}&transcript=${enc}"
open -g "$url" 2>/dev/null
exit 0
