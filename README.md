# claude-terminal-borders

Per-session coloured borders around macOS **Terminal.app** windows, so several
concurrent [Claude Code](https://claude.com/claude-code) sessions are
distinguishable at a glance — and so you can see which one is waiting for you.

Each window is claimed by its tty, coloured from that session's `/color`, and
**blinks while Claude is waiting for input**. Focus the window and the blink stops.

## Why not just `/color`?

`/color` tints Claude Code's own UI *inside* the pane. It tells you nothing when
you are looking at a screen full of terminal windows, or at another app. This
puts the same colour on the window itself.

## Requirements

- macOS 14+
- **Terminal.app** — iTerm2, Ghostty, kitty and WezTerm are not supported (the
  tty→window lookup is Terminal-specific AppleScript)
- [Hammerspoon](https://www.hammerspoon.org) — `brew install --cask hammerspoon`
- Claude Code

## Install

```bash
git clone https://github.com/NikolajMosbaek/claude-terminal-borders.git
cd claude-terminal-borders
./install.sh
```

Add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("ClaudeBorder"):start()
```

Merge `examples/claude-code-hooks.json` into the `hooks` object of
`~/.claude/settings.json`. Reload Hammerspoon, then start a **new** Claude Code
session — hooks are read at session start, so existing sessions won't pick it up.

### Permissions

Hammerspoon needs two grants, both prompted on first use:

1. **Accessibility** — reads window frames. Restart Hammerspoon after granting;
   it does not pick the grant up live.
2. **Automation → Terminal** — asks Terminal which window owns a tty.

## How it works

| Claude Code hook | Border |
|---|---|
| `SessionStart` | claims the window in the session's `/color`, solid |
| `UserPromptSubmit` | solid — Claude is working |
| `Stop` | **blink** — Claude is waiting for you |
| `Notification` | **blink** — permission prompt mid-turn |
| `SessionEnd` | cleared |

The hook resolves its own tty by walking up the process tree, reads the last
`{"type":"agent-color","agentColor":"…"}` record from the session transcript
(`/color` is stored there, not in settings), and pokes Hammerspoon over a
`hammerspoon://border?…` URL.

`/color` is a built-in command and fires no hook, so the hook alone would only
pick up a colour change on your next submitted prompt. The Spoon therefore also
watches the session transcript directly (`hs.pathwatcher`, debounced, reading
only the tail) and recolours within about a second of the command.

A session that has not run `/color` gets **no border at all**. The window is
still tracked and its transcript still watched, so the border appears the moment
you run `/color`, and disappears again on `/color default`.

```
tty → claude pid → ~/.claude/sessions/<pid>.json → sessionId → transcript → /color
```

## Known limitations

**Borders float above other windows.** `hs.canvas` has no window level between
"behind my own window" and "above everything" — at `normal` level the border
disappears behind the terminal's own window surface. The workaround is
`autoHide`: borders are shown only while Terminal is the active application, so
a border over another app's window is hidden exactly when that app is in use.
Disable with `spoon.ClaudeBorder:setAutoHide(false)`.

If you want *genuinely* correct stacking and don't need per-window colours,
[JankyBorders](https://github.com/FelixKratz/JankyBorders) does it properly via
private SkyLight APIs — but it has one `active_color` and one `inactive_color`
for every window on the system.

**A Hammerspoon restart leaves existing windows bare** until each session's next
turn, since `SessionStart` only fires for new sessions.

**Windows are matched by bounds, not title.** Concurrent Claude windows routinely
share a byte-identical title, so title matching collapses them onto one window.
Two windows at the same origin (within 8pt) will still be confused.

## Configuration

Set before `:start()`:

```lua
local cb = hs.loadSpoon("ClaudeBorder")
cb.width         = 5        -- border thickness
cb.radius        = 11       -- corner radius
cb.blinkInterval = 0.55     -- seconds per blink phase
cb.dimAlpha      = 0.12     -- raise for a gentler pulse
cb.autoHide      = true     -- show only while Terminal is frontmost
cb.colors.green  = "#32d74b"
cb:start()
```

## Manual control

With the `hs` CLI (`brew install --cask hammerspoon` links it):

```bash
hs -c 'spoon.ClaudeBorder:paint("/dev/ttys001", "green")'
hs -c 'spoon.ClaudeBorder:paint("/dev/ttys001", "#ff00ff", "blink")'
hs -c 'spoon.ClaudeBorder:mode("/dev/ttys001", "solid")'
hs -c 'spoon.ClaudeBorder:list()'
hs -c 'spoon.ClaudeBorder:clearAll()'
```

Or over the URL bridge, which needs no CLI:

```bash
open -g "hammerspoon://border?tty=/dev/ttys001&color=green&mode=blink"
open -g "hammerspoon://border?tty=/dev/ttys001&color=off"
```

## Troubleshooting

**Nothing appears.** Check `hs -c 'hs.accessibilityState()'` returns `true`;
restart Hammerspoon after granting. Then check the Hammerspoon console for a
config error — one bad line aborts the rest of the file, including the URL bridge.

**Borders don't follow windows.** `hs.window.filter.windowResized` does not
exist; passing it to `subscribe` throws `missing event(s)` and silently kills
every subscription below it. `windowMoved` already covers resizes.

**Stack overflow in the console.** Something is calling `canvas:show()` from
inside a window-event handler, which re-triggers window events. Show/hide belongs
on the `hs.application.watcher` channel instead.

## Licence

MIT
