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
obj.version  = "2.6.1"
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

--- ClaudeBorder.rescanInterval (Number)
--- Seconds between safety-net rescans. Rescan is idempotent (painted ttys are
--- left alone) and cheap (session files + one async ps), and this makes every
--- failure mode self-healing: whatever a lock/unlock cycle, display change or
--- AX hiccup broke, live sessions get their borders back within a minute.
--- Skipped while the screen is locked -- paints cannot succeed there.
--- 0 disables.
obj.rescanInterval = 60

--- ClaudeBorder.menubar (Boolean)
--- Show a menubar item: one dot per waiting session, in its border colour,
--- or a quiet frame glyph when nothing waits (dimmed while borders are
--- disabled). Occlusion clipping means a fully covered window shows no border
--- at all, so a blinking session can be invisible -- the menubar dot is the
--- signal that survives that. The menu focuses waiting windows and carries
--- the Enable/Disable Borders toggle.
obj.menubar = true

--- ClaudeBorder.settingsKey (String)
--- hs.settings key that persists the Enable/Disable toggle across Hammerspoon
--- restarts.
obj.settingsKey = "ClaudeBorder.enabled"

--- ClaudeBorder.pill (Boolean)
--- Floating "waiting" pill: a small capsule with one dot per waiting session,
--- drawn as a canvas on the primary screen. It exists for menu bars the
--- MacBook notch eats -- macOS hides overflowing status items with no
--- indication, so the menubar dots can be invisible exactly when needed.
--- Clicking the pill focuses the next waiting session. Off by default.
obj.pill = false

--- ClaudeBorder.pillCorner (String)
--- Where the pill sits on the primary screen: "topRight" (default),
--- "topLeft", "bottomRight" or "bottomLeft".
obj.pillCorner = "topRight"

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

--- ClaudeBorder.tabCacheTTL (Number)
--- Minimum seconds between selected-tab refreshes. The answer is refreshed in
--- the background and restacks read the last one, so this bounds refresh
--- traffic, not latency; tab-switch events force a refresh regardless.
obj.tabCacheTTL = 1.0

--- ClaudeBorder.colors (Table)
--- Maps Claude Code's eight /color names to hex. A raw "#rrggbb" also works
--- anywhere a colour name is accepted.
obj.colors = {
  red    = "#ff453a", orange = "#ff9f0a", yellow = "#ffd60a", green = "#32d74b",
  cyan   = "#64d2ff", blue   = "#0a84ff", purple = "#bf5af0", pink   = "#ff375f",
}

--- ClaudeBorder.terminalApps (Table)
--- The terminal applications the Spoon can resolve a tty inside, tried in
--- order. Each entry supplies the app's name plus three AppleScript templates
--- (`%s` is the tty), all returning plain text because they run through an
--- asynchronous `osascript` (hs.task): a busy terminal answers Apple events
--- in whole seconds, so nothing script-shaped may ever run on Hammerspoon's
--- main thread. `locate` returns "left|top|right|bottom|window name" for the
--- window owning the tty (name last: it may contain anything); `selectedTabs`
--- returns the tty of every window's selected tab/pane, one per line;
--- `selectTab` makes the tty's tab the selected one and returns "true".
---
--- Terminal.app is fully supported. iTerm2 is implemented per its scripting
--- dictionary (sessions inside tabs; the border follows the *active* pane of
--- a split). Ghostty/kitty/WezTerm expose no AppleScript and cannot be added.
obj.terminalApps = {
  {
    app = "Terminal",
    locate = [[
      with timeout of 5 seconds
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "%s" then
                set b to bounds of w
                return (item 1 of b as text) & "|" & (item 2 of b as text) & "|" & (item 3 of b as text) & "|" & (item 4 of b as text) & "|" & (name of w)
              end if
            end repeat
          end repeat
        end tell
      end timeout
      return ""
    ]],
    selectedTabs = [[
      with timeout of 5 seconds
        tell application "Terminal"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              if selected of t then set out to out & (tty of t) & linefeed
            end repeat
          end repeat
          return out
        end tell
      end timeout
    ]],
    selectTab = [[
      with timeout of 5 seconds
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "%s" then
                set selected of t to true
                return "true"
              end if
            end repeat
          end repeat
        end tell
      end timeout
      return "false"
    ]],
  },
  {
    app = "iTerm2",
    locate = [[
      with timeout of 5 seconds
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "%s" then
                  set b to bounds of w
                  return (item 1 of b as text) & "|" & (item 2 of b as text) & "|" & (item 3 of b as text) & "|" & (item 4 of b as text) & "|" & (name of w)
                end if
              end repeat
            end repeat
          end repeat
        end tell
      end timeout
      return ""
    ]],
    selectedTabs = [[
      with timeout of 5 seconds
        tell application "iTerm2"
          set out to ""
          repeat with w in windows
            set out to out & (tty of current session of current tab of w) & linefeed
          end repeat
          return out
        end tell
      end timeout
    ]],
    selectTab = [[
      with timeout of 5 seconds
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "%s" then
                  tell t to select
                  tell s to select
                  return "true"
                end if
              end repeat
            end repeat
          end repeat
        end tell
      end timeout
      return "false"
    ]],
  },
}

-- A session whose /color has not been set gets NO border at all. The window is
-- still tracked and its transcript still watched, so the border appears the
-- moment /color runs -- there is simply nothing to draw until then.

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

local painted    = {}     -- [tty] = { canvas, color, mode, timer, win, title,
                          --           transcript, watcher, onScreen, holeKey }
local shown      = true   -- the autoHide machinery's flag
local enabled    = true   -- the user's master switch (menubar / setEnabled)
local restacking = false
local restackDelayed          -- hs.timer.delayed coalescing restack requests
local wf, appWatcher, spaceWatcher, powerWatcher, pollTimer, pruneTimer
local bar, hotkeyObj           -- persistent menubar item, hotkey
local scheduleRestack          -- forward: the coalesced-restack scheduler
local lastStack                -- ordered-window data from the last full restack
local dragTap, dragTimer, dragLast   -- mouse-driven responsiveness (see start)

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

-- Asynchronous subprocess runner (hs.task), retained until it reports, with a
-- safety terminate. Injectable (obj._exec) so the test harness can substitute
-- a synchronous fake.
--
-- The stream callback is load-bearing, not an optimization: without one,
-- hs.task reads stdout only at exit, so a child whose output exceeds the 64KB
-- pipe buffer (ps -ax on this machine: ~140KB) blocks writing and DEADLOCKS,
-- and the exit callback never fires.
local runningTasks = {}
obj._exec = function(cmd, args, cb)
  local buf = {}
  local t
  t = hs.task.new(cmd, function(code, stdOut, _)
    runningTasks[t] = nil
    buf[#buf + 1] = stdOut or ""
    cb(code == 0, table.concat(buf))
  end, function(_, stdOut, _)
    buf[#buf + 1] = stdOut or ""
    return true
  end, args)
  runningTasks[t] = true
  t:start()
  after(15, function()
    if runningTasks[t] then runningTasks[t] = nil; pcall(function() t:terminate() end) end
  end)
end

local function cancelTasks()
  for t in pairs(runningTasks) do pcall(function() t:terminate() end) end
  runningTasks = {}
end

-- AppleScript, asynchronously: a Terminal that is busy printing answers Apple
-- events in whole SECONDS (measured 2-4s per script under load), and the sync
-- hs.osascript call would stall Hammerspoon's main thread -- menus, timers,
-- everything -- for exactly that long. This is why every template above
-- returns plain text: it comes back through osascript's stdout.
local function runScript(script, cb)
  obj._exec("/usr/bin/osascript", { "-e", script }, cb)
end

--------------------------------------------------------------------------------
-- Window lookup
--------------------------------------------------------------------------------

-- Match an AppleScript-reported window position back to an AX window.
--
-- Bounds, not title: concurrent Claude windows routinely share a byte-identical
-- title (same repo, same size, same running command), so matching on title
-- collapses them all onto whichever window happens to come first.
local function windowMatching(appName, left, top)
  local app = hs.application.get(appName)
  if not app then return nil end
  for _, w in ipairs(app:allWindows()) do
    local ok, f = pcall(w.frame, w)
    if ok and f and math.abs(f.x - left) <= 8 and math.abs(f.y - top) <= 8 then
      return w
    end
  end
  return nil
end

-- Resolve tty -> (window, title) through each running terminal app in turn.
-- Asynchronous: cb(win, title) on a hit, cb(nil) when nobody owns the tty.
local function resolveTTY(tty, cb)
  local i = 0
  local function tryNext()
    i = i + 1
    local cfg = obj.terminalApps[i]
    if not cfg then cb(nil); return end
    if not hs.application.get(cfg.app) then tryNext(); return end
    runScript(cfg.locate:format(tty), function(ok, out)
      local l, t = (out or ""):match("^%s*(-?%d+)|(-?%d+)|%-?%d+|%-?%d+|")
      local title = (out or ""):match("^%s*%-?%d+|%-?%d+|%-?%d+|%-?%d+|([^\n]*)")
      if ok and l then
        local win = windowMatching(cfg.app, tonumber(l), tonumber(t))
        if win then cb(win, title); return end
      end
      tryNext()
    end)
  end
  tryNext()
end

local function isTerminalApp(name)
  for _, cfg in ipairs(obj.terminalApps) do
    if cfg.app == name then return true end
  end
  return false
end

-- The set of ttys whose tab/pane is the selected one of its window, across
-- every running terminal app. Refreshed in the background; restack reads the
-- last answer (selCache). nil means "no answer yet" -- hide nothing. A
-- changed answer schedules a restack, so tab switches propagate on their own.
local selCache, selCacheAt = nil, 0
local selInFlight = false
local function refreshSelected(force)
  if selInFlight then return end
  local now = hs.timer.secondsSinceEpoch()
  if not force and selCache and (now - selCacheAt) < (obj.tabCacheTTL or 0) then return end
  local cfgs = {}
  for _, cfg in ipairs(obj.terminalApps) do
    if cfg.selectedTabs and hs.application.get(cfg.app) then cfgs[#cfgs + 1] = cfg end
  end
  if #cfgs == 0 then selCache = nil; return end
  selInFlight = true
  local set, remaining, answered = {}, #cfgs, false
  for _, cfg in ipairs(cfgs) do
    runScript(cfg.selectedTabs, function(ok, out)
      if ok then
        answered = true
        for line in (out or ""):gmatch("[^\r\n]+") do
          if line:match("^/dev/") then set[line] = true end
        end
      end
      remaining = remaining - 1
      if remaining == 0 then
        selInFlight = false
        selCacheAt = hs.timer.secondsSinceEpoch()
        if answered then
          local changed = selCache == nil
          if selCache then
            for k in pairs(set) do if not selCache[k] then changed = true end end
            for k in pairs(selCache) do if not set[k] then changed = true end end
          end
          selCache = set
          if changed and scheduleRestack then scheduleRestack() end
        end
      end
    end)
  end
end

local function selectTab(tty, cb)
  local i = 0
  local function tryNext()
    i = i + 1
    local cfg = obj.terminalApps[i]
    if not cfg then if cb then cb(false) end return end
    if not (cfg.selectTab and hs.application.get(cfg.app)) then tryNext(); return end
    runScript(cfg.selectTab:format(tty), function(ok, out)
      if ok and (out or ""):find("true", 1, true) then
        selCacheAt = 0                -- the answer just changed; refetch soon
        refreshSelected(true)
        if cb then cb(true) end
      else
        tryNext()
      end
    end)
  end
  tryNext()
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

-- One shared timer for every blinking border: the phases stay in sync (calmer
-- to look at than N independent pulses) and N waiting sessions cost one timer.
-- It exists only while something blinks.
local blinkTimer, blinkDim
local function syncBlinkTimer()
  local any = false
  for _, rec in pairs(painted) do
    if rec.mode == "blink" then any = true; break end
  end
  if any and not blinkTimer then
    blinkDim = false
    blinkTimer = hs.timer.doEvery(obj.blinkInterval, function()
      blinkDim = not blinkDim
      local a = blinkDim and obj.dimAlpha or 1.0
      for _, rec in pairs(painted) do
        if rec.mode == "blink" then rec.canvas:alpha(a) end
      end
    end)
  elseif blinkTimer and not any then
    blinkTimer:stop(); blinkTimer = nil
  end
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

-- The floating pill: a notch-proof stand-in for the menubar dots. Lives on
-- the primary screen, repositioned on every update so display changes are
-- absorbed; clicking it focuses the next waiting session.
local pillCanvas
local function updatePill()
  local waiting = (obj.pill and enabled) and waitingRecs() or {}
  if #waiting == 0 then
    if pillCanvas then pillCanvas:delete(); pillCanvas = nil; obj._pill = nil end
    return
  end
  local h, r, gap, margin = 22, 4.5, 13, 14
  local w = 9 + #waiting * gap
  local sf = hs.screen.primaryScreen():fullFrame()
  local corner = obj.pillCorner or "topRight"
  local x = corner:find("Left") and (sf.x + margin) or (sf.x + sf.w - w - margin)
  local y = corner:find("top", 1, true) and (sf.y + 38) or (sf.y + sf.h - h - margin)
  if not pillCanvas then
    pillCanvas = hs.canvas.new({ x = x, y = y, w = w, h = h })
    obj._pill = pillCanvas
    pillCanvas:level(hs.canvas.windowLevels.floating)
    pillCanvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    pillCanvas:clickActivating(false)
    pillCanvas:canvasMouseEvents(true, false, false, false)
    pillCanvas:mouseCallback(function(_, event)
      if event == "mouseDown" then obj:focusNextWaiting() end
    end)
  else
    pillCanvas:frame({ x = x, y = y, w = w, h = h })
  end
  while #pillCanvas > 0 do pillCanvas:removeElement(#pillCanvas) end
  pillCanvas:appendElements({
    type             = "rectangle",
    action           = "strokeAndFill",
    fillColor        = { hex = "#1c1c1e", alpha = 0.92 },
    strokeColor      = { hex = "#ffffff", alpha = 0.16 },
    strokeWidth      = 1,
    roundedRectRadii = { xRadius = h / 2, yRadius = h / 2 },
  })
  for i, e in ipairs(waiting) do
    pillCanvas:appendElements({
      type      = "circle",
      action    = "fill",
      fillColor = { hex = e.rec.color or "#8e8e93", alpha = 1.0 },
      center    = { x = w / 2 + (i - (#waiting + 1) / 2) * gap, y = h / 2 },
      radius    = r,
    })
  end
  pillCanvas:show()
end

local function updateMenubar()
  updatePill()   -- same triggers, same waiting set
  if not obj.menubar then
    if bar then bar:delete(); bar = nil; obj._bar = nil end
    return
  end
  if not bar then bar = hs.menubar.new(); obj._bar = bar end

  -- Title: one dot per waiting session in its colour; a quiet frame glyph
  -- when nothing waits. Everything dims while borders are disabled.
  local dim = enabled and 1.0 or 0.35
  local waiting = waitingRecs()
  local title
  if #waiting > 0 then
    title = hs.styledtext.new("")
    for _, e in ipairs(waiting) do
      local hex = e.rec.color or "#8e8e93"   -- colourless sessions get a grey dot
      title = title .. hs.styledtext.new("●", { color = { hex = hex, alpha = dim } })
    end
  else
    title = hs.styledtext.new("▢", { color = { hex = "#8e8e93", alpha = dim } })
  end
  bar:setTitle(title)

  local items = {}
  for _, e in ipairs(waiting) do
    local hex = e.rec.color or "#8e8e93"
    items[#items + 1] = {
      title = hs.styledtext.new("● ", { color = { hex = hex } })
              .. hs.styledtext.new(("%s  (%s)"):format(liveTitle(e.rec), e.tty)),
      fn = function() obj:focus(e.tty) end,
    }
  end
  if #items > 0 then items[#items + 1] = { title = "-" } end
  items[#items + 1] = {
    title = enabled and "Disable Borders" or "Enable Borders",
    fn = function() obj:setEnabled(not enabled) end,
  }
  items[#items + 1] = { title = "Rescan Sessions", fn = function() obj:rescan() end }
  bar:setMenu(items)
end

-- A border is drawn only when the session has a colour AND its window is
-- actually visible (on the current Space, not minimized, app not hidden) AND
-- its tab is the window's selected one AND borders are globally shown.
-- tabSelected is nil when unknown -- only a definite "another tab is selected"
-- hides the border.
local function updateVisibility(rec)
  if enabled and shown and rec.color and rec.onScreen ~= false
     and rec.tabSelected ~= false then
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
-- `light` reuses the ordered-window data from the last full pass: the full
-- pass costs ~35ms (orderedWindows does AX work per window on screen), a
-- cached pass ~1ms, so the drag-follow loop can run it at drag rate. Painted
-- windows' frames are always read live either way.
local function restack(light)
  if restacking then return end
  restacking = true

  local ok, err = pcall(function()
    local zOf, ids, frames
    if light and lastStack then
      zOf, ids, frames = lastStack.zOf, lastStack.ids, lastStack.frames
    else
      local ordered = hs.window.orderedWindows() or {}   -- front to back, all apps
      zOf, ids, frames = {}, {}, {}
      for i, w in ipairs(ordered) do
        local id = windowId(w)
        if id then
          zOf[id], ids[i] = i, id
          local okF, f = pcall(w.frame, w)
          if okF then frames[i] = f end
        end
      end
      lastStack = { zOf = zOf, ids = ids, frames = frames }
    end

    -- Two sessions in two tabs of one window would otherwise fight over the
    -- same border: only the selected tab's session shows. The others stay
    -- tracked (and keep blinking into the menubar) while hidden. The answer
    -- comes from the background refresh; kick one and read the latest.
    if not light and next(painted) then refreshSelected() end
    local selSet = selCache

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
        -- Cache stale. Hide now and re-resolve in the background (an
        -- AppleScript round trip). A failed resolve means "cannot find it
        -- RIGHT NOW", not "gone" -- a locked screen zeroes every AX frame, so
        -- resolving during a lock always fails -- so never clear here: stay
        -- hidden and let the safety poll retry. A truly dead session is the
        -- prune's job (its claude is gone), and a closed window kills its
        -- shell, which is the same thing.
        f = nil
        rec.onScreen = false
        updateVisibility(rec)
        if not rec.resolving then
          rec.resolving = true
          resolveTTY(tty, function(win)
            if painted[tty] ~= rec then return end
            rec.resolving = false
            if win then rec.win = win; scheduleRestack() end
          end)
        end
      end
      if f then
        positionCanvas(rec.canvas, f)
        if selSet then rec.tabSelected = (selSet[tty] == true) else rec.tabSelected = nil end
        local z = zOf[windowId(rec.win)]
        rec.onScreen = z ~= nil
        if z then frames[z] = f end   -- keep the cache fresh for light passes
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

scheduleRestack = function()
  if not restackDelayed then
    restackDelayed = hs.timer.delayed.new(0.05, function() restack() end)
  end
  restackDelayed:start()
end

--------------------------------------------------------------------------------
-- Mouse-driven responsiveness
--
-- hs.window.filter delivers move/raise events debounced and often only when a
-- drag ENDS, and the safety poll runs every 2s -- so a dragged or backgrounded
-- window could wear a stale border for whole seconds. The input is the honest
-- signal: while the left button is down, a ~16Hz loop reads the focused
-- window's frame and runs a cached-order light restack when it changed, so
-- borders (and the punches they cut in neighbours) follow the drag live.
-- Mouse-down and mouse-up each schedule a full restack for the raise/lower.
--------------------------------------------------------------------------------

local function stopDragWatch()
  if dragTimer then dragTimer:stop(); dragTimer = nil end
  dragLast = nil
end

local function startDragWatch()
  stopDragWatch()
  if not next(painted) then return end
  dragTimer = hs.timer.doEvery(0.06, function()
    local w = hs.window.focusedWindow()
    local id = windowId(w)
    local z = id and lastStack and lastStack.zOf[id]
    if not z then return end
    local okF, f = pcall(w.frame, w)
    if not okF or not f then return end
    if dragLast and dragLast.id == id and dragLast.x == f.x and dragLast.y == f.y
       and dragLast.w == f.w and dragLast.h == f.h then
      return   -- the button is down but nothing is moving
    end
    dragLast = { id = id, x = f.x, y = f.y, w = f.w, h = f.h }
    lastStack.frames[z] = f
    restack(true)
  end)
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

  -- Fresh claim: the tty->window resolution is an AppleScript round trip, so
  -- it completes in the background and the border appears when it lands.
  resolveTTY(tty, function(win, title)
    if not win then return end
    if painted[tty] then
      obj:paint(tty, color, mode, transcript)   -- a hook raced us; update in place
      return
    end
    local m = mode
    if m == "blink" and windowId(win) == focusedWindowId() then m = "solid" end
    local fresh = { canvas = drawAround(win, hex or "#000000"), color = hex, win = win,
                    mode = m, title = title, transcript = transcript }
    painted[tty] = fresh
    updateVisibility(fresh)
    updateMenubar()
    if transcript then watchTranscript(fresh) end
    syncBlinkTimer()
    restack()   -- punch + order the new canvas before its first frame is seen
  end)
  rec = painted[tty]   -- already set when the resolver completed synchronously
  if rec then
    return ("painted %s (%s) %s %s"):format(tty, rec.title or "?",
                                            rec.color or "no colour", rec.mode)
  end
  return "resolving " .. tty
end

--- ClaudeBorder:mode(tty, mode) -> string
--- Switch an existing border between "solid" and "blink" without redrawing.
--- The same already-focused downgrade as `paint` applies.
function obj:mode(tty, mode)
  local rec = painted[tty]
  if not rec then return "not painted: " .. tostring(tty) end
  if mode == "blink" and windowId(rec.win) == focusedWindowId() then mode = "solid" end
  rec.mode = mode
  if mode ~= "blink" then rec.canvas:alpha(1.0) end
  syncBlinkTimer()
  updateMenubar()
  return tty .. " -> " .. mode
end

--- ClaudeBorder:clear(tty) -> string
function obj:clear(tty)
  local rec = painted[tty]
  if rec then
    if rec.watcher then rec.watcher:stop(); rec.watcher = nil end
    rec.canvas:delete()
    painted[tty] = nil
    syncBlinkTimer()
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
--- Focus the window owning `tty` (switching Space if needed), selecting its
--- tab first when the session lives in a background tab. A waiting border
--- goes solid immediately -- deterministic, rather than waiting for the focus
--- event to arrive.
function obj:focus(tty)
  local rec = painted[tty]
  if not rec then return "not painted: " .. tostring(tty) end
  pcall(function() rec.win:focus() end)   -- instant; the tab select follows
  selectTab(tty)                          -- async, refreshes the tab cache too
  if rec.mode == "blink" then obj:mode(tty, "solid") end
  scheduleRestack()
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
--- Runs every `pruneInterval` seconds; the ps runs asynchronously.
function obj:prune()
  if not next(painted) then return "pruned 0" end
  obj._exec("/bin/ps", { "-axo", "tty=,comm=" }, function(ok, out)
    if not ok or not out:find("%S") then return end   -- never clear on a failed ps
    local live = {}
    for line in out:gmatch("[^\n]+") do
      local t, comm = line:match("^%s*(%S+)%s+(.+)$")
      if t and comm and comm:lower():find("claude", 1, true) then
        live["/dev/" .. t] = true
      end
    end
    for tty in pairs(painted) do
      if not live[tty] then obj:clear(tty) end
    end
  end)
  return "prune requested"
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
  local sessions = {}
  for file in hs.fs.dir(dir) do
    if file:match("^%d+%.json$") then
      local okRead, s = pcall(hs.json.read, dir .. "/" .. file)
      if okRead and s and s.pid and s.sessionId and s.cwd then
        sessions[#sessions + 1] = s
      end
    end
  end
  if #sessions == 0 then return "rescan: no sessions" end
  -- One async ps maps pid -> tty and confirms each is still a claude process
  -- (pids get recycled); the paints then resolve their windows themselves.
  obj._exec("/bin/ps", { "-axo", "pid=,tty=,comm=" }, function(ok, out)
    if not ok then return end
    local ttyOf = {}
    for line in out:gmatch("[^\n]+") do
      local pid, t, comm = line:match("^%s*(%d+)%s+(%S+)%s+(.+)$")
      if pid and comm and comm:lower():find("claude", 1, true) then
        ttyOf[tonumber(pid)] = t
      end
    end
    for _, s in ipairs(sessions) do
      local t = ttyOf[s.pid]
      if t and t ~= "??" and not painted["/dev/" .. t] then
        local slug = s.cwd:gsub("[^%w]", "-")
        local transcript = ("%s/.claude/projects/%s/%s.jsonl"):format(home, slug, s.sessionId)
        if not hs.fs.attributes(transcript) then transcript = nil end
        local color = transcript and lastColorIn(transcript) or nil
        obj:paint("/dev/" .. t, color, (s.status == "busy") and "solid" or "blink", transcript)
      end
    end
  end)
  return ("rescan: checking %d session(s)"):format(#sessions)
end

--- ClaudeBorder:restack() -> string
--- Force an immediate occlusion/visibility/z-order pass. Normally not needed:
--- window events, Space switches, unlocks and the safety poll all schedule one.
function obj:restack()
  restack()
  return "restacked"
end

--- ClaudeBorder:setEnabled(bool) -> string
--- Master switch, also in the menubar item's menu. Disabling hides every
--- border but keeps the sessions tracked (hooks, transcripts, waiting state),
--- so re-enabling brings everything straight back. Persists across
--- Hammerspoon restarts via hs.settings.
function obj:setEnabled(v)
  enabled = v ~= false
  pcall(function() hs.settings.set(obj.settingsKey, enabled) end)
  for _, rec in pairs(painted) do updateVisibility(rec) end
  updateMenubar()
  if enabled then scheduleRestack() end
  return "enabled=" .. tostring(enabled)
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
    obj:setVisible(front ~= nil and isTerminalApp(front:name()))
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

  -- Bound every Accessibility round trip. A busy app (a Terminal printing
  -- Claude output, say) answers AX messages late, and the DEFAULT messaging
  -- timeout is several seconds -- one slow window frame read then stalls a
  -- whole restack (observed: a single 1.6s spike). 0.5s keeps the worst case
  -- bounded; a window that can't answer in time is treated as stale and
  -- healed asynchronously like any other.
  pcall(function()
    require("hs.axuielement").systemWideElement():setTimeout(0.5)
  end)

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
    -- A tab switch usually renames the window; the 2s poll catches the rest.
    hs.window.filter.windowTitleChanged,
  }, function(win, _, event)
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
    -- A title change usually means a tab switch: refetch the selected tabs.
    if event == hs.window.filter.windowTitleChanged then selCacheAt = 0 end
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
      if obj.autoHide then obj:setVisible(isTerminalApp(name)) end
      scheduleRestack()
    end
  end)
  appWatcher:start()
  obj._appWatcher = appWatcher

  -- Space switches change which windows exist without any window event.
  spaceWatcher = hs.spaces.watcher.new(scheduleRestack)
  spaceWatcher:start()
  obj._spaceWatcher = spaceWatcher

  -- Clicks change z-order immediately; window-filter events about it arrive
  -- late. React to the input itself, and follow drags live (see above).
  local types = hs.eventtap.event.types
  dragTap = hs.eventtap.new({ types.leftMouseDown, types.leftMouseUp }, function(e)
    if e:getType() == types.leftMouseDown then
      scheduleRestack()   -- the click may have raised the window under it
      startDragWatch()
    else
      stopDragWatch()
      scheduleRestack()   -- release: z-order and frame are settled
    end
    return false
  end)
  dragTap:start()
  obj._dragTap = dragTap

  -- A locked screen degrades the Accessibility API system-wide: windows
  -- enumerate but report no frames, so any paint attempted while locked fails
  -- with "no window". Rescan (idempotent) once the session is usable again.
  -- Retry the unlock rescan: AX is often STILL degraded a couple of seconds
  -- after unlock, so a single shot can fire into the same wall it is healing.
  powerWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.screensDidUnlock
       or event == hs.caffeinate.watcher.sessionDidBecomeActive
       or event == hs.caffeinate.watcher.systemDidWake then
      for _, delay in ipairs({ 2, 6, 15 }) do
        after(delay, function() obj:rescan() end)
      end
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

  -- Re-adopt any live session that lost its border (idempotent, see
  -- rescanInterval). Not while locked: no paint can succeed there.
  if obj.rescanInterval and obj.rescanInterval > 0 then
    obj._rescanTimer = hs.timer.doEvery(obj.rescanInterval, function()
      local locked = hs.caffeinate.sessionProperties()["CGSSessionScreenIsLocked"]
      if not locked then obj:rescan() end
    end)
  end

  -- Jump to the next waiting session from anywhere.
  if obj.focusHotkey then
    hotkeyObj = hs.hotkey.bind(obj.focusHotkey[1], obj.focusHotkey[2],
                               function() obj:focusNextWaiting() end)
    obj._hotkey = hotkeyObj
  end

  local front = hs.application.frontmostApplication()
  shown = (not obj.autoHide) or (front ~= nil and isTerminalApp(front:name()))

  -- The user's last Enable/Disable choice survives a restart; the menubar
  -- item is persistent, so it exists (as the idle glyph) from the start.
  local okS, stored = pcall(function() return hs.settings.get(obj.settingsKey) end)
  enabled = not (okS and stored == false)
  updateMenubar()

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
  if obj._rescanTimer then obj._rescanTimer:stop(); obj._rescanTimer = nil end
  if hotkeyObj then hotkeyObj:delete(); hotkeyObj = nil; obj._hotkey = nil end
  if bar then bar:delete(); bar = nil end
  if pillCanvas then pillCanvas:delete(); pillCanvas = nil; obj._pill = nil end
  if dragTap then dragTap:stop(); dragTap = nil; obj._dragTap = nil end
  stopDragWatch()
  if blinkTimer then blinkTimer:stop(); blinkTimer = nil end
  if restackDelayed then restackDelayed:stop() end
  cancelPending()
  cancelTasks()
  return self
end

return obj
