-- Headless test harness for ClaudeBorder v2.0.
-- Stubs the AX/AppleScript layer with fake windows so occlusion punching,
-- visibility, z-ordering and blink can be verified while the screen is locked.
-- Runs inside one synchronous hs -c eval; all stubs are restored before return.

local results = {}
local function check(name, cond, detail)
  results[#results + 1] = (cond and "PASS " or "FAIL ") .. name .. (detail and (" [" .. tostring(detail) .. "]") or "")
end

-- ---------------------------------------------------------------- stubs
local realOrdered   = hs.window.orderedWindows
local realAppGet    = hs.application.get
local realOsascript = hs.osascript.applescript
local realCanvasNew = hs.canvas.new
local realFocused   = hs.window.focusedWindow

local function fakeWin(id, x, y, w, h)
  return {
    id    = function() return id end,
    frame = function() return { x = x, y = y, w = w, h = h } end,
  }
end

-- Three fake terminal windows + one plain occluder window:
--   z1 = plain window (Finder-like), frontmost
--   z2 = bordered terminal A
--   z3 = bordered terminal B (overlapped by both above)
local winPlain = fakeWin(101, 350, 100, 200, 200)
local winA     = fakeWin(102, 100, 100, 300, 300)
local winB     = fakeWin(103, 250, 250, 300, 300)
local orderedStub = { winPlain, winA, winB }

local ttyWin = { ["/dev/ttyTEST_A"] = winA, ["/dev/ttyTEST_B"] = winB }

hs.window.orderedWindows = function() return orderedStub end
hs.window.focusedWindow = function() return nil end
hs.osascript.applescript = function(script)
  for tty, w in pairs(ttyWin) do
    if script:find(tty, 1, true) then
      local f = w.frame()
      return true, { f.x, f.y, f.x + f.w, f.y + f.h, "stub " .. tty }
    end
  end
  return true, {}
end
hs.application.get = function(name)
  if name ~= "Terminal" then return nil end
  local wins = {}
  for _, w in pairs(ttyWin) do wins[#wins + 1] = w end
  return { allWindows = function() return wins end }
end

local madeCanvases = {}
hs.canvas.new = function(...)
  local c = realCanvasNew(...)
  madeCanvases[#madeCanvases + 1] = c
  return c
end

-- ---------------------------------------------------------------- dev instance
local ok, err = pcall(function()
  local dev = dofile(os.getenv("HOME") .. "/.hammerspoon/Spoons/ClaudeBorder.spoon/init.lua")
  local W = dev.width      -- 5
  local R = dev.radius     -- 11

  -- B first so A's canvas is created second (ordering must not depend on it)
  local resB = dev:paint("/dev/ttyTEST_B", "blue", "blink")
  local resA = dev:paint("/dev/ttyTEST_A", "red", "solid")
  check("paint A returns painted", resA:match("^painted") ~= nil, resA)
  check("paint B returns painted", resB:match("^painted") ~= nil, resB)
  check("two canvases created", #madeCanvases == 2, #madeCanvases)

  local cB, cA = madeCanvases[1], madeCanvases[2]

  -- A (z2): occluded only by the plain window (z1), pad 0.
  -- canvas origin = (100-5, 100-5); occluder at 350,100 200x200
  check("A hole count", #cA == 2, #cA)
  if #cA >= 2 then
    local h = cA[2].frame
    check("A hole x", h.x == 350 - 95, h.x)
    check("A hole y", h.y == 100 - 95, h.y)
    check("A hole w", h.w == 200, h.w)
    check("A hole h", h.h == 200, h.h)
    check("A hole is clear", tostring(cA[2].compositeRule) == "clear", cA[2].compositeRule)
    check("A hole radius", cA[2].roundedRectRadii.xRadius == R, cA[2].roundedRectRadii.xRadius)
  end

  -- B (z3): occluded by plain (pad 0) and by bordered A (pad = width).
  check("B hole count", #cB == 3, #cB)
  if #cB >= 3 then
    -- holes appended in z order: plain first, then A
    local hPlain, hA = cB[2].frame, cB[3].frame
    check("B plain hole x", hPlain.x == 350 - 245, hPlain.x)
    check("B A-hole inflated x", hA.x == (100 - W) - 245, hA.x)
    check("B A-hole inflated w", hA.w == 300 + 2 * W, hA.w)
    check("B A-hole radius", cB[3].roundedRectRadii.xRadius == R + W, cB[3].roundedRectRadii.xRadius)
  end

  -- Visibility: both on screen, coloured -> showing.
  check("A showing", cA:isShowing(), tostring(cA:isShowing()))
  check("B showing", cB:isShowing(), tostring(cB:isShowing()))

  -- Blink: B blinks (not focused), A solid.
  check("list shows modes", dev:list():find("ttyTEST_B #0a84ff blink", 1, true) ~= nil, dev:list())

  -- Focus downgrade: blink request on the focused window becomes solid.
  hs.window.focusedWindow = function() return winB end
  local m = dev:mode("/dev/ttyTEST_B", "blink")
  check("blink on focused window downgrades", m:find("solid") ~= nil, m)
  hs.window.focusedWindow = function() return nil end

  -- Repainting an alive tty updates in place: no new canvas, "(updated)".
  local resA2 = dev:paint("/dev/ttyTEST_A", "green", "solid")
  check("repaint updates in place", resA2:find("updated") ~= nil, resA2)
  check("repaint recolours", dev:list():find("ttyTEST_A #32d74b", 1, true) ~= nil, dev:list())
  check("no extra canvas on repaint", #madeCanvases == 2, #madeCanvases)

  -- Take B off screen (e.g. other Space): border must hide.
  orderedStub = { winPlain, winA }
  dev:restack()
  check("B hidden when off screen", not cB:isShowing(), tostring(cB:isShowing()))
  check("A still showing", cA:isShowing(), tostring(cA:isShowing()))

  -- Bring B back: restack must show it again.
  orderedStub = { winPlain, winA, winB }
  dev:restack()
  check("B shown again when back on screen", cB:isShowing(), tostring(cB:isShowing()))

  -- A punches B? No: B is BEHIND A (z3 > z2) -> no hole for B.
  check("A punches only windows in front", #cA == 2, #cA)

  -- No-colour session: nothing drawn.
  local winC = fakeWin(104, 600, 600, 100, 100)
  ttyWin["/dev/ttyTEST_C"] = winC
  orderedStub = { winPlain, winA, winB, winC }
  dev:paint("/dev/ttyTEST_C", "unknown", "solid")
  local cC = madeCanvases[#madeCanvases]
  check("unknown colour draws nothing", not cC:isShowing(), tostring(cC:isShowing()))

  -- Hex colour accepted.
  local resHex = dev:paint("/dev/ttyTEST_C", "#123abc", "solid")
  check("raw hex accepted", resHex:find("#123abc") ~= nil, resHex)

  -- clear() releases everything.
  dev:clearAll()
  check("clearAll empties list", dev:list() == "", dev:list())
end)

-- ---------------------------------------------------------------- restore
hs.window.orderedWindows = realOrdered
hs.window.focusedWindow = realFocused
hs.application.get = realAppGet
hs.osascript.applescript = realOsascript
hs.canvas.new = realCanvasNew
for _, c in ipairs(madeCanvases) do pcall(function() c:delete() end) end

if not ok then results[#results + 1] = "ERROR: " .. tostring(err) end
return table.concat(results, "\n")
