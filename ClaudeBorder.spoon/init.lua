--- === ClaudeBorder ===
---
--- Per-session coloured borders around macOS Terminal.app windows, so several
--- concurrent Claude Code sessions are distinguishable at a glance.
---
--- A border is claimed by a tty, coloured from that session's `/color`, and
--- blinks while Claude is waiting for input. Borders are occlusion-aware: the
--- parts covered by windows above are punched out, so a border reads as glued
--- to its window instead of floating over everything.
---
--- Download: https://github.com/NikolajMosbaek/claude-terminal-borders

local obj = {}
obj.__index = obj

obj.name     = "ClaudeBorder"
obj.version  = "2.1"
obj.author   = "Nikolaj Søgaard Simonsen"
obj.homepage = "https://github.com/NikolajMosbaek/claude-terminal-borders"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--------------------------------------------------------------------------------
-- Configuration. Set before :start().
--------------------------------------------------------------------------------

--- ClaudeBorder.width (Number)
--- Border thickness in points. Drawn entirely outside the window frame.
obj.width = 5

--- ClaudeBorder.radius (Number)
--- Corner radius, to match the macOS window corner.
obj.radius = 11

--- ClaudeBorder.blinkInterval (Number)
--- Seconds between blink phases when a session is waiting for input.
obj.blinkInterval = 0.55

--- ClaudeBorder.dimAlpha (Number)
--- Alpha of the dim phase of a blink. Raise it for a gentler pulse.
obj.dimAlpha = 0.12

--- ClaudeBorder.autoHide (Boolean)
--- Hide all borders whenever Terminal is not the active application.
---
--- Off by default: occlusion clipping already removes the parts of a border
--- that other windows cover, so borders stay correct while you work in another
--- app. Turn it on to reclaim the pre-2.0 behaviour of no borders at all
--- outside Terminal.
obj.autoHide = false

--- ClaudeBorder.rescanOnStart (Boolean)
--- Rebuild borders for already-running Claude Code sessions when the Spoon
--- starts, from ~/.claude/sessions/. Without this a Hammerspoon restart leaves
--- every existing window bare until its session's next hook fires.
obj.rescanOnStart = true

--- ClaudeBorder.zPollInterval (Number)
--- Seconds between safety-net restacks. Most z-order changes arrive as window
--- events; this catches the ones that fire no event (a window raised without
--- focus, an app un-hidden behind another). 0 disables the poll.
obj.zPollInterval = 2.0

--- ClaudeBorder.menubar (Boolean)
--- Show a menubar item while at least one session is waiting for input: one
--- dot per waiting session, in its border colour. Occlusion clipping means a
--- fully covered window shows no border at all, so a blinking session can be
--- invisible -- the menubar dot is the signal that survives that. Clicking a
--- dot's menu entry focuses that window.
obj.menubar = true

--- ClaudeBorder.focusHotkey (Table | false)
--- Hotkey that focuses the next waiting session (and thereby clears its
--- blink), as `{ mods, key }`. Default ⌃⌥⌘B. Set to false to disable.
obj.focusHotkey = { { "ctrl", "alt", "cmd" }, "b" }

--- ClaudeBorder.pruneInterval (Number)
--- Seconds between checks that every painted tty still hosts a live claude
--- process. SessionEnd only fires on a clean exit; a crashed or killed claude
--- would otherwise leave its border painted until the window closes.
--- 0 disables.
obj.pruneInterval = 10

--- ClaudeBorder.colors (Table)
--- Maps Claude Code's eight /color names to hex. A raw "#rrggbb" also works
--- anywhere a colour name is accepted.
obj.colors = {
  red    = "#ff453a", orange = "#ff9f0a", yellow = "#ffd60a", green = "#32d74b",
  cyan   = "#64d2ff", blue   = "#0a84ff", purple = "#bf5af0", pink   = "#ff375f",
}

-- A session whose /color has not been set gets NO border at all. The window is
-- still tracked and its transcript still watched, so the border appears the
-- moment /color runs -- there is simply nothing to draw until then.

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

local painted    = {}     -- [tty] = { canvas, color, mode, timer, win, title,
                          --           transcript, watcher, onScreen, holeKey }
local shown      = true
local restacking = false
local restackDelayed          -- hs.timer.delayed coalescing restack requests
local wf, appWatcher, spaceWatcher, powerWatcher, pollTimer, pruneTimer
local bar, hotkeyObj           -- menubar item (present only while waiting), hotkey

-- One-shot timers must be retained until they fire: an hs.timer.doAfter whose
-- return value is dropped can be garbage-collected first and silently never
-- run (observed: the start-time rescans never firing).
local pendingTimers = {}
local function after(delay, fn)
  local t
  t = hs.timer.doAfter(delay, function()
    pendingTimers[t] = nil
    fn()
  end)
  pendingTimers[t] = true
end

local function cancelPending()
  for t in pairs(pendingTimers) do t:stop() end
  pendingTimers = {}
end

--------------------------------------------------------------------------------
-- Window lookup
--------------------------------------------------------------------------------

-- Ask Terminal.app which window owns this tty, and where it is.
--
-- Bounds, not title: concurrent Claude windows routinely share a byte-identical
-- title (same repo, same size, same running command), so matching on title
-- collapses them all onto whichever window happens to come first.
local function locateTTY(tty)
  local script = [[
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is "]] .. tty .. [[" then
            set b to bounds of w
            return {item 1 of b, item 2 of b, item 3 of b, item 4 of b, name of w}
          end if
        end repeat
      end repeat
    end tell
    return {}
  ]]
  local ok, r = hs.osascript.applescript(script)
  if not ok or not r or #r < 5 then return nil end
  return { left = r[1], top = r[2], title = r[5] }
end

local function windowForTTY(tty)
  local loc = locateTTY(tty)
  if not loc then return nil end
  local term = hs.application.get("Terminal")
  if not term then return nil end
  for _, w in ipairs(term:allWindows()) do
    local f = w:frame()
    if math.abs(f.x - loc.left) <= 8 and math.abs(f.y - loc.top) <= 8 then
      return w, loc.title
    end
  end
  return nil
end

local function windowId(win)
  if not win then return nil end
  local ok, id = pcall(win.id, win)
  if ok then return id end
  return nil
end

local function focusedWindowId()
  local ok, id = pcall(function()
    local w = hs.window.focusedWindow()
    return w and w:id() or nil
  end)
  if ok then return id end
  return nil
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- Reposition an existing canvas. Cheap enough to run on every windowMoved event
-- during a drag, which a delete-and-recreate would not be.
local function positionCanvas(c, f)
  local w = obj.width
  c:frame({ x = f.x - w, y = f.y - w, w = f.w + w * 2, h = f.h + w * 2 })
  -- The stroke sits wholly in the band outside the window frame, never over
  -- the window's own content.
  c[1].frame = { x = w / 2, y = w / 2, w = f.w + w, h = f.h + w }
end

local function drawAround(win, hex)
  local c = hs.canvas.new({ x = 0, y = 0, w = 100, h = 100 })
  c:appendElements({
    type             = "rectangle",
    action           = "stroke",
    strokeColor      = { hex = hex, alpha = 1.0 },
    strokeWidth      = obj.width,
    roundedRectRadii = { xRadius = obj.radius, yRadius = obj.radius },
  })
  positionCanvas(c, win:frame())
  c:level(hs.canvas.windowLevels.floating)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:clickActivating(false)
  return c
end

local function stopTimer(rec)
  if rec and rec.timer then rec.timer:stop(); rec.timer = nil end
end

local function startBlink(rec)
  stopTimer(rec)
  rec.timer = hs.timer.doEvery(obj.blinkInterval, function()
    if rec.canvas then
      rec.canvas:alpha(rec.canvas:alpha() > 0.5 and obj.dimAlpha or 1.0)
    end
  end)
end

--------------------------------------------------------------------------------
-- Waiting indicator
--
-- Occlusion clipping means a fully covered window shows no border at all, so a
-- blinking (waiting) session can be invisible. The menubar item is the signal
-- that survives that: one dot per waiting session, in its border colour, with
-- a menu that focuses the window. It exists only while something is waiting.
--------------------------------------------------------------------------------

local function waitingRecs()
  local out = {}
  for tty, rec in pairs(painted) do
    if rec.mode == "blink" then out[#out + 1] = { tty = tty, rec = rec } end
  end
  table.sort(out, function(a, b) return a.tty < b.tty end)
  return out
end

local function liveTitle(rec)
  local ok, t = pcall(function() return rec.win and rec.win:title() end)
  return (ok and t and #t > 0 and t) or rec.title or "?"
end

local function updateMenubar()
  local waiting = obj.menubar and waitingRecs() or {}
  if #waiting == 0 then
    if bar then bar:delete(); bar = nil; obj._bar = nil end
    return
  end
  if not bar then bar = hs.menubar.new(); obj._bar = bar end
  local title = hs.styledtext.new("")
  local items = {}
  for _, e in ipairs(waiting) do
    local hex = e.rec.color or "#8e8e93"   -- colourless sessions get a grey dot
    title = title .. hs.styledtext.new("●", { color = { hex = hex } })
    items[#items + 1] = {
      title = hs.styledtext.new("● ", { color = { hex = hex } })
              .. hs.styledtext.new(("%s  (%s)"):format(liveTitle(e.rec), e.tty)),
      fn = function() obj:focus(e.tty) end,
    }
  end
  bar:setTitle(title)
  bar:setMenu(items)
end

-- A border is drawn only when the session has a colour AND its window is
-- actually visible (on the current Space, not minimized, app not hidden) AND
-- borders are globally shown.
local function updateVisibility(rec)
  if shown and rec.color and rec.onScreen ~= false then
    rec.canvas:show()
  else
    rec.canvas:hide()
  end
end

--------------------------------------------------------------------------------
-- Occlusion
--
-- hs.canvas has no window level between "behind my own window" and "above
-- everything", so the canvas necessarily floats over every ordinary window.
-- Instead of hiding borders (the pre-2.0 autoHide workaround), punch out the
-- parts of each border that a window above it covers: element 1 is the stroke,
-- every following element is a compositeRule="clear" rectangle over an
-- occluding window. The punch mirrors the occluder's rounded corners, so the
-- border appears to slide *under* its neighbours.
--------------------------------------------------------------------------------

local function applyPunches(rec, holes, key)
  if rec.holeKey == key then return end   -- unchanged since last restack
  rec.holeKey = key
  local c = rec.canvas
  while #c > 1 do c:removeElement(#c) end
  for _, h in ipairs(holes) do
    c:appendElements({
      type             = "rectangle",
      action           = "fill",
      compositeRule    = "clear",
      frame            = { x = h.x, y = h.y, w = h.w, h = h.h },
      roundedRectRadii = { xRadius = h.r, yRadius = h.r },
    })
  end
end

-- One pass over everything: refresh window handles, reposition canvases, punch
-- occluded regions, mirror window z-order onto the canvases, apply visibility.
--
-- Never called directly from a window-event handler -- always through
-- scheduleRestack(), whose delayed timer runs outside the handler. Calling
-- canvas:show() from inside a window-event handler re-triggers window events
-- and overflows the Lua stack.
local function restack()
  if restacking then return end
  restacking = true

  local ok, err = pcall(function()
    local ordered = hs.window.orderedWindows() or {}   -- front to back, all apps
    local zOf, ids, frames = {}, {}, {}
    for i, w in ipairs(ordered) do
      local id = windowId(w)
      if id then
        zOf[id], ids[i] = i, id
        local okF, f = pcall(w.frame, w)
        if okF then frames[i] = f end
      end
    end

    -- Occluders that carry a border of their own get their punch inflated by
    -- the border width: their own canvas owns that band, and two coloured
    -- strokes crossing each other read as noise.
    local borderedIds = {}
    for _, rec in pairs(painted) do
      local id = windowId(rec.win)
      if id and rec.color then borderedIds[id] = true end
    end

    local byZ = {}   -- recs visible on this Space, for canvas ordering
    for tty, rec in pairs(painted) do
      local okF, f = pcall(function() return rec.win and rec.win:frame() end)
      if not okF or not f then
        local win = windowForTTY(tty)  -- cache stale: re-resolve through Terminal
        if win then rec.win = win; f = win:frame() else obj:clear(tty); f = nil end
      end
      if f then
        positionCanvas(rec.canvas, f)
        local z = zOf[windowId(rec.win)]
        rec.onScreen = z ~= nil
        if z then
          byZ[#byZ + 1] = { z = z, rec = rec }
          local w = obj.width
          local cf = { x = f.x - w, y = f.y - w, w = f.w + w * 2, h = f.h + w * 2 }
          local holes, key = {}, ""
          for i = 1, z - 1 do
            local of = frames[i]
            if of then
              local pad = borderedIds[ids[i]] and w or 0
              local px, py = of.x - pad, of.y - pad
              local pw, ph = of.w + pad * 2, of.h + pad * 2
              if px < cf.x + cf.w and px + pw > cf.x and
                 py < cf.y + cf.h and py + ph > cf.y then
                -- Keep the occluder's full rect (the canvas clips it) so the
                -- punch's rounded corners land where the window's do.
                local hx, hy = px - cf.x, py - cf.y
                holes[#holes + 1] = { x = hx, y = hy, w = pw, h = ph, r = obj.radius + pad }
                key = key .. ("|%d,%d,%d,%d,%d"):format(hx, hy, pw, ph, pad)
              end
            end
          end
          applyPunches(rec, holes, key)
        end
        updateVisibility(rec)
      end
    end

    -- Raise canvases back-to-front so their stacking mirrors the windows':
    -- the frontmost window's border ends up on top of its neighbours'.
    -- Only visible ones: orderAbove() un-hides a hidden canvas.
    table.sort(byZ, function(a, b) return a.z > b.z end)
    for _, e in ipairs(byZ) do
      if e.rec.canvas:isShowing() then e.rec.canvas:orderAbove() end
    end
  end)

  restacking = false
  if not ok then print("ClaudeBorder restack: " .. tostring(err)) end
end

local function scheduleRestack()
  if not restackDelayed then
    restackDelayed = hs.timer.delayed.new(0.05, restack)
  end
  restackDelayed:start()
end

--------------------------------------------------------------------------------
-- Live /color tracking
--
-- /color is a built-in command that fires no Claude Code hook, so a hook-driven
-- repaint only happens on the next submitted prompt. Watching the session
-- transcript closes that gap: the colour lands within a second of the command.
--------------------------------------------------------------------------------

-- Read only the tail: transcripts reach many megabytes and are appended to
-- constantly during a turn.
local function lastColorIn(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - 65536))
  local chunk = f:read("*a") or ""
  f:close()
  local last
  for c in chunk:gmatch('"agentColor":"([^"]+)"') do last = c end
  return last
end

-- A /color name, or a raw #rrggbb, to hex. nil in (or an unknown name, or
-- "default") means "no colour" -- nil out.
local function resolveHex(color)
  if not color then return nil end
  return obj.colors[color] or color:match("^#%x%x%x%x%x%x$") or nil
end

-- hex may be nil, meaning "/color has not been run" -- draw nothing.
local function applyColor(rec, hex)
  if hex == rec.color then return end
  rec.color = hex
  if hex then rec.canvas[1].strokeColor = { hex = hex, alpha = 1.0 } end
  updateVisibility(rec)
  updateMenubar()   -- a waiting session's dot follows its colour
end

local function watchTranscript(rec)
  if rec.watcher then rec.watcher:stop(); rec.watcher = nil end
  if not rec.transcript then return end
  local debounced = hs.timer.delayed.new(1.0, function()
    applyColor(rec, resolveHex(lastColorIn(rec.transcript)))
  end)
  rec.watcher = hs.pathwatcher.new(rec.transcript, function() debounced:start() end)
  rec.watcher:start()
  debounced:start()   -- resolve once immediately
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- ClaudeBorder:paint(tty, color[, mode[, transcript]]) -> string
--- Claim the Terminal window owning `tty`. `mode` is "solid" (default) or
--- "blink". Passing the session's transcript path keeps the colour in sync with
--- /color without waiting for a hook.
---
--- A tty that is already painted and whose window is still alive is updated in
--- place -- hooks call this on every prompt, and a delete-and-recreate per turn
--- flickers. The canvas is only rebuilt when the window has to be re-resolved.
---
--- "blink" on the window you are focused on right now downgrades to "solid":
--- you are already looking at it, and a click on an already-focused window
--- fires no focus event, so nothing would ever stop the blink.
function obj:paint(tty, color, mode, transcript)
  local hex = resolveHex(color)
  mode = mode or "solid"

  local rec = painted[tty]
  if rec then
    local alive = pcall(function() return rec.win:frame().w end)
    if alive then
      applyColor(rec, hex)
      if rec.transcript ~= transcript then
        rec.transcript = transcript
        watchTranscript(rec)
      end
      obj:mode(tty, mode)
      scheduleRestack()
      return ("painted %s (%s) %s %s (updated)"):format(
        tty, rec.title or "?", hex or "no colour", rec.mode)
    end
  end

  local win, title = windowForTTY(tty)
  if not win then return "no window for " .. tostring(tty) end
  obj:clear(tty)
  if mode == "blink" and windowId(win) == focusedWindowId() then mode = "solid" end
  rec = { canvas = drawAround(win, hex or "#000000"), color = hex, win = win,
          mode = mode, title = title, transcript = transcript }
  painted[tty] = rec
  updateVisibility(rec)
  updateMenubar()
  if transcript then watchTranscript(rec) end
  if rec.mode == "blink" then startBlink(rec) end
  restack()   -- punch + order the new canvas before its first frame is seen
  return ("painted %s (%s) %s %s"):format(tty, title, hex or "no colour", rec.mode)
end

--- ClaudeBorder:mode(tty, mode) -> string
--- Switch an existing border between "solid" and "blink" without redrawing.
--- The same already-focused downgrade as `paint` applies.
function obj:mode(tty, mode)
  local rec = painted[tty]
  if not rec then return "not painted: " .. tostring(tty) end
  if mode == "blink" and windowId(rec.win) == focusedWindowId() then mode = "solid" end
  rec.mode = mode
  if mode == "blink" then
    startBlink(rec)
  else
    stopTimer(rec)
    rec.canvas:alpha(1.0)
  end
  updateMenubar()
  return tty .. " -> " .. mode
end

--- ClaudeBorder:clear(tty) -> string
function obj:clear(tty)
  local rec = painted[tty]
  if rec then
    stopTimer(rec)
    if rec.watcher then rec.watcher:stop(); rec.watcher = nil end
    rec.canvas:delete()
    painted[tty] = nil
    updateMenubar()
  end
  return "cleared " .. tostring(tty)
end

--- ClaudeBorder:clearAll() -> string
function obj:clearAll()
  for tty in pairs(painted) do obj:clear(tty) end
  return "cleared all"
end

--- ClaudeBorder:list() -> string
--- One line per painted border: tty, colour, mode.
function obj:list()
  local out = {}
  for tty, rec in pairs(painted) do
    out[#out + 1] = ("%s %s %s"):format(tty, rec.color or "(no colour)", rec.mode)
  end
  table.sort(out)
  return table.concat(out, "\n")
end

--- ClaudeBorder:focus(tty) -> string
--- Focus the window owning `tty` (switching Space if needed). A waiting
--- border goes solid immediately -- deterministic, rather than waiting for
--- the focus event to arrive.
function obj:focus(tty)
  local rec = painted[tty]
  if not rec then return "not painted: " .. tostring(tty) end
  pcall(function() rec.win:focus() end)
  if rec.mode == "blink" then obj:mode(tty, "solid") end
  return "focused " .. tty
end

--- ClaudeBorder:focusNextWaiting() -> string
--- Focus the first waiting session (sorted by tty), clearing its blink.
--- Pressing the hotkey repeatedly therefore walks through every waiting
--- session. Bound to `focusHotkey` (default ⌃⌥⌘B).
function obj:focusNextWaiting()
  local waiting = waitingRecs()
  if #waiting == 0 then
    hs.alert.show("No Claude session is waiting", 0.7)
    return "none waiting"
  end
  return obj:focus(waiting[1].tty)
end

--- ClaudeBorder:waiting() -> string
--- One tty per line, for every session currently waiting for input.
function obj:waiting()
  local out = {}
  for _, e in ipairs(waitingRecs()) do out[#out + 1] = e.tty end
  return table.concat(out, "\n")
end

--- ClaudeBorder:prune() -> string
--- Clear every border whose tty no longer hosts a live claude process.
--- SessionEnd only fires on a clean exit; this catches crashes and kills.
--- Runs every `pruneInterval` seconds.
function obj:prune()
  if not next(painted) then return "pruned 0" end
  local out = hs.execute("ps -axo tty=,comm=") or ""
  if not out:find("%S") then return "pruned 0 (ps gave nothing)" end   -- never clear on a failed ps
  local live = {}
  for line in out:gmatch("[^\n]+") do
    local t, comm = line:match("^%s*(%S+)%s+(.+)$")
    if t and comm and comm:lower():find("claude", 1, true) then
      live["/dev/" .. t] = true
    end
  end
  local n = 0
  for tty in pairs(painted) do
    if not live[tty] then obj:clear(tty); n = n + 1 end
  end
  return ("pruned %d"):format(n)
end

--- ClaudeBorder:rescan() -> string
--- Rebuild borders for Claude Code sessions that are already running, from
--- ~/.claude/sessions/<pid>.json (pid, sessionId, cwd, status). Runs on
--- :start() by default (see `rescanOnStart`) and again on screen unlock;
--- SessionStart only fires for new sessions, so without this a Hammerspoon
--- restart leaves existing windows bare until their next turn.
---
--- Idempotent: a tty that already has a border is left exactly as it is, so
--- an unlock-triggered rescan never clobbers a live border's colour or mode.
function obj:rescan()
  local home = os.getenv("HOME")
  local dir = home .. "/.claude/sessions"
  if not hs.fs.attributes(dir) then return "no session directory" end
  local n = 0
  for file in hs.fs.dir(dir) do
    if file:match("^%d+%.json$") then
      local okRead, s = pcall(hs.json.read, dir .. "/" .. file)
      if okRead and s and s.pid and s.sessionId and s.cwd then
        -- Alive, still a claude process (pids get recycled), and on a real tty.
        local out = hs.execute(("ps -o tty=,comm= -p %d 2>/dev/null"):format(s.pid)) or ""
        local t, comm = out:match("^%s*(%S+)%s+(%S+)")
        if t and t ~= "??" and comm and comm:lower():find("claude", 1, true)
           and not painted["/dev/" .. t] then
          local slug = s.cwd:gsub("[^%w]", "-")
          local transcript = ("%s/.claude/projects/%s/%s.jsonl"):format(home, slug, s.sessionId)
          if not hs.fs.attributes(transcript) then transcript = nil end
          local color = transcript and lastColorIn(transcript) or nil
          local mode = (s.status == "busy") and "solid" or "blink"
          if obj:paint("/dev/" .. t, color, mode, transcript):match("^painted") then
            n = n + 1
          end
        end
      end
    end
  end
  return ("rescan painted %d session(s)"):format(n)
end

--- ClaudeBorder:restack() -> string
--- Force an immediate occlusion/visibility/z-order pass. Normally not needed:
--- window events, Space switches, unlocks and the safety poll all schedule one.
function obj:restack()
  restack()
  return "restacked"
end

--- ClaudeBorder:setVisible(bool) -> string
function obj:setVisible(v)
  shown = v
  for _, rec in pairs(painted) do updateVisibility(rec) end
  return "visible=" .. tostring(v)
end

--- ClaudeBorder:setAutoHide(bool) -> string
function obj:setAutoHide(v)
  obj.autoHide = v
  if v then
    local front = hs.application.frontmostApplication()
    obj:setVisible(front ~= nil and front:name() == "Terminal")
  else
    obj:setVisible(true)
  end
  return "autohide=" .. tostring(obj.autoHide)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--- ClaudeBorder:start() -> self
function obj:start()
  require("hs.ipc")   -- enables the `hs` command line tool

  -- All apps, not just Terminal: any window can occlude a border, so any
  -- window's move/close/raise must trigger a restack. Hammerspoon's own
  -- windows are rejected so canvas frame changes can never feed back in.
  wf = hs.window.filter.new():setAppFilter("Hammerspoon", false)
  obj._wf = wf        -- retained: a collected filter silently drops subscriptions

  -- windowMoved also covers resizes; hs.window.filter has no windowResized.
  -- The handler only repositions (element/frame writes, no show/hide) and
  -- schedules the real work: restack() runs from the delayed timer, outside
  -- the handler, where canvas:show() is safe.
  wf:subscribe({
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowMoved,
    hs.window.filter.windowMinimized,
    hs.window.filter.windowUnminimized,
    hs.window.filter.windowHidden,
    hs.window.filter.windowUnhidden,
    hs.window.filter.windowFullscreened,
    hs.window.filter.windowUnfullscreened,
    hs.window.filter.windowUnfocused,
  }, function(win)
    -- Keep the border glued to its window during a drag, without waiting for
    -- the coalesced restack.
    local id = windowId(win)
    if id then
      for _, rec in pairs(painted) do
        if windowId(rec.win) == id then
          local okF, f = pcall(win.frame, win)
          if okF and f then positionCanvas(rec.canvas, f) end
        end
      end
    end
    scheduleRestack()
  end)

  -- Focusing a window means you have seen it, so stop its blink without
  -- waiting for a prompt. A raise always accompanies focus, so restack too.
  wf:subscribe(hs.window.filter.windowFocused, function(win)
    local focusedId = windowId(win)
    if focusedId then
      for tty, rec in pairs(painted) do
        if rec.mode == "blink" and windowId(rec.win) == focusedId then
          obj:mode(tty, "solid")
        end
      end
    end
    scheduleRestack()
  end)

  -- App activation changes z-order wholesale; it is also the autoHide channel.
  appWatcher = hs.application.watcher.new(function(name, event)
    if event == hs.application.watcher.activated then
      if obj.autoHide then obj:setVisible(name == "Terminal") end
      scheduleRestack()
    end
  end)
  appWatcher:start()
  obj._appWatcher = appWatcher

  -- Space switches change which windows exist without any window event.
  spaceWatcher = hs.spaces.watcher.new(scheduleRestack)
  spaceWatcher:start()
  obj._spaceWatcher = spaceWatcher

  -- A locked screen degrades the Accessibility API system-wide: windows
  -- enumerate but report no frames, so any paint attempted while locked fails
  -- with "no window". Rescan (idempotent) once the session is usable again.
  powerWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.screensDidUnlock
       or event == hs.caffeinate.watcher.sessionDidBecomeActive
       or event == hs.caffeinate.watcher.systemDidWake then
      after(2, function() obj:rescan() end)
      scheduleRestack()
    end
  end)
  powerWatcher:start()
  obj._powerWatcher = powerWatcher

  -- Safety net for z-order changes that fire no event. restack() is a no-op
  -- redraw-wise when nothing changed (holeKey), so this is cheap.
  if obj.zPollInterval and obj.zPollInterval > 0 then
    pollTimer = hs.timer.doEvery(obj.zPollInterval, function()
      if next(painted) then scheduleRestack() end
    end)
    obj._pollTimer = pollTimer
  end

  -- Clear borders whose claude died without a SessionEnd (crash, kill -9).
  if obj.pruneInterval and obj.pruneInterval > 0 then
    pruneTimer = hs.timer.doEvery(obj.pruneInterval, function() obj:prune() end)
    obj._pruneTimer = pruneTimer
  end

  -- Jump to the next waiting session from anywhere.
  if obj.focusHotkey then
    hotkeyObj = hs.hotkey.bind(obj.focusHotkey[1], obj.focusHotkey[2],
                               function() obj:focusNextWaiting() end)
    obj._hotkey = hotkeyObj
  end

  local front = hs.application.frontmostApplication()
  shown = (not obj.autoHide) or (front ~= nil and front:name() == "Terminal")

  -- URL bridge, used by the Claude Code hook:
  --   open -g "hammerspoon://border?tty=/dev/ttys001&color=green&mode=blink"
  --   open -g "hammerspoon://border?tty=/dev/ttys001&mode=solid"
  --   open -g "hammerspoon://border?tty=/dev/ttys001&color=off"
  hs.urlevent.bind("border", function(_, p)
    if not p.tty then return end
    if p.color == "off" then
      obj:clear(p.tty)
    elseif p.color then
      obj:paint(p.tty, p.color, p.mode, p.transcript)
    elseif p.mode then
      obj:mode(p.tty, p.mode)
    end
  end)
  hs.urlevent.bind("borderoff", function() obj:clearAll() end)

  if obj.rescanOnStart then
    -- The AX/AppleScript layer is not always answerable right at config-load
    -- time (a rescan 0.5s after hs.reload() has been seen finding no windows),
    -- so try a few times. rescan is idempotent, so the extra attempts are free.
    for _, delay in ipairs({ 1, 4, 10 }) do
      after(delay, function() obj:rescan() end)
    end
  end

  return self
end

--- ClaudeBorder:stop() -> self
function obj:stop()
  obj:clearAll()
  if wf then wf:unsubscribeAll(); wf = nil; obj._wf = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil; obj._appWatcher = nil end
  if spaceWatcher then spaceWatcher:stop(); spaceWatcher = nil; obj._spaceWatcher = nil end
  if powerWatcher then powerWatcher:stop(); powerWatcher = nil; obj._powerWatcher = nil end
  if pollTimer then pollTimer:stop(); pollTimer = nil; obj._pollTimer = nil end
  if pruneTimer then pruneTimer:stop(); pruneTimer = nil; obj._pruneTimer = nil end
  if hotkeyObj then hotkeyObj:delete(); hotkeyObj = nil; obj._hotkey = nil end
  if bar then bar:delete(); bar = nil end
  if restackDelayed then restackDelayed:stop() end
  cancelPending()
  return self
end

return obj
