# claude-terminal-borders

Per-session coloured borders around macOS **Terminal.app** windows, so several
concurrent [Claude Code](https://claude.com/claude-code) sessions are
distinguishable at a glance — and so you can see which one is waiting for you.

Each window is claimed by its tty, coloured from that session's `/color`, and
**blinks while Claude is waiting for input**. Focus the window and the blink stops.

Borders are **occlusion-aware**: the parts covered by other windows are punched
out, so a border reads as glued to its window instead of floating over the
window stack.

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
-- hs.ipc first, so the `hs` CLI keeps working even if a Spoon fails to load.
require("hs.ipc")
hs.loadSpoon("ClaudeBorder"):start()
```

Merge `examples/claude-code-hooks.json` into the `hooks` object of
`~/.claude/settings.json`. Reload Hammerspoon, then start a **new** Claude Code
session — hooks are read at session start, so existing sessions won't pick it up.
(Sessions that are already running get their borders anyway, from the rescan —
see below — but their hooks only fire once restarted.)

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

### Occlusion

`hs.canvas` has no window level between "behind my own window" and "above
everything", so the border canvas necessarily floats over every ordinary
window. Instead of drawing on top of whatever covers its window, the Spoon
keeps each border clipped to what its window would actually show:

- Every window above a bordered window in z-order (any app, not just Terminal)
  gets **punched out** of the border with a rounded rectangle matching the
  window's corners, so the border appears to slide *under* its neighbours.
- When the occluder is another bordered terminal, the punch is inflated by the
  border width — that band belongs to the occluder's own border, and two
  coloured strokes crossing each other read as noise.
- Canvas stacking mirrors window stacking, so the frontmost window's border
  wins where two borders touch.
- A window that is minimized, on another Space, or belongs to a hidden app has
  its border hidden entirely, and gets it back the moment it is visible again.

Clipping is recomputed on window move/resize/create/destroy/focus/minimize,
app activation, Space switches, and a low-frequency safety poll for z-order
changes that fire no event (`zPollInterval`). Unchanged geometry is detected
and skipped, so the steady state costs nothing to redraw.

### Blink

`Stop` and `Notification` blink the border because Claude is waiting for you.
Focusing the window stops the blink — you have seen it. A blink requested for
the window you are **already focused on** is downgraded to solid for the same
reason (and because clicking an already-focused window fires no focus event,
nothing would ever have stopped it).

### Rescan

On start — and again on screen unlock / wake — the Spoon rebuilds borders for
Claude Code sessions that are already running, from
`~/.claude/sessions/<pid>.json` (pid → tty via `ps`, sessionId + cwd →
transcript → `/color`; `status` picks solid or blink). The rescan skips ttys
that already have a border, so it never clobbers a live one. A Hammerspoon
restart therefore no longer leaves existing windows bare.

The unlock rescan matters more than it looks: a **locked screen degrades the
macOS Accessibility API system-wide** (windows enumerate but report no frames),
so any border work attempted while locked fails. Everything heals on unlock.

## Known limitations

**Windows are matched by bounds, not title.** Concurrent Claude windows routinely
share a byte-identical title, so title matching collapses them onto one window.
Two windows at the same origin (within 8pt) will still be confused.

**Punches are geometric, not pixel-perfect.** The punch uses the occluder's
frame with the standard macOS corner radius; a window with an unusual shape
(or a sheet hanging outside its parent's frame) can leave a sliver of border
visible where it shouldn't be.

If you want *genuinely* correct stacking without any clipping,
[JankyBorders](https://github.com/FelixKratz/JankyBorders) does it via private
SkyLight APIs — but it has one `active_color` and one `inactive_color` for
every window on the system.

## Configuration

Set before `:start()`:

```lua
local cb = hs.loadSpoon("ClaudeBorder")
cb.width         = 5        -- border thickness
cb.radius        = 11       -- corner radius
cb.blinkInterval = 0.55     -- seconds per blink phase
cb.dimAlpha      = 0.12     -- raise for a gentler pulse
cb.autoHide      = false    -- true: hide all borders when Terminal isn't frontmost
cb.rescanOnStart = true     -- rebuild borders for already-running sessions
cb.zPollInterval = 2.0      -- safety-net restack, seconds; 0 disables
cb.colors.green  = "#32d74b"
cb:start()
```

`autoHide` was the pre-2.0 workaround for borders floating over other apps;
occlusion clipping has replaced it, but it is kept for anyone who prefers no
borders at all outside Terminal.

## Manual control

With the `hs` CLI (`brew install --cask hammerspoon` links it):

```bash
hs -c 'spoon.ClaudeBorder:paint("/dev/ttys001", "green")'
hs -c 'spoon.ClaudeBorder:paint("/dev/ttys001", "#ff00ff", "blink")'
hs -c 'spoon.ClaudeBorder:mode("/dev/ttys001", "solid")'
hs -c 'spoon.ClaudeBorder:rescan()'
hs -c 'spoon.ClaudeBorder:list()'
hs -c 'spoon.ClaudeBorder:clearAll()'
```

Or over the URL bridge, which needs no CLI:

```bash
open -g "hammerspoon://border?tty=/dev/ttys001&color=green&mode=blink"
open -g "hammerspoon://border?tty=/dev/ttys001&color=off"
```

## Testing

```bash
./test/run.sh
```

Runs a headless suite (29 checks) against the **installed** spoon inside the
live Hammerspoon: the AX/AppleScript layer is stubbed with fake windows, so
occlusion punching, visibility, z-ordering, blink and the in-place repaint are
verified numerically — it even works with the screen locked.

## Troubleshooting

**Nothing appears.** Check `hs -c 'hs.accessibilityState()'` returns `true`;
restart Hammerspoon after granting. Then check the Hammerspoon console for a
config error — one bad line aborts the rest of the file, including the URL bridge.
Also check the screen wasn't locked when you tried: a locked session reports
`true` for accessibility while every window frame reads as zero.

**Borders don't follow windows.** `hs.window.filter.windowResized` does not
exist; passing it to `subscribe` throws `missing event(s)` and silently kills
every subscription below it. `windowMoved` already covers resizes.

**Stack overflow in the console.** Something is calling `canvas:show()` from
inside a window-event handler, which re-triggers window events. Show/hide (and
everything else in `restack()`) belongs behind the coalescing timer
(`scheduleRestack`), which runs outside the handler.

**Never make Hammerspoon touch `~/Documents` paths.** Reading a file under
`~/Documents` (even a `loadfile` syntax check) from a Hammerspoon that has no
Documents TCC grant blocks its main thread in an un-cancellable `open()` while
tccd waits for a consent dialog nobody can see. Everything this Spoon reads
lives in `~/.claude` or `~/.hammerspoon`, which are not TCC-protected.

## Licence

MIT
