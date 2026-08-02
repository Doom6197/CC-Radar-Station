-- Smoke-test harness: mocks CC:Tweaked and Basalt, then exercises every
-- module and every canvas draw callback at a range of screen sizes.

local PROJ = ...
package.path = PROJ .. "/?.lua;" .. package.path

------------------------------------------------------------------ CC mocks --

colors = {}
local names = { "white","orange","magenta","lightBlue","yellow","lime","pink",
  "gray","lightGray","cyan","purple","blue","brown","green","red","black" }
for i, n in ipairs(names) do colors[n] = 2 ^ (i - 1) end

keys = {}
do
  local k = 0
  for _, n in ipairs({ "one","two","three","four","five","six","seven","eight","nine","zero",
    "up","down","left","right","a","b","c","d","e","f","g","h","i","j","k","l","m","n","o",
    "p","q","r","s","t","u","v","w","x","y","z","backspace","enter","pageUp","pageDown" }) do
    k = k + 1; keys[n] = k
  end
end

local FILES = {}
fs = {
  exists = function(p) return FILES[p] ~= nil end,
  open = function(p, mode)
    if mode:sub(1,1) == "r" then
      if not FILES[p] then return nil end
      return { readAll = function() return FILES[p] end, close = function() end }
    end
    local buf = {}
    return {
      write = function(s) buf[#buf+1] = s end,
      close = function() FILES[p] = table.concat(buf) end,
    }
  end,
  getDir = function(p) return (p:match("^(.*)/[^/]*$")) or "" end,
  combine = function(a, b)
    if a == "" then return b end
    return a .. "/" .. b
  end,
}

textutils = {
  serialize = function(t)
    local function ser(v, seen)
      if type(v) == "table" then
        seen = seen or {}
        if seen[v] then return "nil" end
        seen[v] = true
        local out = {"{"}
        for k, val in pairs(v) do
          out[#out+1] = "[" .. ser(k, seen) .. "]=" .. ser(val, seen) .. ","
        end
        out[#out+1] = "}"
        return table.concat(out)
      elseif type(v) == "string" then return string.format("%q", v)
      else return tostring(v) end
    end
    return ser(t)
  end,
  unserialize = function(s)
    local f = load("return " .. s)
    return f and f() or nil
  end,
  formatTime = function(t) return string.format("%02d:%02d", math.floor(t), 0) end,
}

local CLOCK = 0
os.clock = function() return CLOCK end
os.day = function() return 142 end
os.time = function() return 9.5 end
os.pullEvent = function() error("pullEvent should not run in the harness", 0) end
os.epoch = function() return 0 end
os.getComputerID = function() return 3 end

function sleep(_) error("sleep should not run in the harness", 0) end

local PERIPHERALS = {}
peripheral = {
  isPresent = function(side) return PERIPHERALS[side] ~= nil end,
  wrap = function(name) return PERIPHERALS[name] end,
  getNames = function()
    local out = {}
    for name in pairs(PERIPHERALS) do
      if not name:match("^back$|^front$") then out[#out+1] = name end
    end
    table.sort(out)
    return out
  end,
  getType = function(name)
    local p = PERIPHERALS[name]
    return p and p.__type or "unknown"
  end,
}

redstone = {
  getSides = function() return { "top","bottom","left","right","front","back" } end,
  setAnalogOutput = function() end,
}

-- rednet, as a loopback: everything broadcast lands in SENT, and a test posts
-- to INBOX whatever it wants the station to have received.
local REDNET = { open = {}, sent = {}, inbox = {} }
rednet = {
  open = function(name) REDNET.open[name] = true end,
  close = function(name) REDNET.open[name] = nil end,
  isOpen = function(name) return REDNET.open[name] == true end,
  broadcast = function(message, protocol)
    REDNET.sent[#REDNET.sent + 1] = { message = message, protocol = protocol }
  end,
  send = function(id, message, protocol)
    REDNET.sent[#REDNET.sent + 1] = { id = id, message = message, protocol = protocol }
  end,
  receive = function(_, _)
    local entry = table.remove(REDNET.inbox, 1)
    if not entry then return nil end
    return entry.id, entry.message, entry.protocol
  end,
}

--- Last thing broadcast on a protocol with the given payload type.
local function lastSent(kind)
  for i = #REDNET.sent, 1, -1 do
    local entry = REDNET.sent[i]
    if type(entry.message) == "table" and entry.message.t == kind then return entry end
  end
  return nil
end

term = {
  setBackgroundColor = function() end, setTextColor = function() end,
  clear = function() end, setCursorPos = function() end,
  getSize = function() return 51, 19 end, blit = function() end,
  setCursorBlink = function() end, current = function() return term end,
  native = function() return term end,
}
shell = { getRunningProgram = function() return "radar.lua" end }

--------------------------------------------------------------- Basalt mock --

local rgbRegistry, rgbNext = {}, 0x10000
local basalt = {}
function basalt.rgb(hex)
  if rgbRegistry[hex] then return rgbRegistry[hex] end
  rgbNext = rgbNext + 1
  rgbRegistry[hex] = rgbNext
  return rgbNext
end
basalt.state = function(v) return { get = function() return v end } end
basalt.computed = basalt.state
basalt.schedule = function(fn) return fn end   -- never actually run here
basalt.run = function() end
basalt.stop = function() end
basalt.use = function() return {} end

local RAW_PROPS = { draw = true, toastColors = true }

local elementMethods = {}
local elementMt = {
  __index = function(t, k)
    local v = rawget(t, "_p")[k]
    if v ~= nil then
      if type(v) == "function" and not RAW_PROPS[k] then return v(t) end
      return v
    end
    return elementMethods[k]
  end,
  __newindex = function(t, k, v) rawget(t, "_p")[k] = v end,
}

local function newElement(kind, props, parent)
  local el = setmetatable({ _p = {}, _children = {}, _handlers = {}, __kind = kind }, elementMt)
  rawset(el, "parent", parent)
  rawset(el, "__name", kind)
  el._p.width = 10; el._p.height = 3; el._p.x = 1; el._p.y = 1; el._p.visible = true
  el._p.items = {}
  for k, v in pairs(props or {}) do el._p[k] = v end
  if parent then table.insert(rawget(parent, "_children"), el) end
  return el
end

local ADDERS = { "Frame","Canvas","Label","Button","Input","List","Toast","ProgressBar","Switch","Slider" }
for _, kind in ipairs(ADDERS) do
  elementMethods["add" .. kind] = function(self, props)
    return newElement(kind, props, self)
  end
end

function elementMethods:getChildren() return rawget(self, "_children") end
function elementMethods:markRenderDirty() return self end
function elementMethods:markDirty() return self end
function elementMethods:markLayoutDirty() return self end
function elementMethods:getFocused() return nil end
function elementMethods:setFocused() end
function elementMethods:destroy()
  local p = rawget(self, "parent")
  if p then
    local kids = rawget(p, "_children")
    for i = #kids, 1, -1 do if kids[i] == self then table.remove(kids, i) end end
  end
  return self
end
function elementMethods:clear() self._p.items = {}; return self end
function elementMethods:addItem(item)
  local list = rawget(self, "_p").items
  list[#list + 1] = item
  return item
end
function elementMethods:show() return self end
function elementMethods:hide() return self end
for _, ev in ipairs({ "onClick","onEnter","onBlur","onChange","onSelect","onScroll","onKey","onFocus" }) do
  elementMethods[ev] = function(self, fn)
    rawget(self, "_handlers")[ev] = fn
    return self
  end
end

local ROOTS = {}
function basalt.createFrame(t, name)
  local w, h = 51, 19
  if t and t.getSize then w, h = t.getSize() end
  local root = newElement("BaseFrame", { width = w, height = h }, nil)
  rawset(root, "monitorName", name)
  ROOTS[#ROOTS + 1] = root
  return root
end
local mainFrame
function basalt.getMainFrame()
  if not mainFrame then mainFrame = basalt.createFrame(term) end
  return mainFrame
end

package.loaded.basalt = basalt

--------------------------------------------------------------- mock buffer --

local Buffer = {}
Buffer.__index = Buffer
local function newBuffer(w, h, label)
  return setmetatable({ w = w, h = h, label = label, writes = 0 }, Buffer)
end

local function checkColor(self, c, where)
  if c == nil or c == false then return end
  if type(c) ~= "number" then
    error(("%s: %s got a non-colour %s"):format(self.label, where, tostring(c)), 0)
  end
end

function Buffer:fill(x, y, w, h, ch, fg, bg)
  if type(ch) ~= "string" or #ch ~= 1 then
    error(("%s: fill needs a single character, got %q"):format(self.label, tostring(ch)), 0)
  end
  checkColor(self, fg, "fill fg"); checkColor(self, bg, "fill bg")
  self.writes = self.writes + 1
end

function Buffer:blit(x, y, str, fg, bg)
  if type(str) ~= "string" then
    error(("%s: blit needs a string, got %s"):format(self.label, tostring(str)), 0)
  end
  if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then
    error(("%s: blit at bad position %s,%s"):format(self.label, tostring(x), tostring(y)), 0)
  end
  checkColor(self, fg, "blit fg"); checkColor(self, bg, "blit bg")
  self.writes = self.writes + 1
end

function Buffer:drawText(x, y, str) return self:blit(x, y, str) end

function Buffer:colorBlit(x, y, str, fgs, bgs)
  if type(str) ~= "string" then
    error(self.label .. ": colorBlit needs a string", 0)
  end
  for i = 1, #str do
    if fgs[i] == nil then error(("%s: colorBlit fg[%d] is nil (len %d)"):format(self.label, i, #str), 0) end
    if bgs[i] == nil then error(("%s: colorBlit bg[%d] is nil (len %d)"):format(self.label, i, #str), 0) end
    checkColor(self, fgs[i], "colorBlit fg"); checkColor(self, bgs[i], "colorBlit bg")
  end
  self.writes = self.writes + 1
end

--------------------------------------------------------------------- tests --

local failures, checks = {}, 0
local function check(name, fn)
  checks = checks + 1
  local ok, err = pcall(fn)
  if not ok then failures[#failures + 1] = name .. "  ->  " .. tostring(err) end
end

local util   = require("radar.util")
local theme  = require("radar.theme")
local pixel  = require("radar.pixel")
local glyphs = require("radar.glyphs")
local sky    = require("radar.sky")
local biomes = require("radar.biomes")
local config = require("radar.config")
local environment = require("radar.environment")

-- util ----------------------------------------------------------------------
check("util.directionOf", function()
  assert(util.directionOf(0, -10) == "N", "north")
  assert(util.directionOf(10, 0) == "E", "east")
  assert(util.directionOf(0, 10) == "S", "south")
  assert(util.directionOf(-10, 0) == "W", "west")
  assert(util.directionOf(10, -10) == "NE", "north-east")
end)

check("util.fit", function()
  assert(util.fit("abc", 5) == "abc  ", "pad right")
  assert(util.fit("abc", 5, true) == "  abc", "pad left")
  assert(util.fit("abcdef", 3) == "abc", "truncate")
end)

check("util.rotateXZ", function()
  local x, z = util.rotateXZ(0, -10, 90)
  assert(math.abs(x - -10) < 0.001 and math.abs(z - 0) < 0.001,
    ("north rotates to the left, got %.3f %.3f"):format(x, z))
end)

-- heading maths ---------------------------------------------------------------
check("util.headingOf turns yaw into a bearing", function()
  -- Minecraft yaw 0 faces south, and grows westward.
  assert(util.headingOf(0) == 180, "yaw 0 faces south, got " .. tostring(util.headingOf(0)))
  assert(util.headingOf(90) == 270, "yaw 90 faces west, got " .. tostring(util.headingOf(90)))
  assert(util.headingOf(180) == 0, "yaw 180 faces north, got " .. tostring(util.headingOf(180)))
  assert(util.headingOf(-90) == 90, "yaw -90 faces east, got " .. tostring(util.headingOf(-90)))
  assert(util.headingOf(540) == 0, "wraps past a full turn")
  assert(util.headingOf(nil) == nil, "no yaw, no heading")
  assert(util.headingOf("nonsense") == nil, "junk yaw, no heading")
end)

check("util.angleDelta takes the short way round", function()
  assert(util.angleDelta(350, 10) == 20, "across north, got " .. util.angleDelta(350, 10))
  assert(util.angleDelta(10, 350) == -20, "back across north")
  assert(util.angleDelta(0, 0) == 0, "no turn")
  for a = 0, 359, 7 do
    for b = 0, 359, 11 do
      local d = util.angleDelta(a, b)
      assert(d >= -180 and d < 180, ("delta in range for %d->%d: %s"):format(a, b, d))
    end
  end
end)

check("util.approachAngle converges without spinning", function()
  local at = 350
  for _ = 1, 40 do at = util.approachAngle(at, 10, 0.34) end
  assert(math.abs(util.angleDelta(at, 10)) < 0.5,
    "eased across north to the target, ended at " .. at)
  -- Every intermediate value has to stay on the short arc.
  local step = util.approachAngle(350, 10, 0.5)
  assert(step >= 359 or step <= 1, "halfway across north is near 0, got " .. step)
end)

check("util.snapAngle quantises", function()
  assert(util.snapAngle(100, 45) == 90, "snaps down, got " .. util.snapAngle(100, 45))
  assert(util.snapAngle(115, 45) == 135, "snaps up")
  assert(util.snapAngle(350, 45) == 0, "snaps across north, got " .. util.snapAngle(350, 45))
  assert(util.snapAngle(123.4, 0) == 123.4, "a zero step is free rotation")
  assert(util.snapAngle(-10, 0) == 350, "still wrapped into range")
end)

-- biomes ----------------------------------------------------------------------
check("biomes.classify resolves the awkward names", function()
  local cases = {
    ["minecraft:cherry_grove"]    = "cherry",       -- not the snowy "grove"
    ["minecraft:mangrove_swamp"]  = "mangrove",     -- also not "grove"
    ["minecraft:grove"]           = "snowyForest",  -- the real one
    ["minecraft:snowy_taiga"]     = "snowyForest",
    ["minecraft:desert"]          = "desert",
    ["minecraft:badlands"]        = "badlands",
    ["minecraft:wooded_badlands"] = "badlands",
    ["minecraft:deep_dark"]       = "deepDark",
    ["minecraft:lush_caves"]      = "lushCaves",
    ["minecraft:the_void"]        = "void",
    ["minecraft:ice_spikes"]      = "iceSpikes",
    ["minecraft:jagged_peaks"]    = "snowyPeaks",
    ["minecraft:stony_peaks"]     = "peaks",
    ["minecraft:warm_ocean"]      = "ocean",
    ["minecraft:beach"]           = "shore",
    ["minecraft:bamboo_jungle"]   = "bamboo",
    ["minecraft:dark_forest"]     = "darkForest",
    ["minecraft:birch_forest"]    = "birch",
    ["minecraft:sunflower_plains"] = "meadow",
    ["biomesoplenty:mystic_grove"] = "forest",      -- modded, falls to "forest"? see below
  }
  for id, want in pairs(cases) do
    local got = biomes.classify(id, "overworld")
    if id ~= "biomesoplenty:mystic_grove" then
      assert(got == want, ("%s -> %s, wanted %s"):format(id, got, want))
    end
  end
  -- Anything unrecognised still lands somewhere drawable.
  assert(biomes.PROFILES[biomes.classify("somemod:utterly_unknown", "overworld")],
    "unknown biomes fall back to a real profile")
  assert(biomes.classify(nil, "overworld") == biomes.DEFAULT, "no biome at all")
  -- The dimension outranks the name.
  assert(biomes.classify("minecraft:plains", "the_end") == "theEnd", "end dimension wins")
  assert(biomes.PROFILES[biomes.classify("somemod:weird", "nether")].terrain == "nether",
    "nether dimension always gets a nether profile")
  assert(biomes.classify("minecraft:crimson_forest", "nether") == "crimsonForest")
end)

check("every biome profile is complete and drawable", function()
  for kind, profile in pairs(biomes.PROFILES) do
    assert(type(profile.label) == "string" and #profile.label > 0, kind .. " has a label")
    assert(type(profile.terrain) == "string", kind .. " names a terrain")
    assert(type(profile.flora) == "string", kind .. " names a flora")
    assert(profile.flora == "none" or sky.FLORA[profile.flora],
      kind .. " flora " .. profile.flora .. " has a painter")
    -- nether, end and cavern grounds are drawn by their own routines.
    assert(sky.TERRAIN[profile.terrain]
      or profile.terrain == "nether" or profile.terrain == "end"
      or profile.terrain == "cavern",
      kind .. " terrain " .. profile.terrain .. " has a painter")
    for _, key in ipairs({ "land", "shade", "accent" }) do
      assert(profile[key]:match("^#%x%x%x%x%x%x$"),
        ("%s.%s is a hex colour, got %s"):format(kind, key, tostring(profile[key])))
    end
  end
  assert(#biomes.ids() == (function()
    local n = 0
    for _ in pairs(biomes.PROFILES) do n = n + 1 end
    return n
  end)(), "ids() lists every profile exactly once")
end)

check("biomes.shade stays inside the colour space", function()
  for _, mood in ipairs({ "day", "dawn", "dusk", "night", "rain", "rainNight",
                          "storm", "snow", "snowNight" }) do
    for kind in pairs(biomes.PROFILES) do
      local land, shade, accent = biomes.groundColors(kind, mood)
      for _, hex in ipairs({ land, shade, accent }) do
        assert(hex:match("^#%x%x%x%x%x%x$"),
          ("%s/%s produced %s"):format(kind, mood, tostring(hex)))
      end
    end
  end
end)

-- config ----------------------------------------------------------------------
check("config.sanitise clamps rubbish", function()
  local cfg = config.sanitise({ rangeIndex = 999, rotation = -45, mode = "wat",
    sound = { volume = 99 }, rs = { mode = "nope" }, displays = { m = 5 } })
  assert(cfg.rangeIndex == #config.RANGES, "range clamped")
  assert(cfg.rotation == 315, "rotation wrapped, got " .. cfg.rotation)
  assert(cfg.mode == "fixed", "mode reset")
  assert(cfg.sound.volume == 3, "volume clamped")
  assert(cfg.rs.mode == "pulse", "redstone mode reset")
  assert(type(cfg.displays.m) == "table", "display entry repaired")
end)

check("config.load with no files", function()
  local cfg, log, ignore = config.load()
  assert(type(cfg) == "table" and type(log) == "table" and type(ignore) == "table")
  assert(config.rangeLabel(cfg) == "MAX")
end)

check("config migrates a v3 file", function()
  FILES["radar.cfg"] = textutils.serialize({
    termStyleIndex = 3, rotation = 90, mode = "fixed", baseX = 10,
    displays = { ["monitor_0"] = { styleIndex = 4, scale = 1.0 } },
  })
  local cfg, _, _, imported = config.load()
  assert(cfg.terminalPage == "contacts", "v3 style 3 becomes contacts, got " .. tostring(cfg.terminalPage))
  assert(cfg.displays.monitor_0.page == "log", "v3 monitor style 4 becomes log")
  assert(imported, "flagged as an upgrade")
  FILES["radar.cfg"] = nil
end)

-- environment -----------------------------------------------------------------
check("environment clock and phases", function()
  assert(environment.clockOf(0) == "06:00", "tick 0 is dawn, got " .. environment.clockOf(0))
  assert(environment.clockOf(6000) == "12:00", "tick 6000 is noon")
  assert(environment.clockOf(18000) == "00:00", "tick 18000 is midnight")
  assert(environment.phaseOf(500) == "dawn")
  assert(environment.phaseOf(6000) == "day")
  assert(environment.phaseOf(12000) == "dusk")
  assert(environment.phaseOf(18000) == "night")
end)

check("environment celestial arc stays in range", function()
  for tick = 0, 23999, 137 do
    local body, u = environment.celestial(tick)
    assert(body == "sun" or body == "moon", "a body is chosen")
    assert(u >= 0 and u <= 1, ("progress in range at %d: %s"):format(tick, tostring(u)))
  end
end)

check("environment.describe covers every combination", function()
  local biomes = { "minecraft:plains", "minecraft:desert", "minecraft:snowy_taiga",
    "minecraft:the_void", nil }
  local dims = { "minecraft:overworld", "minecraft:the_nether", "minecraft:the_end" }
  for _, dim in ipairs(dims) do
    for bi = 1, 5 do
      for _, raining in ipairs({ true, false }) do
        for _, thunder in ipairs({ true, false }) do
          for tick = 0, 23000, 1000 do
            local snap = {
              tick = tick, day = 1, kind = environment.dimensionKind(dim),
              phase = environment.phaseOf(tick), raining = raining,
              thundering = thunder, biome = biomes[bi], moonId = tick % 8,
              moonName = "Full Moon",
            }
            snap.body, snap.bodyProgress = environment.celestial(tick)
            local scene = environment.describe(snap)
            assert(type(scene.palette) == "table" and #scene.palette == 10,
              "ten-entry palette for " .. dim .. " " .. tostring(scene.weather))
            assert(scene.title and #scene.title > 0, "a title")
          end
        end
      end
    end
  end
end)

-- pixel + sky ------------------------------------------------------------------
check("pixel grid compiles cells", function()
  local pal = { theme.tones.bg, theme.tones.text, theme.tones.accent }
  local grid = pixel.new(6, 4, pal)
  grid:clear(1)
  grid:disc(6, 6, 3, 2)
  grid:line(1, 1, 12, 12, 3)
  grid:ring(6, 6, 4, 3)
  grid:dashedRing(6, 6, 5, 2)
  grid:rect(1, 1, 3, 3, 2)
  grid:gradient(1, 12, { 1, 2, 3 })
  grid:blitTo(newBuffer(6, 4, "pixel"), 1, 1)
end)

check("pixel grid tolerates out-of-bounds drawing", function()
  local pal = { theme.tones.bg, theme.tones.text }
  local grid = pixel.new(4, 3, pal)
  grid:clear(1)
  grid:set(-50, -50, 2); grid:set(9999, 9999, 2)
  grid:hline(-20, 200, 4, 2); grid:vline(3, -20, 200, 2)
  grid:disc(-5, -5, 12, 2); grid:line(-30, -30, 60, 60, 2)
  grid:blitTo(newBuffer(4, 3, "pixel-oob"), 1, 1)
end)

check("glyph clock draws at both scales", function()
  local pal = { theme.tones.bg, theme.tones.text }
  local grid = pixel.new(20, 8, pal)
  grid:clear(1)
  glyphs.drawShadowed(grid, 2, 2, "23:59", 2, 1, 1)
  glyphs.drawShadowed(grid, 2, 12, "00:00", 2, 1, 2)
  assert(glyphs.measure("12:34", 2) == 5 * 8 - 2, "measured width")
  grid:blitTo(newBuffer(20, 8, "glyphs"), 1, 1)
end)

check("sky paints every scene at every size", function()
  local sizes = { { 4, 2 }, { 10, 4 }, { 18, 6 }, { 26, 9 }, { 40, 14 }, { 82, 30 } }
  local dims = { "minecraft:overworld", "minecraft:the_nether", "minecraft:the_end" }
  for _, size in ipairs(sizes) do
    local grid = pixel.new(size[1], size[2], theme.skies.day)
    local buffer = newBuffer(size[1], size[2], "sky " .. size[1] .. "x" .. size[2])
    for _, dim in ipairs(dims) do
      for _, weather in ipairs({ { false, false }, { true, false }, { true, true } }) do
        for _, biome in ipairs({ "minecraft:plains", "minecraft:snowy_taiga", "minecraft:desert" }) do
          for tick = 0, 23000, 2300 do
            local snap = {
              tick = tick, kind = environment.dimensionKind(dim),
              phase = environment.phaseOf(tick), raining = weather[1],
              thundering = weather[2], biome = biome, moonId = tick % 8,
            }
            snap.body, snap.bodyProgress = environment.celestial(tick)
            local scene = environment.describe(snap)
            grid:setPalette(scene.palette)
            for _, anim in ipairs({ 0, 3.4, 17.9, 240.5 }) do
              sky.paint(grid, scene, anim)
              grid:blitTo(buffer, 1, 1)
            end
          end
        end
      end
    end
  end
end)

check("every biome paints at every size, wet and dry, day and night", function()
  -- Small sizes matter most here: the terrain painters divide by depths that
  -- collapse to zero on a short screen.
  local sizes = { { 4, 2 }, { 8, 3 }, { 14, 5 }, { 22, 8 }, { 40, 14 }, { 82, 30 } }
  for _, size in ipairs(sizes) do
    local grid = pixel.new(size[1], size[2], theme.skies.day)
    local buffer = newBuffer(size[1], size[2], "biome " .. size[1] .. "x" .. size[2])
    for _, kind in ipairs(biomes.ids()) do
      local profile = biomes.PROFILES[kind]
      -- Drive each profile through the dimension its terrain belongs to.
      local dim = "minecraft:overworld"
      if profile.terrain == "nether" then dim = "minecraft:the_nether"
      elseif profile.terrain == "end" then dim = "minecraft:the_end" end
      for _, weather in ipairs({ { false, false }, { true, false }, { true, true } }) do
        for tick = 0, 23000, 3800 do
          local snap = {
            tick = tick, day = 7, kind = environment.dimensionKind(dim),
            phase = environment.phaseOf(tick), raining = weather[1],
            thundering = weather[2], biome = "minecraft:plains", moonId = tick % 8,
            moonName = "Full Moon",
          }
          snap.body, snap.bodyProgress = environment.celestial(tick)
          -- The override is what forces this particular ground.
          local scene = environment.describe(snap, kind)
          assert(scene.groundKind == kind,
            ("override held: wanted %s, got %s"):format(kind, tostring(scene.groundKind)))
          grid:setPalette(scene.palette)
          for _, anim in ipairs({ 0, 5.5, 61.3 }) do
            sky.paint(grid, scene, anim)
            grid:blitTo(buffer, 1, 1)
          end
        end
      end
    end
  end
end)

-- blitTo quietly substitutes palette index 1 for an unpainted sub-pixel, so a
-- gap in a terrain painter shows up in game as a hole of sky in the ground
-- rather than as an error. The only way to catch it is to read the grid.
check("every scene paints every sub-pixel", function()
  local sizes = { { 10, 4 }, { 26, 9 }, { 46, 16 } }
  for _, size in ipairs(sizes) do
    local grid = pixel.new(size[1], size[2], theme.skies.day)
    for _, kind in ipairs(biomes.ids()) do
      local profile = biomes.PROFILES[kind]
      local dim = "minecraft:overworld"
      if profile.terrain == "nether" then dim = "minecraft:the_nether"
      elseif profile.terrain == "end" then dim = "minecraft:the_end" end
      for _, tick in ipairs({ 1000, 6000, 12000, 18000 }) do
        for _, weather in ipairs({ { false, false }, { true, false }, { true, true } }) do
          local snap = {
            tick = tick, day = 1, kind = environment.dimensionKind(dim),
            phase = environment.phaseOf(tick), raining = weather[1],
            thundering = weather[2], biome = "minecraft:plains", moonId = 3,
          }
          snap.body, snap.bodyProgress = environment.celestial(tick)
          local scene = environment.describe(snap, kind)
          grid:setPalette(scene.palette)
          -- Blank the surface first. Reusing a painted grid would let the
          -- previous scene fill in any gap this one leaves.
          grid.px = {}
          sky.paint(grid, scene, 12.5)

          for i = 1, grid.w * grid.h do
            local index = grid.px[i]
            if type(index) ~= "number" or index < 1 or index > #scene.palette then
              error(("%s at %dx%d left sub-pixel %d as %s"):format(
                kind, size[1], size[2], i, tostring(index)), 0)
            end
          end
        end
      end
    end
  end
end)

check("an unknown override is ignored rather than obeyed", function()
  local snap = {
    tick = 6000, day = 1, kind = "overworld", phase = "day",
    raining = false, thundering = false, biome = "minecraft:desert", moonId = 0,
  }
  snap.body, snap.bodyProgress = environment.celestial(6000)
  local scene = environment.describe(snap, "not-a-biome")
  assert(scene.groundKind == "desert", "fell back to the real biome, got " .. scene.groundKind)
  assert(scene.groundForced == false, "and did not claim to be forced")
  assert(environment.describe(snap, "auto").groundKind == "desert", "auto reads the biome")
  assert(environment.describe(snap, "ocean").groundKind == "ocean", "a real override holds")
end)

check("dry and cold biomes still gate the weather", function()
  local function sceneFor(kind, raining, thundering)
    local snap = {
      tick = 6000, day = 1, kind = "overworld", phase = "day",
      raining = raining, thundering = thundering, biome = "minecraft:plains", moonId = 0,
    }
    snap.body, snap.bodyProgress = environment.celestial(6000)
    return environment.describe(snap, kind)
  end
  assert(sceneFor("desert", true, false).weather == "clear", "deserts stay dry")
  assert(sceneFor("desert", true, true).weather == "clear", "and do not thunder")
  assert(sceneFor("plains", true, false).weather == "rain", "plains get rain")
  assert(sceneFor("plains", true, true).weather == "storm", "and thunder")
  assert(sceneFor("snowy", true, false).weather == "snow", "cold biomes get snow")
  assert(sceneFor("lushCaves", true, false).body == "none", "no sun underground")
end)

check("moon renders every phase", function()
  local grid = pixel.new(30, 10, theme.skies.night)
  local buffer = newBuffer(30, 10, "moon")
  for phase = 0, 7 do
    local scene = {
      kind = "overworld", phase = "night", weather = "clear",
      palette = theme.skies.night, body = "moon", bodyProgress = 0.5,
      moonPhase = phase, night = true,
    }
    sky.paint(grid, scene, 0)
    grid:blitTo(buffer, 1, 1)
  end
end)

------------------------------------------------------------------ the views --

local App = require("radar.app")
local ui  = require("radar.ui")

local function fakeDetector()
  return {
    __type = "player_detector",
    getPlayersInRange = function() return { "Steve", "Alex", "Herobrine" } end,
    getOnlinePlayers = function() return { "Steve", "Alex", "Herobrine", "Notch" } end,
    getPlayerPos = function(name)
      local table_ = {
        Steve = { x = 130, y = 70, z = -320, dimension = "minecraft:overworld",
                  yaw = 45, health = 14, maxHealth = 20 },
        Alex  = { x = -400, y = 12, z = 900, dimension = "minecraft:overworld",
                  yaw = 180, health = 20, maxHealth = 20 },
        Herobrine = { x = 121, y = 200, z = -341, dimension = "minecraft:overworld" },
      }
      return table_[name]
    end,
  }
end

local function fakeEnvironment()
  return {
    __type = "environment_detector",
    getTime = function() return 24000 * 142 + 5200 end,
    isRaining = function() return true end,
    isThunder = function() return false end,
    getBiome = function() return "minecraft:snowy_taiga" end,
    getDimension = function() return "minecraft:overworld" end,
    getMoonId = function() return 6 end,
    getSkyLightLevel = function() return 15 end,
    getBlockLightLevel = function() return 4 end,
    getDayLightLevel = function() return 12 end,
    isSlimeChunk = function() return true end,
  }
end

local function fakeModem(wireless)
  return {
    __type = "modem",
    isWireless = function() return wireless end,
    transmit = function() end,
    open = function() end,
    close = function() end,
    isOpen = function() return false end,
  }
end

PERIPHERALS.back = fakeDetector()
PERIPHERALS.environment_detector_1 = fakeEnvironment()
PERIPHERALS.modem_0 = fakeModem(false)      -- wired, and found first
PERIPHERALS.modem_1 = fakeModem(true)       -- ender: what a flying ship needs
PERIPHERALS.monitor_0 = {
  __type = "monitor",
  setTextScale = function() end,
  getSize = function() return 57, 24 end,
  setBackgroundColor = function() end, setTextColor = function() end,
  clear = function() end, setCursorPos = function() end, write = function() end,
  blit = function() end, setCursorBlink = function() end,
}
PERIPHERALS.speaker_0 = { __type = "speaker", playSound = function() return true end }

local app
check("app boots", function()
  app = App.new()
  assert(app.kit.detector, "player detector found")
  assert(app.kit.env, "environment detector found")
  assert(#app.kit.monitors == 1, "monitor found")
  assert(#app.kit.speakers == 1, "speaker found")
  assert(#app.kit.modems == 2, "both modems found, got " .. #app.kit.modems)
  assert(app.kit.modem.name == "modem_1", "the wireless one wins, got " .. app.kit.modem.name)
  assert(app.cfg.role == "station", "a fresh install stands alone")
  assert(not app.link.open, "and never opens the modem")
  app.cfg.baseX, app.cfg.baseY, app.cfg.baseZ = 120, 64, -340
  app.cfg.baseDim = "minecraft:overworld"
end)

check("sweep produces sorted contacts", function()
  app:sweep()
  assert(app.scanError == nil, "no error: " .. tostring(app.scanError))
  assert(#app.contacts == 3, "three contacts, got " .. #app.contacts)
  assert(app.contacts[1].name == "Herobrine", "nearest first, got " .. app.contacts[1].name)
  assert(app.contacts[1].dir, "bearing computed")
  assert(app.log:count() == 0, "first sweep does not log")
  app:sweep()
  assert(app.log:count() == 0, "players already present at boot are not logged")

  -- A genuinely new arrival should be logged and should alert.
  local previousLookup = PERIPHERALS.back.getPlayersInRange
  PERIPHERALS.back.getPlayersInRange = function()
    return { "Steve", "Alex", "Herobrine", "Notch" }
  end
  local previousPos = PERIPHERALS.back.getPlayerPos
  PERIPHERALS.back.getPlayerPos = function(name)
    if name == "Notch" then
      return { x = 125, y = 64, z = -338, dimension = "minecraft:overworld" }
    end
    return previousPos(name)
  end
  app:sweep()
  assert(app.log:count() == 1, "a new arrival is logged, got " .. app.log:count())
  assert(app.log.entries[1].name == "Notch", "the right player was logged")
  PERIPHERALS.back.getPlayersInRange = previousLookup
  PERIPHERALS.back.getPlayerPos = previousPos
  app:sweep()
end)

check("environment polls", function()
  app:pollEnvironment(true)
  local snap = app:snapshot()
  assert(snap.available, "snapshot available")
  assert(snap.day == 142, "day parsed, got " .. tostring(snap.day))
  assert(snap.clock == "11:12", "clock parsed, got " .. tostring(snap.clock))
  assert(snap.scene.weather == "snow", "cold biome rain becomes snow, got " .. snap.scene.weather)
end)

check("orientation unlocks and follows the player yaw", function()
  -- Steve is the only fake player with a yaw, so he stands in for the
  -- operator here. His name has to go back afterwards, or every later check
  -- would find him filtered out of his own radar.
  local savedName, savedRotation = app.cfg.myName, app.cfg.rotation
  app.cfg.myName = "Steve"
  app.cfg.headingStep = 0
  app.cfg.headingSmooth = false

  app.cfg.orientation = "fixed"
  app.cfg.rotation = 90
  assert(app:rotation() == 90, "a locked scope uses the fixed bearing")

  -- Steve's yaw is 45, so the bearing he faces is 225.
  assert(app:toggleOrientation() == true, "toggled to unlocked")
  assert(app.heading == 225, "read the heading, got " .. tostring(app.heading))
  assert(app:rotation() == 225, "an unlocked scope uses the heading")

  -- Snapping quantises the heading without touching the stored yaw. 225 sits
  -- exactly between two quarter turns; the tie rounds upward.
  app.cfg.headingStep = 90
  app:readHeading()
  assert(app.heading == 270, "snapped to 90 deg steps, got " .. tostring(app.heading))
  app.cfg.headingStep = 45
  app:readHeading()
  assert(app.heading == 225, "225 is already on a 45 deg step, got " .. tostring(app.heading))
  app.cfg.headingStep = 0

  -- Smoothing eases rather than jumping, and settles on the target.
  app.cfg.headingSmooth = true
  app.cfg.animate = true
  app.headingShown = 0
  app:readHeading()
  assert(app.headingShown == 0, "smoothing does not jump on a fresh reading")
  for _ = 1, 60 do app:easeHeading() end
  assert(math.abs(util.angleDelta(app.headingShown, 225)) < 0.5,
    "eased onto the heading, ended at " .. app.headingShown)

  -- With no username there is no yaw, so the scope must not claim a fix.
  app.cfg.myName = nil
  app:readHeading()
  assert(app.heading == nil, "no username, no heading")
  app.cfg.myName = "Steve"

  assert(app:toggleOrientation() == false, "toggled back to locked")
  assert(app:rotation() == 90, "and returned to the fixed bearing")

  app.cfg.myName, app.cfg.rotation = savedName, savedRotation
  app.heading, app.headingShown = nil, nil
end)

check("display defaults and the page rotation", function()
  local entry = app:displayConfig("monitor_0")
  assert(entry.cycle == false, "rotation is off until asked for")
  assert(entry.cycleSeconds == 15, "with a sane default interval")
  assert(#config.cyclePages(entry) == #config.PAGES, "and every page in it")

  entry.cycleSkip = { log = true, status = true }
  local pages = config.cyclePages(entry)
  assert(#pages == #config.PAGES - 2, "skipped pages drop out, got " .. #pages)
  for _, page in ipairs(pages) do
    assert(page ~= "log" and page ~= "status", "and stay out")
  end

  -- A rotation that excluded everything would strand the monitor, so the
  -- sanitiser refuses to keep one.
  local cfg = config.sanitise({
    displays = { m = { page = "radar", scale = 1, cycle = true, cycleSeconds = 7,
                       cycleSkip = { radar = true, contacts = true, weather = true,
                                     log = true, status = true, nonsense = true } } },
  })
  assert(next(cfg.displays.m.cycleSkip) == nil, "an all-skipping rotation is discarded")
  assert(cfg.displays.m.cycleSeconds == 5, "interval snapped to a legal value, got "
    .. cfg.displays.m.cycleSeconds)

  local partial = config.sanitise({
    displays = { m = { page = "weather", cycleSkip = { log = true, bogus = true } } },
  })
  assert(partial.displays.m.cycleSkip.log == true, "a real page stays skipped")
  assert(partial.displays.m.cycleSkip.bogus == nil, "a made-up one does not")
  assert(partial.displays.m.cycle == false, "missing keys are filled in")
end)

check("ignore list round trip", function()
  app:ignorePlayer("Alex")
  app:sweep()
  assert(#app.contacts == 2, "ignored player dropped, got " .. #app.contacts)
  app:unignorePlayer("Alex")
  app:sweep()
  assert(#app.contacts == 3, "ignored player restored")
end)

check("stats tally", function()
  local rows = app.log:stats()
  assert(#rows >= 1, "stats produced")
  assert(rows[1].count >= 1, "counted")
end)

-- Build the whole UI and drive every draw callback at several sizes.
local roots, terminalRoot
check("ui builds", function()
  roots, terminalRoot = ui.build(app)
  assert(#roots == 2, "terminal plus one monitor, got " .. #roots)
end)

local function drawTree(element, buffer, seen)
  seen = seen or {}
  if seen[element] then return end
  seen[element] = true
  if element.visible == false then return end
  local draw = rawget(element, "_p").draw
  if type(draw) == "function" then
    draw(element, buffer)
  end
  for _, child in ipairs(rawget(element, "_children") or {}) do
    drawTree(child, buffer, seen)
  end
end

check("every page draws at every size", function()
  local sizes = { { 15, 10 }, { 26, 12 }, { 39, 13 }, { 51, 19 }, { 57, 24 }, { 82, 40 }, { 164, 81 } }
  local scenarios = {
    { name = "normal" },
    { name = "empty", contacts = {} },
    { name = "fault", err = "Detector error: nope" },
    { name = "no-env", noEnv = true },
    { name = "muted", mute = true },
  }
  local saved = { contacts = app.contacts, err = app.scanError, snap = app.env.snapshot,
                  alert = app.cfg.alert }

  for _, root in ipairs(roots) do
    for _, page in ipairs(root.pages) do
      root:setPage(page, false)
      for _, size in ipairs(sizes) do
        rawget(root.root, "_p").width = size[1]
        rawget(root.root, "_p").height = size[2]
        for _, scenario in ipairs(scenarios) do
          app.contacts = scenario.contacts or saved.contacts
          app.scanError = scenario.err
          app.env.snapshot = scenario.noEnv and { available = false } or saved.snap
          app.cfg.alert = not scenario.mute
          root:refreshChrome()
          local label = ("%s %s %dx%d %s"):format(
            root.monitor and "monitor" or "terminal", page, size[1], size[2], scenario.name)
          local buffer = newBuffer(size[1], size[2], label)
          local ok, err = pcall(drawTree, root.root, buffer)
          if not ok then error(label .. ": " .. tostring(err), 0) end
        end
      end
    end
  end

  app.contacts, app.scanError = saved.contacts, saved.err
  app.env.snapshot, app.cfg.alert = saved.snap, saved.alert
end)

check("a monitor rotates through its pages on the timer", function()
  local monitorRoot
  for _, root in ipairs(roots) do
    if root.monitor then monitorRoot = root end
  end
  assert(monitorRoot, "a monitor root exists")

  local entry = app:displayConfig(monitorRoot.monitor.name)
  entry.cycle, entry.cycleSeconds, entry.cycleSkip = true, 10, {}
  monitorRoot:setPage("radar", false)
  monitorRoot:holdCycle()

  -- Not yet due: nothing moves.
  monitorRoot:tickCycle(CLOCK + 9)
  assert(monitorRoot.page == "radar", "held until the interval elapses")

  -- Due: it walks the rotation in PAGES order and wraps round to the start.
  local pages = config.cyclePages(entry)
  local at = CLOCK + 10
  for step = 1, #pages + 1 do
    monitorRoot:tickCycle(at)
    local want = pages[(step % #pages) + 1]
    assert(monitorRoot.page == want,
      ("step %d landed on %s, wanted %s"):format(step, monitorRoot.page, want))
    at = at + 10
  end

  -- A page dropped from the rotation is not somewhere it can get stuck.
  entry.cycleSkip = { radar = true }
  monitorRoot:setPage("radar", false)
  monitorRoot:tickCycle(at + 100)
  assert(monitorRoot.page ~= "radar", "left the excluded page")
  entry.cycleSkip = {}

  -- Rotation off means the page never moves by itself, however long it waits.
  entry.cycle = false
  monitorRoot:setPage("weather", false)
  monitorRoot:tickCycle(at + 10000)
  assert(monitorRoot.page == "weather", "a monitor with rotation off stays put")

  -- The terminal is never rotated, whatever its display entry says.
  local before = terminalRoot.page
  terminalRoot:tickCycle(at + 10000)
  assert(terminalRoot.page == before, "the terminal is left alone")
end)

check("tapping a monitor moves it to the next page", function()
  local monitorRoot
  for _, root in ipairs(roots) do
    if root.monitor then monitorRoot = root end
  end
  local tap = rawget(monitorRoot.content, "_handlers").onClick
  assert(tap, "the content area has a touch handler")

  app.cfg.tapCycle = true
  monitorRoot:setPage("radar", false)
  local order = monitorRoot.pages
  local start = nil
  for i, page in ipairs(order) do if page == "radar" then start = i end end

  tap(monitorRoot)
  assert(monitorRoot.page == order[(start % #order) + 1],
    "one tap, one page, landed on " .. monitorRoot.page)

  -- A tap also restarts the dwell timer, so the rotation cannot yank the page
  -- away the instant the operator has chosen one.
  local entry = app:displayConfig(monitorRoot.monitor.name)
  entry.cycle, entry.cycleSeconds = true, 30
  local held = monitorRoot.page
  monitorRoot:tickCycle(monitorRoot.cycleAt + 5)
  assert(monitorRoot.page == held, "the tap bought a full interval")
  entry.cycle = false

  -- Turning the setting off makes the screen inert again.
  app.cfg.tapCycle = false
  local stuck = monitorRoot.page
  tap(monitorRoot)
  assert(monitorRoot.page == stuck, "tap-to-cycle honours the setting")
  app.cfg.tapCycle = true
end)

check("settings rows all resolve", function()
  terminalRoot:setPage("settings", false)
  local view = terminalRoot.views.settings
  assert(view, "settings view built")
  view.refresh()
end)

check("every settings button handler runs", function()
  terminalRoot:setPage("settings", false)
  -- Pressing every button mutates a lot of settings; snapshot and restore.
  local before = textutils.serialize(app.cfg)
  local pressed = 0
  local function walk(element)
    local handler = rawget(element, "_handlers").onClick
    if handler and element.__kind == "Button" then
      pressed = pressed + 1
      local ok, err = pcall(handler, element)
      -- Quit and test-pulse use schedules, which the harness stubs out.
      if not ok then error(("button %q: %s"):format(tostring(element.text), tostring(err)), 0) end
    end
    for _, child in ipairs(rawget(element, "_children") or {}) do walk(child) end
  end
  walk(terminalRoot.views.settings.container)
  assert(pressed > 15, "plenty of buttons exercised, got " .. pressed)

  local restored = textutils.unserialize(before)
  for k in pairs(app.cfg) do app.cfg[k] = nil end
  for k, v in pairs(restored) do app.cfg[k] = v end
end)

check("key actions all run", function()
  terminalRoot:setPage("status", false)
  for _, action in pairs(getmetatable and {} or {}) do end
  -- registerKeys stored its table privately; drive the public equivalents.
  app:rangeUp(); app:rangeDown(); app:rotate(45); app:toggleMode(); app:toggleMode()
  app:toggleAlerts(); app:toggleAlerts(); app:ignoreNearest(); app:clearLog()
  app.alerts:play(); app.alerts:updateRedstone(); app.alerts:tick()
end)

check("redstone modes behave", function()
  app.cfg.rs.enabled = true
  app.cfg.rs.invert = false
  app.cfg.rs.rangeIndex = #config.RANGES
  app.ignore = {}
  app:sweep()
  assert(#app.contacts > 0, "contacts present for the test")
  for _, mode in ipairs({ "hold", "analog", "pulse" }) do
    app.cfg.rs.mode = mode
    app.alerts:invalidate()
    app.alerts:updateRedstone()
    local level = app.alerts:level()
    assert(level >= 0 and level <= 15, mode .. " level in range, got " .. level)
  end
  app.cfg.rs.mode = "hold"
  app.alerts:invalidate(); app.alerts:updateRedstone()
  assert(app.alerts:level() == 15, "hold is on while contacts are present")
  app.cfg.rs.invert = true
  app.alerts:invalidate(); app.alerts:updateRedstone()
  assert(app.alerts:level() == 0, "inverted hold reads zero")
  app.cfg.rs.invert = false
  app.cfg.rs.enabled = false
end)

--------------------------------------------------------------- base / ship --
-- One app is flipped between the roles rather than two being built, so a
-- relayed sweep can be compared field for field against the local sweep that
-- produced it.

local linkLib = require("radar.link")

local BASE_ID = 12
local SHIP_PAYLOAD = nil        -- the last scan payload the base broadcast
local LOCAL_CONTACTS = nil      -- what the base itself drew from it

check("v4 settings sanitise to a stand-alone station", function()
  local cfg = config.sanitise({ rangeIndex = 4, mode = "self" })
  assert(cfg.role == "station", "role defaults to station, got " .. tostring(cfg.role))
  assert(cfg.relayWeather == false, "the weather relay stays off")
  assert(cfg.pairedBaseId == nil, "nothing is paired")
  assert(cfg.stationName == "Base 3", "named from the computer id, got " .. cfg.stationName)
  assert(config.usesNetwork(cfg) == false, "and it never opens a modem")

  local junk = config.sanitise({ role = "wat", stationName = 42,
    relayWeather = "yes", pairedBaseId = "17.8" })
  assert(junk.role == "station", "an unknown role falls back")
  assert(junk.stationName == "Base 3", "a non-string name is replaced")
  assert(junk.relayWeather == false, "only a real boolean turns the relay on")
  assert(junk.pairedBaseId == 17, "a paired id is forced to a whole number")

  local long = config.sanitise({ stationName = string.rep("x", 90) })
  assert(#long.stationName == config.MAX_STATION_NAME, "names are capped")
end)

check("a station never touches the network", function()
  local before = #REDNET.sent
  app.cfg.role = "station"
  app.link:attach(app.kit, app.cfg)
  app:sweep()
  app:pollEnvironment(true)
  assert(not app.link.open, "the modem stays shut")
  assert(#REDNET.sent == before, "and nothing was broadcast, got "
    .. (#REDNET.sent - before) .. " messages")
end)

check("a base broadcasts every sweep", function()
  app.ignore = {}
  app.cfg.myName = "Steve"          -- the pilot, so a position and yaw travel
  app:setRole("base")
  assert(app.link.open, "the modem opened: " .. tostring(app.link.error))
  assert(REDNET.open.modem_1, "on the wireless modem")

  app:sweep()
  LOCAL_CONTACTS = app.contacts
  local entry = lastSent("s")
  assert(entry, "a sweep payload went out")
  assert(entry.protocol == linkLib.PROTOCOL, "on the data protocol, got "
    .. tostring(entry.protocol))

  local payload = entry.message
  assert(#payload.l == #app.contacts,
    ("%d contacts relayed, %d drawn"):format(#payload.l, #app.contacts))
  assert(payload.c and payload.c.x == app.centre.x, "the centre travels")
  assert(payload.p and payload.p.x == 130, "so does the pilot's position")
  assert(payload.g == 225, "and their heading, got " .. tostring(payload.g))
  assert(payload.i == config.scanInterval(app.cfg), "and the sweep interval")
  -- Nothing the far end can work out for itself is on the wire.
  assert(payload.l[1].dist == nil and payload.l[1].bearing == nil,
    "derived fields are left off the wire")

  SHIP_PAYLOAD = textutils.unserialize(textutils.serialize(payload))

  -- A base is still a working radar in its own right.
  assert(#app.contacts == 2, "the base drew its own sweep, got " .. #app.contacts)
  assert(app.scanError == nil, "with no fault")

  app.link:announce(app.cfg)
  local hello = lastSent("h")
  assert(hello and hello.protocol == linkLib.HELLO, "and announces itself")
  assert(hello.message.n == app.cfg.stationName, "under its own name")
end)

check("a ship renders a relayed sweep exactly as the base did", function()
  app:setRole("ship")
  app:pairWithBase(BASE_ID, "Hangar")
  app.contacts, app.myPos, app.heading = {}, nil, nil

  assert(app.link:handle(app, BASE_ID, SHIP_PAYLOAD, linkLib.PROTOCOL),
    "the payload was accepted")
  assert(#app.contacts == #LOCAL_CONTACTS,
    ("%d contacts rebuilt, %d expected"):format(#app.contacts, #LOCAL_CONTACTS))

  for i, want in ipairs(LOCAL_CONTACTS) do
    local got = app.contacts[i]
    for _, field in ipairs({ "name", "x", "y", "z", "dx", "dy", "dz", "dist",
                             "bearing", "dir", "zone", "zoneColor", "health",
                             "maxHealth", "yaw", "dim" }) do
      assert(got[field] == want[field],
        ("contact %d %s: got %s, wanted %s"):format(
          i, field, tostring(got[field]), tostring(want[field])))
    end
  end

  assert(app.scanError == nil, "no fault reported: " .. tostring(app.scanError))
  assert(app.myPos and app.myPos.x == 130, "the pilot's position came across")
  assert(app.centre and app.centre.x == 120, "and what distances are measured from")
  assert(app.heading == 225, "and their heading, got " .. tostring(app.heading))

  -- The ship snaps the relayed bearing with its OWN heading step, so two
  -- screens can be set up differently off one broadcast.
  local saved = app.cfg.headingStep
  app.cfg.headingStep = 90
  app.link:handle(app, BASE_ID, SHIP_PAYLOAD, linkLib.PROTOCOL)
  assert(app.heading == 270, "snapped locally, got " .. tostring(app.heading))
  app.cfg.headingStep = saved
end)

check("a ship ignores everything but its paired base", function()
  local stranger = textutils.unserialize(textutils.serialize(SHIP_PAYLOAD))
  stranger.l = {}
  local before = #app.contacts
  assert(before > 0, "there is something to lose")

  assert(app.link:handle(app, BASE_ID + 1, stranger, linkLib.PROTOCOL) == false,
    "another station's sweep is refused")
  assert(#app.contacts == before, "and changes nothing")

  -- A beacon from a stranger is still collected: that list is the picker.
  assert(app.link:handle(app, BASE_ID + 1, { t = "h", n = "Someone else" },
    linkLib.HELLO), "beacons are heard from anyone")
  assert(#app.contacts == before, "without touching the contacts")

  -- Junk on the protocol must not take the station down.
  assert(app.link:handle(app, BASE_ID, "not a table", linkLib.PROTOCOL) == false)
  assert(app.link:handle(app, BASE_ID, { t = "?" }, linkLib.PROTOCOL) == false)
  assert(app.link:handle(app, nil, SHIP_PAYLOAD, linkLib.PROTOCOL) == false)
end)

check("scanning for base stations, then pairing with one", function()
  app.link.seen = {}
  app:pairWithBase(nil, nil)
  assert(config.pairedLabel(app.cfg) == nil, "nothing paired to start with")

  -- What the pump would have collected while the operator waited.
  app.link:handle(app, BASE_ID, { t = "h", n = "Hangar" }, linkLib.HELLO)
  app.link:handle(app, 40, { t = "h", n = "Ore Island" }, linkLib.HELLO)
  app.link:handle(app, 41, { t = "h" }, linkLib.HELLO)

  local found = app.link:knownBases()
  assert(#found == 3, "three stations heard, got " .. #found)
  assert(found[1].name == "Computer 41", "sorted by name, got " .. found[1].name)
  assert(found[2].name == "Hangar" and found[2].id == BASE_ID, "ids kept with names")

  -- Drive the real picker the settings page opens.
  terminalRoot:setPage("settings", false)
  local settingsView = terminalRoot.views.settings
  assert(settingsView.pickBase, "the settings page exposes the base picker")
  settingsView.pickBase()
  local items = rawget(terminalRoot.views.settings.container, "_children")
  local picked = nil
  local function findItems(element)
    for _, item in ipairs(rawget(element, "_p").items or {}) do
      if type(item) == "table" and item.text and item.text:find("Hangar", 1, true) then
        picked = item
      end
    end
    for _, child in ipairs(rawget(element, "_children") or {}) do findItems(child) end
  end
  for _, child in ipairs(items) do findItems(child) end
  assert(picked, "the picker offered the base by name")
  picked.callback()

  assert(app.cfg.pairedBaseId == BASE_ID, "paired, got " .. tostring(app.cfg.pairedBaseId))
  assert(app.cfg.pairedBaseName == "Hangar", "and remembered its name")
  assert(config.pairedLabel(app.cfg) == "Hangar", "which is what the UI shows")

  -- A base heard long enough ago has probably gone; it drops out of the list.
  CLOCK = CLOCK + linkLib.SEEN_SECONDS + 1
  assert(#app.link:knownBases() == 0, "stale beacons are forgotten")
end)

check("silence from the paired base is reported as a lost link", function()
  app.link:forget()
  app:pairWithBase(BASE_ID, "Hangar")

  -- Nothing heard yet.
  app:sweep()
  assert(app.scanError and app.scanError:find("Waiting for Hangar", 1, true),
    "says what it is waiting for, got " .. tostring(app.scanError))

  app.link:handle(app, BASE_ID, SHIP_PAYLOAD, linkLib.PROTOCOL)
  app:sweep()
  assert(app.scanError == nil, "a fresh sweep clears it: " .. tostring(app.scanError))
  assert(#app.contacts > 0, "and there is something to draw")

  -- The base said it sweeps once a second, so the tolerance is measured off
  -- that rather than off this ship's own interval.
  assert(app.link.interval == 1, "the base's interval came across, got "
    .. tostring(app.link.interval))
  assert(app.link:staleAfter(app.cfg) == 3,
    "two sweeps, floored at three seconds, got " .. app.link:staleAfter(app.cfg))

  -- One missed sweep is not a lost link.
  CLOCK = CLOCK + 2
  app:sweep()
  assert(app.scanError == nil, "a single missed sweep is tolerated: "
    .. tostring(app.scanError))

  CLOCK = CLOCK + 3
  app:sweep()
  assert(app.scanError and app.scanError:find("Link lost", 1, true),
    "the link is called lost, got " .. tostring(app.scanError))
  assert(#app.contacts == 0, "and the scope is cleared rather than left stale")

  local summary, healthy = app.link:summary(app.cfg)
  assert(not healthy and summary:find("Link lost", 1, true), "the status line agrees")

  -- Unpaired and modem-less ships say so just as plainly.
  app:pairWithBase(nil, nil)
  app:sweep()
  assert(app.scanError:find("No base station paired", 1, true),
    "an unpaired ship says so, got " .. app.scanError)
  app:pairWithBase(BASE_ID, "Hangar")
  app.link:close()
  app:sweep()
  assert(app.scanError:find("modem", 1, true),
    "a ship with no modem says so, got " .. app.scanError)
  app.link:attach(app.kit, app.cfg)
end)

check("the weather relay rebuilds an identical snapshot", function()
  app:setRole("base")
  app.cfg.relayWeather = false
  app:pollEnvironment(true)
  local baseSnap = app:snapshot()
  assert(baseSnap.available, "the base has a snapshot")
  assert(lastSent("e") == nil, "nothing relayed while the relay is off")

  app.cfg.relayWeather = true
  app:pollEnvironment(true)
  local entry = lastSent("e")
  assert(entry, "the readings went out once it was on")
  assert(entry.protocol == linkLib.PROTOCOL, "on the data protocol")
  assert(entry.message.r.scene == nil and entry.message.r.palette == nil,
    "raw readings only -- the scene is rebuilt, not shipped")

  local payload = textutils.unserialize(textutils.serialize(entry.message))

  app:setRole("ship")
  app:pairWithBase(BASE_ID, "Hangar")
  app.env.snapshot = { available = false }
  assert(app.link:handle(app, BASE_ID, payload, linkLib.PROTOCOL), "accepted")

  local shipSnap = app:snapshot()
  assert(shipSnap.available, "the ship has a snapshot without a detector")
  for _, field in ipairs({ "rawTime", "tick", "day", "clock", "phase", "body",
                           "raining", "thundering", "biome", "biomeName",
                           "dimension", "kind", "moonId", "moonName",
                           "skyLight", "blockLight", "dayLight", "slimeChunk" }) do
    assert(shipSnap[field] == baseSnap[field],
      ("%s: got %s, wanted %s"):format(field, tostring(shipSnap[field]),
        tostring(baseSnap[field])))
  end
  assert(shipSnap.scene.weather == baseSnap.scene.weather, "same weather")
  assert(shipSnap.scene.groundKind == baseSnap.scene.groundKind, "same ground")
  assert(#shipSnap.scene.palette == 10, "and a full scene palette to draw it")

  -- While the relay is fresh the ship leaves its own detector alone.
  local polled = false
  local realGetTime = PERIPHERALS.environment_detector_1.getTime
  PERIPHERALS.environment_detector_1.getTime = function()
    polled = true
    return realGetTime()
  end
  app:pollEnvironment(false)
  assert(not polled, "a fresh relay stops the local poll")
  assert(app:snapshot().clock == baseSnap.clock, "and keeps the relayed snapshot")

  CLOCK = CLOCK + 60
  app:pollEnvironment(false)
  assert(polled, "a stale relay falls back to whatever is attached")
  PERIPHERALS.environment_detector_1.getTime = realGetTime
end)

check("every page draws in the base and ship roles", function()
  local sizes = { { 15, 10 }, { 51, 19 }, { 82, 40 } }
  local scenarios = {
    { name = "ship-live",  role = "ship", feed = true },
    { name = "ship-lost",  role = "ship", feed = false },
    { name = "base",       role = "base", feed = false },
  }
  for _, scenario in ipairs(scenarios) do
    app:setRole(scenario.role)
    app:pairWithBase(BASE_ID, "Hangar")
    if scenario.feed then
      app.link:handle(app, BASE_ID, SHIP_PAYLOAD, linkLib.PROTOCOL)
    else
      app:sweep()
    end
    for _, root in ipairs(roots) do
      for _, page in ipairs(root.pages) do
        root:setPage(page, false)
        for _, size in ipairs(sizes) do
          rawget(root.root, "_p").width = size[1]
          rawget(root.root, "_p").height = size[2]
          root:refreshChrome()
          local label = ("%s %s %dx%d %s"):format(
            root.monitor and "monitor" or "terminal", page, size[1], size[2], scenario.name)
          local buffer = newBuffer(size[1], size[2], label)
          local ok, err = pcall(drawTree, root.root, buffer)
          if not ok then error(label .. ": " .. tostring(err), 0) end
        end
      end
    end
  end
  app:setRole("station")
end)

--------------------------------------------------------------------- report --

print(("%d checks, %d failures"):format(checks, #failures))
for _, failure in ipairs(failures) do print("  FAIL " .. failure) end
if #failures > 0 then os.exit(1) end
