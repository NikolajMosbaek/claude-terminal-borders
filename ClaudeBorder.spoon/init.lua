--- === ClaudeBorder ===
---
--- Per-session coloured borders around macOS Terminal.app windows, so several
--- concurrent Claude Code sessions are distinguishable at a glance.
---
--- A border is claimed by a tty, coloured from that session's `/color`, and
--- blinks while Claude is waiting for input.
---
--- Download: https://github.com/NikolajMosbaek/claude-terminal-borders

local obj = {}
obj.__index = obj

obj.name     = "ClaudeBorder"
obj.version  = "1.0"
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
--- Show borders only while Terminal is the active application.
---
--- hs.canvas has no window level between "behind my own window" and "above
--- everything", so a border necessarily floats over other applications. Hiding
--- it whenever Terminal is not frontmost sidesteps that: a border over another
--- app's window only matters while you are using that app.
obj.autoHide = true

--- ClaudeBorder.colors (Table)
--- Maps Claude Code's eight /color names to hex. A raw "#rrggbb" also works
--- anywhere a colour name is accepted.
obj.colors = {
  red    = "#ff453a", orange = "#ff9f0a", yellow = "#ffd60a", green = "#32d74b",
  cyan   = "#64d2ff", blue   = "#0a84ff", purple = "#bf5af0", pink   = "#ff375f",
}

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

local painted   = {}      -- [tty] = { canvas, color, mode, timer, win, title }
local shown     = true
local reflowing = false
local wf, appWatcher

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
  c:show()
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
-- Public API
--------------------------------------------------------------------------------

--- ClaudeBorder:paint(tty, color[, mode]) -> string
--- Claim the Terminal window owning `tty`. `mode` is "solid" (default) or "blink".
function obj:paint(tty, color, mode)
  local hex = obj.colors[color] or color
  local win, title = windowForTTY(tty)
  if not win then return "no window for " .. tostring(tty) end
  obj:clear(tty)
  local rec = { canvas = drawAround(win, hex), color = hex, win = win,
                mode = mode or "solid", title = title }
  painted[tty] = rec
  if not shown then rec.canvas:hide() end
  if rec.mode == "blink" then startBlink(rec) end
  return ("painted %s (%s) %s %s"):format(tty, title, hex, rec.mode)
end

--- ClaudeBorder:mode(tty, mode) -> string
--- Switch an existing border between "solid" and "blink" without redrawing.
function obj:mode(tty, mode)
  local rec = painted[tty]
  if not rec then return "not painted: " .. tostring(tty) end
  rec.mode = mode
  if mode == "blink" then
    startBlink(rec)
  else
    stopTimer(rec)
    rec.canvas:alpha(1.0)
  end
  return tty .. " -> " .. mode
end

--- ClaudeBorder:clear(tty) -> string
function obj:clear(tty)
  local rec = painted[tty]
  if rec then
    stopTimer(rec)
    rec.canvas:delete()
    painted[tty] = nil
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
    out[#out + 1] = ("%s %s %s"):format(tty, rec.color, rec.mode)
  end
  table.sort(out)
  return table.concat(out, "\n")
end

--- ClaudeBorder:setVisible(bool) -> string
function obj:setVisible(v)
  shown = v
  for _, rec in pairs(painted) do
    if v then rec.canvas:show() else rec.canvas:hide() end
  end
  return "visible=" .. tostring(v)
end

--- ClaudeBorder:setAutoHide(bool) -> string
function obj:setAutoHide(v)
  obj.autoHide = v
  if not v then obj:setVisible(true) end
  return "autohide=" .. tostring(obj.autoHide)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function reflow()
  if reflowing then return end       -- canvas ops can re-enter this
  reflowing = true
  for tty, rec in pairs(painted) do
    local ok, f = pcall(function() return rec.win and rec.win:frame() end)
    if not ok or not f then
      local win = windowForTTY(tty)  -- cache stale: re-resolve through Terminal
      if win then rec.win = win; f = win:frame() end
    end
    if f then positionCanvas(rec.canvas, f) else obj:clear(tty) end
  end
  reflowing = false
end

--- ClaudeBorder:start() -> self
function obj:start()
  require("hs.ipc")   -- enables the `hs` command line tool

  wf = hs.window.filter.new("Terminal")
  obj._wf = wf        -- retained: a collected filter silently drops subscriptions

  -- windowMoved also covers resizes; hs.window.filter has no windowResized.
  wf:subscribe({
    hs.window.filter.windowMoved,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowMinimized,
    hs.window.filter.windowUnminimized,
  }, reflow)

  -- Focusing a window means you have seen it, so stop its blink without waiting
  -- for a prompt. Safe here because :mode() only stops a timer and sets alpha.
  -- Calling canvas:show() from a window-event handler re-triggers window events
  -- and overflows the Lua stack -- do not add one.
  wf:subscribe(hs.window.filter.windowFocused, function(win)
    if not win then return end
    local okId, focusedId = pcall(function() return win:id() end)
    if not okId then return end
    for tty, rec in pairs(painted) do
      if rec.mode == "blink" and rec.win then
        local ok, id = pcall(function() return rec.win:id() end)
        if ok and id == focusedId then obj:mode(tty, "solid") end
      end
    end
  end)

  -- App activation, deliberately not window focus, for the show/hide channel.
  appWatcher = hs.application.watcher.new(function(name, event)
    if obj.autoHide and event == hs.application.watcher.activated then
      obj:setVisible(name == "Terminal")
    end
  end)
  appWatcher:start()
  obj._appWatcher = appWatcher

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
      obj:paint(p.tty, p.color, p.mode)
    elseif p.mode then
      obj:mode(p.tty, p.mode)
    end
  end)
  hs.urlevent.bind("borderoff", function() obj:clearAll() end)

  return self
end

--- ClaudeBorder:stop() -> self
function obj:stop()
  obj:clearAll()
  if wf then wf:unsubscribeAll(); wf = nil; obj._wf = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil; obj._appWatcher = nil end
  return self
end

return obj
