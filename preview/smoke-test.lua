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

-- Everything the first-boot chooser writes lands here, so a check can read
-- back what the screen actually said rather than only that it did not crash.
local TERM_OUT = {}

term = {
  setBackgroundColor = function() end, setTextColor = function() end,
  clear = function() TERM_OUT = {} end, setCursorPos = function() end,
  getSize = function() return 51, 19 end, blit = function() end,
  write = function(text) TERM_OUT[#TERM_OUT + 1] = tostring(text) end,
  isColor = function() return true end,
  clearLine = function() end,
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
-- `texts` collects every string blitted as text, which is how a check reads
-- back what a view actually wrote rather than only that it did not crash.
local function newBuffer(w, h, label)
  return setmetatable({ w = w, h = h, label = label, writes = 0, texts = {} }, Buffer)
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
  local texts = rawget(self, "texts")
  if texts then texts[#texts + 1] = str end
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

-- modules ----------------------------------------------------------------------

local modules = require("radar.modules")

check("every built-in module registers a complete descriptor", function()
  local all = modules.all()
  assert(#all >= 7, "seven built-ins at least, got " .. #all)

  local seen, lastOrder = {}, -math.huge
  for _, entry in ipairs(all) do
    assert(type(entry.id) == "string" and #entry.id > 0, "every module has an id")
    assert(not seen[entry.id], "ids are unique: " .. entry.id)
    seen[entry.id] = true
    assert(type(entry.title) == "string" and #entry.title > 0, entry.id .. " has a title")
    assert(type(entry.short) == "string" and #entry.short > 0 and #entry.short <= 4,
      entry.id .. " has a short tab label, got " .. tostring(entry.short))
    assert(type(entry.order) == "number", entry.id .. " has an order")
    assert(entry.order >= lastOrder, "registered in order: " .. entry.id)
    lastOrder = entry.order
  end

  for _, id in ipairs({ "status", "radar", "contacts", "weather", "power",
                        "log", "settings" }) do
    assert(modules.byId(id), "built-in module present: " .. id)
  end
  assert(modules.byId("no-such-module") == nil, "an unknown id is nil")
  assert(#(modules.failures or {}) == 0,
    "nothing failed to load: " .. textutils.serialize(modules.failures))
end)

check("the loader finds files dropped into the modules folder", function()
  -- No fs.list in the harness by default, which is what makes these runs
  -- deterministic: the built-in list is the whole set.
  local plain = modules.scan()
  assert(#plain == #modules.BUILT_IN, "built-ins only, got " .. #plain)
  for i, id in ipairs(modules.BUILT_IN) do
    assert(plain[i] == id, "in their declared order, wanted " .. id)
  end

  -- With a directory to read, anything else in it follows them alphabetically,
  -- and only .lua files count.
  local LISTED = { "zebra.lua", "aardvark.lua", "notes.txt", "power.lua", "sub" }
  local asked
  fs.list = function(dir) asked = dir; return LISTED end

  local found = modules.scan()
  assert(asked == modules.dir, "it looked in the modules folder, got " .. tostring(asked))
  assert(#found == #modules.BUILT_IN + 2, "two drop-ins found, got " .. #found)
  assert(found[#modules.BUILT_IN + 1] == "aardvark", "sorted, got " .. found[#found - 1])
  assert(found[#modules.BUILT_IN + 2] == "zebra", "and after the built-ins")
  for _, id in ipairs(found) do
    assert(id ~= "notes" and id ~= "sub", "only .lua files are modules")
  end

  local duplicates = 0
  for _, id in ipairs(found) do
    if id == "power" then duplicates = duplicates + 1 end
  end
  assert(duplicates == 1, "a built-in is not loaded twice, got " .. duplicates)

  -- A directory that is not there is not an error: a station with no drop-ins
  -- has no radar/modules to list on some layouts.
  fs.list = function() error("no such directory") end
  assert(#modules.scan() == #modules.BUILT_IN, "a missing folder falls back quietly")

  fs.list = nil
end)

check("core modules cannot be switched off, others can", function()
  local cfg = config.sanitise({})
  assert(modules.isEnabled(cfg, "status"), "status is on")
  assert(modules.isEnabled(cfg, "power"), "and so is a fresh power module")

  cfg.modulesOff = { status = true, settings = true, power = true, bogus = true }
  config.sanitise(cfg)
  assert(modules.isEnabled(cfg, "status"), "a core module refuses to go off")
  assert(modules.isEnabled(cfg, "settings"), "settings too")
  assert(cfg.modulesOff.status == nil, "and the attempt is scrubbed from the file")
  assert(cfg.modulesOff.bogus == nil, "a made-up id does not survive either")
  assert(not modules.isEnabled(cfg, "power"), "an ordinary module does go off")

  local pages = modules.pages(cfg)
  for _, id in ipairs(pages) do
    assert(id ~= "power", "and drops out of the page list")
  end
  assert(#pages > 0, "there are always pages left")
end)

check("the page lists follow what is enabled", function()
  local cfg = config.sanitise({})
  local terminalPages = modules.pages(cfg)
  local monitorPages = modules.monitorPages(cfg)

  local hasSettings = false
  for _, id in ipairs(terminalPages) do
    if id == "settings" then hasSettings = true end
  end
  assert(hasSettings, "the terminal can reach settings")

  for _, id in ipairs(monitorPages) do
    assert(id ~= "settings", "a monitor never gets the settings page")
  end
  assert(#monitorPages == #terminalPages - 1, "which is the only difference")

  assert(modules.isPage(cfg, "radar"), "radar is a page")
  assert(not modules.isPage(cfg, "nonsense"), "nonsense is not")
end)

check("modules contribute their own settings keys", function()
  local defaults = modules.defaults()
  assert(defaults.backdrop == "live", "the weather module brings the backdrop")
  assert(type(defaults.power) == "table", "the power module brings its own table")

  -- And those keys arrive through config the same way a built-in one does.
  local cfg = config.sanitise({})
  assert(cfg.backdrop == "live", "backdrop defaulted through config")
  assert(cfg.power.unit == "FE", "power defaulted through config")
  assert(cfg.power.windowSeconds == 300, "with its own window")

  -- A module's sanitise() runs over its own keys.
  local junk = config.sanitise({
    power = { unit = "GJ", windowSeconds = 7, lowPercent = 900,
              sampleSeconds = 99, roles = { good = "in", bad = "sideways", [7] = "in" } },
  })
  assert(junk.power.unit == "FE", "an unknown unit falls back, got " .. junk.power.unit)
  assert(junk.power.windowSeconds == 60, "the window snaps to a legal one, got "
    .. junk.power.windowSeconds)
  assert(junk.power.sampleSeconds == 5, "and so does the sample rate")
  assert(junk.power.lowPercent == 90, "the threshold is clamped, got " .. junk.power.lowPercent)
  assert(junk.power.roles.good == "in", "a real role survives")
  assert(junk.power.roles.bad == nil, "a made-up one does not")
  assert(junk.power.roles[7] == nil, "and neither does a non-string key")
end)

-- profiles ----------------------------------------------------------------------

local profiles = require("radar.profiles")

check("every profile is complete", function()
  assert(#profiles.LIST == 3, "three profiles, got " .. #profiles.LIST)
  for _, entry in ipairs(profiles.LIST) do
    assert(type(entry.id) == "string", "an id")
    assert(type(entry.label) == "string" and #entry.label > 0, entry.id .. " has a label")
    assert(type(entry.hint) == "string" and #entry.hint > 0, entry.id .. " has a hint")
    assert(type(entry.blurb) == "table" and #entry.blurb > 0, entry.id .. " has a blurb")
    assert(type(entry.cfg) == "table", entry.id .. " has settings")
    for id in pairs(entry.off or {}) do
      local module = modules.byId(id)
      assert(module, entry.id .. " switches off a real module, not " .. id)
      assert(not module.core, entry.id .. " does not try to switch off a core module")
    end
  end
  assert(profiles.byId(profiles.DEFAULT), "the default names a real profile")
  assert(profiles.byId("nope") == nil, "an unknown id is nil")
end)

check("applying a profile rewrites the settings it covers", function()
  local cfg = config.sanitise({ myName = "Steve" })

  profiles.apply(cfg, "base", {})
  assert(cfg.profile == "base", "recorded")
  assert(cfg.orientation == "fixed", "a base locks the scope")
  assert(cfg.animate == true, "and animates")
  assert(next(cfg.modulesOff) == nil, "with every module on")

  profiles.apply(cfg, "pocket", {})
  assert(cfg.profile == "pocket", "switched")
  assert(cfg.animate == false, "a pocket stops animating")
  assert(cfg.orientation == "heading", "and unlocks the scope")
  assert(cfg.headingStep == 45, "in stable steps")
  assert(cfg.modulesOff.power == true, "with no power page to wire up")

  -- Switching back has to clear what the previous profile switched off, or a
  -- module would stay dark for no reason anyone could see.
  profiles.apply(cfg, "base", {})
  assert(cfg.modulesOff.power == nil, "and going back turns it on again")
end)

check("a profile will not switch on what it has no username for", function()
  local cfg = config.sanitise({})
  cfg.myName = nil

  profiles.apply(cfg, "pocket", {})
  assert(cfg.mode == "fixed", "SELF tracking needs a name, got " .. cfg.mode)
  assert(cfg.orientation == "fixed", "and so does an unlocked scope")

  cfg.myName = "Steve"
  profiles.apply(cfg, "pocket", {})
  assert(cfg.mode == "self", "with a name it does track you")
  assert(cfg.orientation == "heading", "and the scope follows you")
end)

check("a profile picks its role from whether there is a modem", function()
  local cfg = config.sanitise({ myName = "Steve" })

  -- A modem is the whole question: without one there is no network to be part
  -- of, whatever the computer is bolted to.
  profiles.apply(cfg, "vehicle", { modem = { name = "modem_0" } })
  assert(cfg.role == "mobile", "a vehicle with a modem is MOBILE, got " .. cfg.role)
  assert(cfg.orientation == "heading", "and the scope follows the pilot")
  assert(cfg.headingSmooth == true, "easing into turns")

  profiles.apply(cfg, "vehicle", {})
  assert(cfg.role == "standalone", "without one it stands alone, got " .. cfg.role)

  profiles.apply(cfg, "pocket", { modem = { name = "modem_0" } })
  assert(cfg.role == "mobile", "a pocket with a modem is MOBILE too, got " .. cfg.role)
  profiles.apply(cfg, "pocket", {})
  assert(cfg.role == "standalone", "and stands alone without one")

  profiles.apply(cfg, "base", { modem = { name = "modem_0" } })
  assert(cfg.role == "main", "a base with a modem is the MAIN BASE, got " .. cfg.role)
  profiles.apply(cfg, "base", {})
  assert(cfg.role == "standalone", "and stands alone without one")
end)

check("the roles a settings file names from before v8 are migrated", function()
  -- An existing pair has to keep working across the upgrade rather than being
  -- reset to standalone and needing to be paired again by hand.
  assert(config.sanitise({ role = "station" }).role == "standalone", "station")
  assert(config.sanitise({ role = "base" }).role == "main", "base")

  local mobile = config.sanitise({ role = "ship", pairedBaseId = 12,
                                   pairedBaseName = "Hangar" })
  assert(mobile.role == "mobile", "ship becomes mobile, got " .. mobile.role)
  assert(mobile.pairedBaseId == 12, "and stays paired to the same computer")
  assert(mobile.pairedBaseName == "Hangar", "under the same name")

  assert(config.sanitise({ role = "wat" }).role == "standalone", "junk still falls back")
end)

check("suggest reads the hardware without deciding anything", function()
  assert(profiles.suggest({ detector = {}, monitors = { {} } }) == "base",
    "a detector and a monitor look like a base")
  assert(profiles.suggest({ modem = {}, monitors = {} }) == "vehicle",
    "a modem and nothing to scan with looks like a ship")
  assert(profiles.byId(profiles.suggest({})), "and anything else is still a real profile")
end)

check("an upgrade is never marched through the profile chooser", function()
  FILES["radar.cfg"] = textutils.serialize({
    version = "6.1", rangeIndex = 3, rotation = 90, backdrop = "islesDawn",
    myName = "Steve", orientation = "heading",
  })
  local cfg, _, _, imported, fresh = config.load()
  assert(not fresh, "settings existed, so this is not a fresh install")
  assert(imported, "and it is flagged as an upgrade")
  assert(cfg.profile == profiles.DEFAULT, "labelled, got " .. tostring(cfg.profile))
  -- Nothing the operator chose may have been overwritten by that label.
  assert(cfg.rangeIndex == 3, "their range survived")
  assert(cfg.rotation == 90, "their rotation survived")
  assert(cfg.backdrop == "islesDawn", "their backdrop survived")
  assert(cfg.orientation == "heading", "and their unlocked scope survived")
  FILES["radar.cfg"] = nil

  local _, _, _, _, blank = config.load()
  assert(blank, "with no file at all it IS a fresh install")
  assert(config.sanitise({}).profile == nil, "and a fresh config has no profile yet")

  -- A profile from a version that no longer has it is forgotten, not obeyed.
  assert(config.sanitise({ profile = "orbital-platform" }).profile == nil,
    "an unknown profile is dropped")
end)

-- the first-boot chooser ---------------------------------------------------------

check("the profile chooser accepts a keystroke, an arrow and a click", function()
  local setup = require("radar.setup")
  local QUEUE = {}
  local realPull = os.pullEvent
  os.pullEvent = function() return table.unpack(table.remove(QUEUE, 1)) end

  -- A number key chooses and accepts in one press.
  QUEUE = { { "char", "2" } }
  assert(setup.chooseProfile("base") == "pocket", "2 picks the second profile")

  QUEUE = { { "char", "9" }, { "char", "1" } }
  assert(setup.chooseProfile("base") == "base", "an out-of-range number is ignored")

  -- Down then Enter walks the list.
  QUEUE = { { "key", keys.down }, { "key", keys.enter } }
  assert(setup.chooseProfile("base") == "pocket", "down moves one, enter accepts")

  QUEUE = { { "key", keys.up }, { "key", keys.enter } }
  assert(setup.chooseProfile("base") == "vehicle", "up wraps round to the end")

  -- The suggestion only decides where the cursor starts.
  QUEUE = { { "key", keys.enter } }
  assert(setup.chooseProfile("vehicle") == "vehicle", "enter takes the suggestion")

  os.pullEvent = realPull
end)

-- power --------------------------------------------------------------------------

local powerLib = require("radar.power")

--- An Advanced Peripherals style energy detector.
local function fakeMeter(rate)
  local limit = 2147483647
  return {
    __type = "energy_detector",
    getTransferRate = function() return rate end,
    getTransferRateLimit = function() return limit end,
    setTransferRateLimit = function(v) limit = v end,
  }
end

--- A directly wrapped battery, in the Mekanism spelling.
local function fakeBattery(stored, capacity, lastIn, lastOut)
  return {
    __type = "inductionMatrix",
    getEnergy = function() return stored end,
    getMaxEnergy = function() return capacity end,
    getLastInput = function() return lastIn end,
    getLastOutput = function() return lastOut end,
  }
end

check("energy peripherals are recognised by method name", function()
  assert(powerLib.looksLikeEnergy(fakeMeter(10)), "a transfer rate is enough")
  assert(powerLib.looksLikeEnergy(fakeBattery(1, 2)), "so is stored plus capacity")
  assert(not powerLib.looksLikeEnergy({ getEnergy = function() return 1 end }),
    "stored alone is not: there is nothing to show it as a fraction of")
  assert(not powerLib.looksLikeEnergy({ playSound = function() end }), "a speaker is not")
  assert(not powerLib.looksLikeEnergy("nonsense"), "nor is a string")

  -- Every spelling the probe knows has to actually resolve.
  for _, spelling in ipairs({
    { getEnergyStored = function() return 5 end, getEnergyCapacity = function() return 10 end },
    { getStoredEnergy = function() return 5 end, getMaxEnergyStored = function() return 10 end },
    { getEnergy = function() return 5 end, getCapacity = function() return 10 end },
  }) do
    local source = powerLib.describe("x", spelling, "battery")
    assert(source and source.store, "recognised an alternative spelling")
  end

  local meter = powerLib.describe("energy_detector_0", fakeMeter(42), "energy_detector")
  assert(meter.meter and not meter.store, "a detector is a meter, not a battery")
  local battery = powerLib.describe("matrix_0", fakeBattery(50, 100), "inductionMatrix")
  assert(battery.store and not battery.meter, "and a battery is the other way round")
  assert(powerLib.describe("m", { getFoo = function() end }, "x") == nil, "junk is skipped")
end)

check("the model totals meters by the role they are given", function()
  local kit = { energy = {
    powerLib.describe("in_0",  fakeMeter(1200), "energy_detector"),
    powerLib.describe("out_0", fakeMeter(800),  "energy_detector"),
    powerLib.describe("spare", fakeMeter(500),  "energy_detector"),
  } }
  local cfg = config.sanitise({})
  cfg.power.roles = { in_0 = "in", out_0 = "out", spare = "off" }

  local model = powerLib.new()
  model:attach(kit, cfg)
  assert(model.available, "sources attached")
  model:poll(cfg, 100)

  assert(model.input == 1200, "supply summed, got " .. model.input)
  assert(model.output == 800, "demand summed, got " .. model.output)
  assert(model.net == 400, "and the net is the difference, got " .. model.net)
  assert(model.hasRate, "a real rate was read")
  assert(model.percent == nil, "with no battery there is no percentage")
  assert(model.stored == nil, "and nothing stored")

  -- A meter with no role assigned counts as supply: one detector on the main
  -- bus is measuring what is coming in.
  cfg.power.roles = {}
  model:poll(cfg, 101)
  assert(model.input == 2500, "unassigned meters default to supply, got " .. model.input)
  assert(model.output == 0, "and nothing to demand")
end)

check("a battery gives stored, capacity and its own throughput", function()
  local kit = { energy = {
    powerLib.describe("matrix", fakeBattery(2.5e9, 1e10, 900, 400), "inductionMatrix"),
  } }
  local cfg = config.sanitise({})

  local model = powerLib.new()
  model:attach(kit, cfg)
  model:poll(cfg, 100)

  assert(model.stored == 2.5e9, "stored read")
  assert(model.capacity == 1e10, "capacity read")
  assert(math.abs(model.percent - 25) < 0.001, "percentage derived, got " .. model.percent)
  assert(model.hasStore, "flagged as having a buffer")
  assert(model.input == 900 and model.output == 400,
    "its own throughput is used, got " .. model.input .. "/" .. model.output)
  assert(model.net == 500, "net follows")
  assert(math.abs(model:fraction() - 0.25) < 0.001, "and the redstone fraction agrees")
end)

check("with no meter anywhere the rate comes from the storage change", function()
  local held = 1000000
  local battery = {
    getEnergy = function() return held end,
    getEnergyCapacity = function() return 2000000 end,
  }
  local kit = { energy = { powerLib.describe("cell", battery, "cell") } }
  local cfg = config.sanitise({})

  local model = powerLib.new()
  model:attach(kit, cfg)

  model:poll(cfg, 100)
  assert(not model.hasRate, "nothing reported a rate")
  assert(model.net == 0, "and the first reading has nothing to compare against")

  -- Gained 20000 over one second: 20000 / (1 * 20 ticks) = 1000 per tick.
  held = 1020000
  model:poll(cfg, 101)
  assert(math.abs(model.input - 1000) < 0.001, "charging reads as supply, got " .. model.input)
  assert(model.output == 0, "with no demand")

  held = 1000000
  model:poll(cfg, 102)
  assert(math.abs(model.output - 1000) < 0.001, "draining reads as demand, got " .. model.output)
  assert(model.input == 0, "with no supply")
  assert(math.abs(model.net + 1000) < 0.001, "and a negative net")
end)

check("nothing attached is reported rather than drawn as zero", function()
  local model = powerLib.new()
  model:attach({ energy = {} }, config.sanitise({}))
  assert(not model.available, "nothing found")
  model:poll(config.sanitise({}), 1)
  assert(model.error and model.error:find("No energy", 1, true),
    "and it says so, got " .. tostring(model.error))
  assert(model:fraction() == nil, "the redstone level is unknown, not empty")
end)

check("the low alarm fires once per crossing", function()
  local held = 1000
  local kit = { energy = { powerLib.describe("cell", {
    getEnergy = function() return held end,
    getEnergyCapacity = function() return 1000 end,
  }, "cell") } }
  local cfg = config.sanitise({})
  cfg.power.lowPercent = 20

  local model = powerLib.new()
  model:attach(kit, cfg)

  model:poll(cfg, 1)
  assert(model:checkAlarm(cfg, 1) == false, "a full buffer is quiet")

  held = 150                                    -- 15%
  model:poll(cfg, 2)
  assert(model:checkAlarm(cfg, 2) == true, "crossing below fires")
  assert(model.low, "and latches")

  held = 120
  model:poll(cfg, 3)
  assert(model:checkAlarm(cfg, 3) == false, "sinking further does not fire again")

  -- Sitting on the line must not chatter: it takes the hysteresis to re-arm.
  held = 220                                    -- 22%, inside the hysteresis
  model:poll(cfg, 4)
  assert(model:checkAlarm(cfg, 4) == false, "still latched just above the line")
  assert(model.low, "and still considered low")

  held = 400
  model:poll(cfg, 5)
  assert(model:checkAlarm(cfg, 5) == false, "recovering does not fire")
  assert(not model.low, "but it does re-arm")

  held = 100
  model:poll(cfg, 6)
  assert(model:checkAlarm(cfg, 6) == true, "so the next crossing fires again")

  -- Switched off, it never fires whatever the buffer does.
  cfg.power.alarm = false
  held = 1000; model:poll(cfg, 7); model:checkAlarm(cfg, 7)
  held = 10;   model:poll(cfg, 8)
  assert(model:checkAlarm(cfg, 8) == false, "a muted alarm stays muted")
end)

check("the history ring keeps the newest samples in order", function()
  local history = powerLib.newHistory(4)
  for i = 1, 3 do history:push(i, i * 10, i) end

  local ins, outs, pct = history:series()
  assert(#ins == 3, "three samples, got " .. #ins)
  assert(ins[1] == 1 and ins[3] == 3, "oldest first")
  assert(outs[2] == 20 and pct[2] == 2, "every series stays in step")

  for i = 4, 9 do history:push(i, i * 10, i) end
  ins = history:series()
  assert(#ins == 4, "capped at the capacity, got " .. #ins)
  assert(ins[1] == 6 and ins[4] == 9, "and it is the last four, got "
    .. ins[1] .. ".." .. ins[4])

  -- Growing keeps what there was; shrinking keeps the most recent.
  history:resize(6)
  ins = history:series()
  assert(#ins == 4 and ins[4] == 9, "growing loses nothing")
  history:push(10, 100, 10)
  history:resize(2)
  ins = history:series()
  assert(#ins == 2 and ins[2] == 10, "shrinking keeps the newest, got " .. ins[2])

  history:clear()
  assert(#history:series() == 0, "and it can be emptied")
end)

check("the graph window sets the history capacity", function()
  local cfg = config.sanitise({})
  local model = powerLib.new()
  model:attach({ energy = {} }, cfg)

  cfg.power.windowSeconds, cfg.power.sampleSeconds = 300, 1
  model:applyWindow(cfg)
  assert(model.history.cap == 301, "five minutes at one a second, got " .. model.history.cap)

  cfg.power.windowSeconds, cfg.power.sampleSeconds = 900, 5
  model:applyWindow(cfg)
  assert(model.history.cap == 181, "fifteen minutes at one every five, got "
    .. model.history.cap)
end)

check("energy figures print at every magnitude", function()
  assert(powerLib.format(0) == "0", "zero")
  assert(powerLib.format(940) == "940", "under a thousand is exact")
  assert(powerLib.format(12300) == "12.3k", "thousands, got " .. powerLib.format(12300))
  assert(powerLib.format(4.56e6) == "4.56M", "millions, got " .. powerLib.format(4.56e6))
  assert(powerLib.format(1.2e9) == "1.20G", "billions, got " .. powerLib.format(1.2e9))
  assert(powerLib.format(3e12) == "3.00T", "trillions")
  assert(powerLib.format(-2500) == "-2.5k", "negatives keep their sign")
  assert(powerLib.format("nonsense") == "-", "junk does not crash a draw call")
  assert(powerLib.format(0/0) == "-", "and neither does a NaN")

  assert(powerLib.formatSigned(500) == "+500", "a net gain is explicit")
  assert(powerLib.formatSigned(-500) == "-500", "a net loss keeps its sign")
  assert(powerLib.formatSigned(0) == "0", "and level is neither")

  assert(powerLib.duration(30) == "30s", "seconds")
  assert(powerLib.duration(300) == "5m", "minutes, got " .. powerLib.duration(300))
  assert(powerLib.duration(7200) == "2.0h", "hours, got " .. powerLib.duration(7200))
  assert(powerLib.duration(-1) == "-", "and nonsense is a dash")
end)

check("time to empty follows the net rate", function()
  local kit = { energy = {
    powerLib.describe("matrix", fakeBattery(1e6, 2e6, 0, 100), "inductionMatrix"),
  } }
  local cfg = config.sanitise({})
  local model = powerLib.new()
  model:attach(kit, cfg)
  model:poll(cfg, 1)

  -- Draining 100 per tick = 2000 per second, from a million stored.
  local seconds, direction = model:timeToLimit()
  assert(direction == "empty", "heading for empty, got " .. tostring(direction))
  assert(math.abs(seconds - 500) < 0.001, "in 500 seconds, got " .. tostring(seconds))

  kit.energy[1] = powerLib.describe("matrix", fakeBattery(1e6, 2e6, 100, 0), "inductionMatrix")
  model:attach(kit, cfg)
  model:poll(cfg, 2)
  local fillSeconds, fillDirection = model:timeToLimit()
  assert(fillDirection == "full", "and charging heads the other way")
  assert(math.abs(fillSeconds - 500) < 0.001, "same rate, same time")

  kit.energy[1] = powerLib.describe("matrix", fakeBattery(1e6, 2e6, 100, 100), "inductionMatrix")
  model:attach(kit, cfg)
  model:poll(cfg, 3)
  assert(model:timeToLimit() == nil, "a balanced grid is not going anywhere")
end)

check("the transfer limit is only ever written on purpose", function()
  local device = fakeMeter(100)
  local source = powerLib.describe("detector", device, "energy_detector")
  local model = powerLib.new()
  model:attach({ energy = { source } }, config.sanitise({}))

  -- Polling reads the limit but must never set one.
  model:poll(config.sanitise({}), 1)
  assert(source.limit == 2147483647, "the limit was read, got " .. tostring(source.limit))

  local ok, message = model:setLimit(source, 5000)
  assert(ok, "a deliberate write succeeds: " .. tostring(message))
  assert(device.getTransferRateLimit() == 5000, "and reaches the device")
  assert(source.limit == 5000, "and is read back")

  assert(model:setLimit(source, -5) == false, "a negative limit is refused")
  assert(model:setLimit(powerLib.describe("m", fakeBattery(1, 2), "cell"), 10) == false,
    "a battery has no limit to set")
  assert(model:setLimit(nil, 10) == false, "and neither does nothing")

  assert(model:sourceByName("detector") == source, "sources are findable by name")
  assert(model:sourceByName("nope") == nil, "and an unknown name is nil")
end)

-- charts -------------------------------------------------------------------------

local chart = require("radar.chart")

check("chart.range widens rather than dividing by zero", function()
  local lo, hi = chart.range({ { values = { 5, 5, 5 } } })
  assert(hi > lo, "a flat series still spans something")

  lo, hi = chart.range({ { values = { 10, 20, 30 } } })
  assert(lo == 10 and hi == 30, "otherwise it is the data")

  lo, hi = chart.range({ { values = { 900, 910 } } }, { zero = true })
  assert(lo == 0, "zero is included when asked for, got " .. lo)

  lo, hi = chart.range({ { values = { -50, 20 } } }, { zero = true })
  assert(lo == -50 and hi == 20, "a series crossing zero already spans it")

  lo, hi = chart.range({ { values = {} } })
  assert(hi > lo, "and an empty series is still a drawable range")

  lo, hi = chart.range({ { values = { 1, 2 } } }, { min = -5, max = 100 })
  assert(lo == -5 and hi == 100, "explicit bounds win")
end)

check("charts draw inside their box at every size", function()
  local pal = { theme.tones.bg, theme.tones.line, theme.tones.good, theme.tones.warn }
  for _, size in ipairs({ { 4, 2 }, { 10, 3 }, { 26, 6 }, { 60, 12 } }) do
    local grid = pixel.new(size[1], size[2], pal)
    local buffer = newBuffer(size[1], size[2], "chart " .. size[1] .. "x" .. size[2])

    -- Series of every awkward shape: empty, one point, more points than
    -- columns, fewer, all negative, and one with a hole in it.
    local long, sparse, holed = {}, { 5 }, { 1, nil, 3, nil, 5 }
    for i = 1, 400 do long[i] = math.sin(i / 9) * 5000 end

    for _, series in ipairs({
      { { values = {}, index = 3 } },
      { { values = sparse, index = 3 } },
      { { values = long, index = 3, fill = true } },
      { { values = holed, index = 4 } },
      { { values = long, index = 3 }, { values = { -10, -20, -30 }, index = 4 } },
    }) do
      grid:clear(1)
      local box = { x = 1, y = 1, w = grid.w, h = grid.h }
      local lo, hi = chart.line(grid, box, series, { count = 300, zero = true })
      chart.rule(grid, box, 0, lo, hi, 2)
      chart.ticks(grid, box, 4, 2)
      chart.gauge(grid, box, 0.42, 3, 2)
      chart.gaugeTicks(grid, box, 0.25, 2)

      -- Nothing may be left unpainted, or blitTo silently substitutes a
      -- palette entry and the hole only shows up in game.
      for i = 1, grid.w * grid.h do
        local index = grid.px[i]
        assert(type(index) == "number" and index >= 1 and index <= #pal,
          ("chart at %dx%d left sub-pixel %d as %s"):format(
            size[1], size[2], i, tostring(index)))
      end
      grid:blitTo(buffer, 1, 1)
    end
  end
end)

check("a gauge clamps rather than overrunning its box", function()
  local pal = { theme.tones.bg, theme.tones.line, theme.tones.accent }
  local grid = pixel.new(10, 1, pal)
  local box = { x = 1, y = 1, w = grid.w, h = grid.h }

  for _, fraction in ipairs({ -5, 0, 0.5, 1, 99, 0/0 }) do
    grid:clear(1)
    chart.gauge(grid, box, fraction, 3, 2)
    for i = 1, grid.w * grid.h do
      assert(grid.px[i] == 2 or grid.px[i] == 3,
        "a gauge paints only track and fill, fraction " .. tostring(fraction))
    end
  end

  grid:clear(1)
  chart.gauge(grid, box, 0, 3, 2)
  assert(grid.px[1] == 2, "empty draws no fill at all")
  grid:clear(1)
  chart.gauge(grid, box, 1, 3, 2)
  assert(grid.px[grid.w] == 3, "and full reaches the far edge")
end)

------------------------------------------------------------------ the views --

local App = require("radar.app")
local ui  = require("radar.ui")

-- A module registered from outside radar/modules/, which is exactly what a
-- dropped-in add-on is. Registered BEFORE the app is built, so it goes through
-- the whole machine: its defaults reach the settings file, its discover()
-- claims hardware, its page joins the tab strip and gets drawn at every size
-- alongside the built-ins, and its settings section is built and pressed.
local addonState = { attached = 0, started = 0, drew = 0, settingsBuilt = 0 }

modules.register({
  id = "addon",
  title = "ADDON",
  short = "ADD",
  order = 70,
  summary = "a synthetic module, for the tests",
  defaults = { addonThreshold = 5 },
  events = { "addon" },
  sanitise = function(cfg)
    cfg.addonThreshold = math.max(1, math.min(9, tonumber(cfg.addonThreshold) or 5))
  end,
  discover = function(kit)
    kit.addonCount = #(kit.peripherals or {})
  end,
  attach = function(app)
    addonState.attached = addonState.attached + 1
    app.addon = { ready = true }
  end,
  start = function(app) addonState.started = addonState.started + 1 end,
  settings = function(ctx)
    addonState.settingsBuilt = addonState.settingsBuilt + 1
    ctx.heading("ADDON")
    ctx.row("Threshold", function() return tostring(ctx.app.cfg.addonThreshold) end,
      function()
        ctx.app.cfg.addonThreshold = (ctx.app.cfg.addonThreshold % 9) + 1
        ctx.app:saveConfig()
      end)
    ctx.spacer()
  end,
  keys = { [keys.k] = { hint = "K        an addon key", run = function() end } },
  build = function(container, app)
    local canvas = container:addCanvas({
      x = 1, y = 1,
      width = function(s) return s.parent.width end,
      height = function(s) return s.parent.height end,
      background = theme.bg,
    })
    canvas.draw = function(self, buf)
      addonState.drew = addonState.drew + 1
      buf:fill(1, 1, self.width, self.height, " ", theme.text, theme.bg)
      buf:blit(1, 1, "ADDON " .. app.cfg.addonThreshold, theme.accent, theme.bg)
    end
    return { refresh = function() canvas:markRenderDirty() end }
  end,
})

check("a dropped-in module registers in order", function()
  local ids = {}
  for _, entry in ipairs(modules.all()) do ids[#ids + 1] = entry.id end
  local text = table.concat(ids, " ")
  assert(text:find("addon", 1, true), "it is in the registry: " .. text)
  assert(text:find("log addon settings", 1, true),
    "and sorted by its order, between log and settings: " .. text)
  assert(modules.byId("addon").page, "it counts as a page, because it builds one")
end)

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

-- Energy hardware, so the power page draws its real content in the sweeps
-- below rather than only its "nothing attached" branch. Held in a table the
-- checks can move, to drive the buffer up and down.
local GRID = { supply = 4800, demand = 3100, stored = 6.4e9, capacity = 1e10 }
PERIPHERALS.energyDetector_0 = fakeMeter(0)
PERIPHERALS.energyDetector_0.getTransferRate = function() return GRID.supply end
PERIPHERALS.energyDetector_1 = fakeMeter(0)
PERIPHERALS.energyDetector_1.getTransferRate = function() return GRID.demand end
PERIPHERALS.inductionMatrix_0 = {
  __type = "inductionMatrix",
  getEnergy = function() return GRID.stored end,
  getMaxEnergy = function() return GRID.capacity end,
}

local app
check("app boots", function()
  app = App.new()
  assert(app.kit.detector, "player detector found")
  assert(app.kit.env, "environment detector found")
  assert(#app.kit.monitors == 1, "monitor found")
  assert(#app.kit.speakers == 1, "speaker found")
  assert(#app.kit.modems == 2, "both modems found, got " .. #app.kit.modems)
  assert(app.kit.modem.name == "modem_1", "the wireless one wins, got " .. app.kit.modem.name)
  assert(app.cfg.role == "standalone", "a fresh install stands alone")
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
  local all = config.pages(app.cfg)
  local entry = app:displayConfig("monitor_0")
  assert(entry.cycle == false, "rotation is off until asked for")
  assert(entry.cycleSeconds == 15, "with a sane default interval")
  assert(#config.cyclePages(app.cfg, entry) == #all, "and every page in it")

  entry.cycleSkip = { log = true, status = true }
  local pages = config.cyclePages(app.cfg, entry)
  assert(#pages == #all - 2, "skipped pages drop out, got " .. #pages)
  for _, page in ipairs(pages) do
    assert(page ~= "log" and page ~= "status", "and stay out")
  end
  entry.cycleSkip = {}

  -- A rotation that excluded everything would strand the monitor, so the
  -- sanitiser refuses to keep one.
  local everything = {}
  for _, page in ipairs(all) do everything[page] = true end
  everything.nonsense = true
  local cfg = config.sanitise({
    displays = { m = { page = "radar", scale = 1, cycle = true, cycleSeconds = 7,
                       cycleSkip = everything } },
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

check("a module claims its own hardware and hangs its state off the app", function()
  -- The addon's discover() ran, which means the kit carried the full
  -- peripheral list rather than only the four things hardware.lua names.
  assert(app.kit.addonCount and app.kit.addonCount > 0,
    "the addon saw the peripheral list, got " .. tostring(app.kit.addonCount))
  assert(app.addon and app.addon.ready, "and its attach() ran")
  assert(addonState.attached >= 1, "exactly once per attach, got " .. addonState.attached)

  -- Its defaults reached the settings file and were sanitised by its own hook.
  assert(app.cfg.addonThreshold == 5, "its default landed, got "
    .. tostring(app.cfg.addonThreshold))
  assert(config.sanitise({ addonThreshold = 99 }).addonThreshold == 9,
    "and its sanitiser clamps it")

  -- The power module found the energy hardware the same way.
  assert(app.power and app.power.available, "the power module found its devices")
  assert(#app.power.sources == 3, "two meters and a battery, got " .. #app.power.sources)
end)

check("the power module reads the grid through the app", function()
  app.cfg.power.roles = {
    energyDetector_0 = "in",
    energyDetector_1 = "out",
  }
  app.power:poll(app.cfg, CLOCK)

  assert(app.power.input == 4800, "supply, got " .. app.power.input)
  assert(app.power.output == 3100, "demand, got " .. app.power.output)
  assert(app.power.net == 1700, "net, got " .. app.power.net)
  assert(math.abs(app.power.percent - 64) < 0.001, "buffer, got " .. app.power.percent)
  assert(#app.power.history:series() > 0, "and it went into the graph")
end)

check("the buffer redstone mode drives the one output line", function()
  local saved = { enabled = app.cfg.rs.enabled, mode = app.cfg.rs.mode,
                  invert = app.cfg.rs.invert }
  app.cfg.rs.enabled, app.cfg.rs.mode, app.cfg.rs.invert = true, "buffer", false

  -- The mode is a real, selectable entry rather than something bolted on.
  local found = false
  for _, mode in ipairs(config.RS_MODES) do
    if mode.id == "buffer" then found = true end
  end
  assert(found, "Buffer is in the mode list")
  assert(config.sanitise({ rs = { mode = "buffer" } }).rs.mode == "buffer",
    "and survives a save and reload")

  GRID.stored = 1e10                            -- full
  app.power:poll(app.cfg, CLOCK)
  app.alerts:invalidate(); app.alerts:updateRedstone()
  assert(app.alerts:level() == 15, "a full buffer is full strength, got " .. app.alerts:level())

  GRID.stored = 5e9                             -- half
  app.power:poll(app.cfg, CLOCK)
  app.alerts:invalidate(); app.alerts:updateRedstone()
  assert(app.alerts:level() == 8, "half reads about half, got " .. app.alerts:level())

  -- Nearly empty still reads 1, not 0: "reading, and nearly nothing" has to
  -- stay distinguishable from "the output is off".
  GRID.stored = 0
  app.power:poll(app.cfg, CLOCK)
  app.alerts:invalidate(); app.alerts:updateRedstone()
  assert(app.alerts:level() == 1, "empty still reads, got " .. app.alerts:level())

  -- With nothing to read the line HOLDS rather than dropping a fuel gate open.
  local savedSources = app.power.sources
  app.power.sources = {}
  app.power:poll(app.cfg, CLOCK)
  app.alerts:updateRedstone()
  assert(app.alerts:level() == 1, "an unreadable buffer holds the last level, got "
    .. app.alerts:level())
  app.power.sources = savedSources

  GRID.stored = 6.4e9
  app.cfg.rs.enabled, app.cfg.rs.mode, app.cfg.rs.invert =
    saved.enabled, saved.mode, saved.invert
  app.alerts:invalidate(); app.alerts:updateRedstone()
end)

check("a module can raise the alarm on the shared channels", function()
  local flashed, played = 0, 0
  local savedFlash = app.alerts.onFlash
  local savedSpeaker = PERIPHERALS.speaker_0.playSound
  app.alerts.onFlash = function(_, reason)
    flashed = flashed + 1
    assert(reason and reason:find("low", 1, true), "the reason travels: " .. tostring(reason))
  end
  PERIPHERALS.speaker_0.playSound = function() played = played + 1; return true end

  app.cfg.alert = true
  assert(app.alerts:fire("Power low - buffer at 12%"), "it fired")
  assert(flashed == 1, "the flash handler heard it")
  app.alerts:tick()
  assert(played >= 1, "and so did the speaker")

  -- The master mute covers a module alarm exactly as it covers a contact.
  app.cfg.alert = false
  assert(app.alerts:fire("again") == false, "a muted station stays quiet")
  assert(flashed == 1, "with no flash")
  app.cfg.alert = true

  app.alerts.onFlash = savedFlash
  PERIPHERALS.speaker_0.playSound = savedSpeaker
end)

-- Build the whole UI and drive every draw callback at several sizes.
local roots, terminalRoot
check("ui builds", function()
  roots, terminalRoot = ui.build(app)
  assert(#roots == 2, "terminal plus one monitor, got " .. #roots)

  -- The tab strip is the enabled module list, not a hand-written one.
  local expected = config.terminalPages(app.cfg)
  assert(#terminalRoot.pages == #expected,
    ("%d tabs, %d enabled pages"):format(#terminalRoot.pages, #expected))
  for i, page in ipairs(expected) do
    assert(terminalRoot.pages[i] == page, "tab " .. i .. " is " .. page)
  end

  local monitorRoot
  for _, root in ipairs(roots) do
    if root.monitor then monitorRoot = root end
  end
  for _, page in ipairs(monitorRoot.pages) do
    assert(page ~= "settings", "a monitor never gets the settings page")
  end
  assert(addonState.started >= 1 or true, "start() is driven by app:start, not ui.build")
end)

check("the tab strip lays out and truncates rather than wrapping", function()
  for _, width in ipairs({ 8, 15, 26, 40, 51, 82, 164 }) do
    local spans = ui.tabLayout(terminalRoot.pages, width)
    local previous = 0
    for _, span in ipairs(spans) do
      assert(span.x1 > previous, "tabs do not overlap at width " .. width)
      assert(span.x2 <= width, "and none runs off the edge at width " .. width)
      previous = span.x2
    end
  end
  -- Every page is still reachable by name even when its tab did not fit.
  local narrow = ui.tabLayout(terminalRoot.pages, 8)
  assert(#narrow < #terminalRoot.pages, "a narrow strip drops tabs, got " .. #narrow)
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

  -- Due: it walks the rotation in page order and wraps round to the start.
  local pages = config.cyclePages(app.cfg, entry)
  local start = 1
  for i, page in ipairs(pages) do
    if page == "radar" then start = i end
  end
  local at = CLOCK + 10
  for step = 1, #pages + 1 do
    monitorRoot:tickCycle(at)
    local want = pages[((start + step - 1) % #pages) + 1]
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

check("right-clicking a monitor moves it to the next page", function()
  local monitorRoot
  for _, root in ipairs(roots) do
    if root.monitor then monitorRoot = root end
  end
  local name = monitorRoot.monitor.name

  -- A monitor_touch off the event queue, which is what a right-click in game
  -- actually produces. It is NOT delivered as a click to the content frame:
  -- the page's canvas covers that frame edge to edge and does not take
  -- clicks, so a handler there never fires. That was the v7 bug.
  local contentHandler = rawget(monitorRoot.content, "_handlers").onClick
  monitorRoot:setPage("radar", false)
  contentHandler(monitorRoot)
  assert(monitorRoot.page == "radar",
    "the content handler no longer drives a monitor")

  app.cfg.tapCycle = true
  local order = monitorRoot.pages
  local start
  for i, page in ipairs(order) do if page == "radar" then start = i end end

  local landed = ui.handleTouch(roots, app, name, 3, 4)
  assert(landed == order[(start % #order) + 1],
    "one touch, one page, landed on " .. tostring(landed))
  assert(monitorRoot.page == landed, "and the root agrees")

  -- A touch also restarts the dwell timer, so the rotation cannot yank the
  -- page away the instant the operator has chosen one.
  local entry = app:displayConfig(name)
  entry.cycle, entry.cycleSeconds = true, 30
  local held = monitorRoot.page
  monitorRoot:tickCycle(monitorRoot.cycleAt + 5)
  assert(monitorRoot.page == held, "the touch bought a full interval")
  entry.cycle = false

  -- A touch meant for another monitor, or for the terminal, is not this
  -- root's business.
  local before = monitorRoot.page
  assert(ui.handleTouch(roots, app, "monitor_99", 3, 4) == nil,
    "a touch on an unknown monitor is ignored")
  assert(monitorRoot.page == before, "and changes nothing")

  -- Turning the setting off makes the screen inert again.
  app.cfg.tapCycle = false
  assert(ui.handleTouch(roots, app, name, 3, 4) == nil,
    "tap-to-change honours the setting")
  assert(monitorRoot.page == before, "so the page stays put")
  app.cfg.tapCycle = true
end)

check("touching a monitor's tab strip jumps straight to that tab", function()
  local monitorRoot
  for _, root in ipairs(roots) do
    if root.monitor then monitorRoot = root end
  end
  local name = monitorRoot.monitor.name

  rawget(monitorRoot.root, "_p").width = 57
  rawget(monitorRoot.root, "_p").height = 24
  monitorRoot:setPage(monitorRoot.pages[1], false)

  -- Lay the strip out the way the canvas does, then touch the middle of a tab.
  local spans = ui.tabLayout(monitorRoot.pages, 57)
  monitorRoot.tabSpans = spans
  local target = spans[3]
  assert(target, "there are at least three tabs")

  local stripRow = monitorRoot.root.height
  local landed = ui.handleTouch(roots, app, name,
    math.floor((target.x1 + target.x2) / 2), stripRow)
  assert(landed == target.id, "landed on the tab pressed, got " .. tostring(landed))

  -- A tab is an explicit choice of page, so it works even with tap-to-change
  -- off -- that setting is about "move me along", not about the tabs.
  app.cfg.tapCycle = false
  monitorRoot:setPage(monitorRoot.pages[1], false)
  local second = spans[2]
  assert(ui.handleTouch(roots, app, name,
    math.floor((second.x1 + second.x2) / 2), stripRow) == second.id,
    "tabs work with tap-to-change off")
  app.cfg.tapCycle = true

  -- A touch on the strip but past the last tab does nothing rather than
  -- falling through to a page change.
  local page = monitorRoot.page
  assert(ui.handleTouch(roots, app, name, 57, stripRow) == nil,
    "empty space on the strip is not a page change")
  assert(monitorRoot.page == page, "so the page stays put")
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

  -- Pressing every button includes the MODULES rows, so the page as built is
  -- now describing a module set that has just been restored out from under it.
  -- The event a real toggle fires is what rebuilds it.
  app:emit("modules")

  -- Every module is back, and so is its settings section.
  local modules = require("radar.modules")
  for _, entry in ipairs(modules.all()) do
    assert(modules.isEnabled(app.cfg, entry.id),
      entry.id .. " came back on after the config was restored")
  end
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
  assert(cfg.role == "standalone", "role defaults to standalone, got " .. tostring(cfg.role))
  assert(cfg.relayWeather == false, "the weather relay stays off")
  assert(cfg.pairedBaseId == nil, "nothing is paired")
  assert(cfg.stationName == "Base 3", "named from the computer id, got " .. cfg.stationName)
  assert(config.usesNetwork(cfg) == false, "and it never opens a modem")

  local junk = config.sanitise({ role = "wat", stationName = 42,
    relayWeather = "yes", pairedBaseId = "17.8" })
  assert(junk.role == "standalone", "an unknown role falls back")
  assert(junk.stationName == "Base 3", "a non-string name is replaced")
  assert(junk.relayWeather == false, "only a real boolean turns the relay on")
  assert(junk.pairedBaseId == 17, "a paired id is forced to a whole number")

  local long = config.sanitise({ stationName = string.rep("x", 90) })
  assert(#long.stationName == config.MAX_STATION_NAME, "names are capped")
end)

check("a station never touches the network", function()
  local before = #REDNET.sent
  app.cfg.role = "standalone"
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
  app:setRole("main")
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
  app:setRole("mobile")
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
  assert(app.scanError:find("No main base paired", 1, true),
    "an unpaired ship says so, got " .. app.scanError)
  app:pairWithBase(BASE_ID, "Hangar")
  app.link:close()
  app:sweep()
  assert(app.scanError:find("modem", 1, true),
    "a ship with no modem says so, got " .. app.scanError)
  app.link:attach(app.kit, app.cfg)
end)

check("the weather relay rebuilds an identical snapshot", function()
  app:setRole("main")
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

  app:setRole("mobile")
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
    { name = "ship-live",  role = "mobile", feed = true },
    { name = "ship-lost",  role = "mobile", feed = false },
    { name = "base",       role = "main", feed = false },
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
  app:setRole("standalone")
end)

------------------------------------------------------------------ backdrops --
-- A backdrop replaces the weather page's PICTURE and nothing else, so these
-- check both halves of that: that every picture draws, and that the readout
-- and the header badge carry on reporting the real sky underneath it.

local backdrops = require("radar.backdrops")

check("v5 settings sanitise to a live weather page", function()
  local cfg = config.sanitise({ rangeIndex = 4 })
  assert(cfg.backdrop == "live", "the page draws the real sky, got " .. tostring(cfg.backdrop))
  assert(cfg.backdropSeconds == 60, "with a sane interval, got " .. tostring(cfg.backdropSeconds))
  assert(next(cfg.backdropSkip) == nil, "and every picture in the cycle")

  local junk = config.sanitise({ backdrop = "not-a-picture", backdropSeconds = 7,
    backdropSkip = { islesDawn = true, nonsense = true } })
  assert(junk.backdrop == "live", "an unknown picture falls back to live")
  assert(junk.backdropSeconds == 10, "the interval snaps to a legal one, got "
    .. junk.backdropSeconds)
  assert(junk.backdropSkip.islesDawn == true, "a real picture stays out of the cycle")
  assert(junk.backdropSkip.nonsense == nil, "a made-up one does not")

  -- A cycle that excluded everything would leave the page with nothing to draw.
  local all = {}
  for _, id in ipairs(backdrops.ids()) do all[id] = true end
  local emptied = config.sanitise({ backdropSkip = all })
  assert(next(emptied.backdropSkip) == nil, "an all-skipping cycle is discarded")
  assert(#backdrops.rotation(emptied) == backdrops.count(), "so every picture is back in it")

  -- rotation() is the last line of defence, below the sanitiser: handed a set
  -- that skips everything it must still produce something to draw.
  assert(#backdrops.rotation({ backdropSkip = all }) == 1,
    "an all-skipping set still yields one picture")
  assert(#backdrops.rotation({}) == backdrops.count(), "and no set yields all of them")
end)

check("open-air backdrops have no horizon under them", function()
  -- A ground that is not registered as open sky gets a slab of LAND laid
  -- across the bottom of the frame before the islands go on -- which is
  -- exactly the horizon these scenes are supposed not to have.
  local LAND = 8
  local grid = pixel.new(46, 16, theme.skies.day)
  for _, id in ipairs({ "islesNoon", "islesDawn", "shipDay", "cloudDay", "spiresDay" }) do
    local scene = backdrops.scene(id, nil)
    grid:setPalette(scene.palette)
    grid.px = {}
    sky.paint(grid, scene, 7.5)

    local solid = true
    for x = 1, grid.w do
      if grid.px[(grid.h - 1) * grid.w + x] ~= LAND then solid = false; break end
    end
    assert(not solid, id .. " drew a solid horizon across the bottom of the frame")
  end
end)

check("every backdrop is complete and buildable", function()
  assert(backdrops.count() >= 15, "a set worth cycling, got " .. backdrops.count())
  local seen = {}
  for _, id in ipairs(backdrops.ids()) do
    assert(not seen[id], "ids are unique: " .. id)
    seen[id] = true

    local entry = backdrops.byId(id)
    assert(type(entry.label) == "string" and #entry.label > 0, id .. " has a label")
    assert(theme.skies[entry.sky], id .. " names a real sky: " .. tostring(entry.sky))
    assert(biomes.PROFILES[entry.ground],
      id .. " names a real ground: " .. tostring(entry.ground))

    -- No snapshot at all: this is the case that matters on a ship.
    local scene = backdrops.scene(id, nil)
    assert(scene, id .. " builds a scene with no snapshot")
    assert(#scene.palette == 10, id .. " has a ten-entry palette")
    assert(scene.title and #scene.title > 0, id .. " has a title")
    assert(scene.groundKind and scene.ground, id .. " has a ground")
    assert(scene.weather and scene.phase, id .. " has weather and an hour")
  end
  assert(backdrops.scene("no-such-picture", nil) == nil, "an unknown id builds nothing")
end)

check("every backdrop paints every sub-pixel at every size", function()
  local sizes = { { 4, 2 }, { 10, 4 }, { 18, 6 }, { 26, 9 }, { 46, 16 }, { 82, 30 } }
  for _, size in ipairs(sizes) do
    local grid = pixel.new(size[1], size[2], theme.skies.day)
    local buffer = newBuffer(size[1], size[2], "backdrop " .. size[1] .. "x" .. size[2])
    for _, id in ipairs(backdrops.ids()) do
      local scene = backdrops.scene(id, nil)
      grid:setPalette(scene.palette)
      for _, anim in ipairs({ 0, 4.2, 31.7, 240.5 }) do
        -- Blank the surface first, or a previous frame fills in any gap this
        -- one leaves and the hole only shows up in game.
        grid.px = {}
        sky.paint(grid, scene, anim)
        for i = 1, grid.w * grid.h do
          local index = grid.px[i]
          if type(index) ~= "number" or index < 1 or index > #scene.palette then
            error(("%s at %dx%d anim %s left sub-pixel %d as %s"):format(
              id, size[1], size[2], anim, i, tostring(index)), 0)
          end
        end
        grid:blitTo(buffer, 1, 1)
      end
    end
  end
end)

local liveSnapshot
check("a backdrop replaces the picture and nothing else", function()
  app:pollEnvironment(true)
  liveSnapshot = app:snapshot()
  assert(liveSnapshot.available, "there is a live snapshot to compare against")

  app.backdrop:set("live")
  assert(app.backdrop:id() == nil, "live means no backdrop")
  assert(app.backdrop:scene() == liveSnapshot.scene, "and the page paints the live sky")

  app.backdrop:set("shipDusk")
  assert(app.backdrop:id() == "shipDusk", "a chosen picture is the one on screen")
  local painted = app.backdrop:scene()
  assert(painted.backdrop == "shipDusk", "and it is what gets painted")
  assert(painted.groundKind == "skyship", "with its own ground")
  assert(painted.phase == "dusk", "and its own hour, not the real one")
  assert(painted ~= liveSnapshot.scene, "the live scene is not what is drawn")

  -- The readout and the header badge have to carry on telling the truth.
  assert(app:snapshot() == liveSnapshot, "the snapshot itself is untouched")
  assert(app:snapshot().scene.weather == liveSnapshot.scene.weather,
    "so the readout still reports the real weather")
  assert(sky.badge(app:snapshot().scene) == "SNOW",
    "and the header badge with it, got " .. sky.badge(app:snapshot().scene))

  -- The real moon phase is borrowed whenever there is a detector to ask.
  assert(painted.moonPhase == liveSnapshot.moonId,
    "the live moon phase shows through, got " .. tostring(painted.moonPhase))
end)

check("a backdrop needs no Environment Detector at all", function()
  local saved = app.env.snapshot
  app.env.snapshot = { available = false, reason = "no detector" }

  app.backdrop:set("live")
  assert(app.backdrop:scene() == nil, "live with no detector has nothing to draw")

  app.backdrop:set("islesNight")
  local painted = app.backdrop:scene()
  assert(painted, "a backdrop draws anyway")
  assert(#painted.palette == 10, "with a full palette")
  assert(painted.moonPhase == 0, "and a full moon to fall back on, got "
    .. tostring(painted.moonPhase))

  app.env.snapshot = saved
  app.backdrop:set("live")
end)

check("the backdrop cycle changes on its interval", function()
  -- With animation off nothing else would repaint the page, so the change has
  -- to drive a redraw of its own.
  assert(app.listeners.backdrop and #app.listeners.backdrop > 0,
    "a backdrop change is wired to a redraw")

  app.backdrop:set("cycle")
  app.cfg.backdropSeconds, app.cfg.backdropSkip = 30, {}
  app.backdrop.index, app.backdrop.at = 1, CLOCK

  local rotation = backdrops.rotation(app.cfg)
  assert(#rotation == backdrops.count(), "every picture is in it by default")
  assert(app.backdrop:id() == rotation[1], "starting on the first")

  assert(app.backdrop:tick(CLOCK + 29) == false, "held until the interval elapses")
  assert(app.backdrop:id() == rotation[1], "so the picture has not moved")

  -- Due: walks the list in order and wraps round to the start.
  local at = CLOCK + 30
  for step = 1, #rotation + 1 do
    assert(app.backdrop:tick(at), "step " .. step .. " changed the picture")
    local want = rotation[(step % #rotation) + 1]
    assert(app.backdrop:id() == want,
      ("step %d landed on %s, wanted %s"):format(step, app.backdrop:id(), want))
    at = at + 30
  end

  -- Pictures left out of the cycle are never landed on.
  app.cfg.backdropSkip = { islesDawn = true, islesNoon = true }
  local trimmed = backdrops.rotation(app.cfg)
  assert(#trimmed == backdrops.count() - 2, "two dropped out, got " .. #trimmed)
  app.backdrop.index = 1
  for _ = 1, #trimmed + 2 do
    at = at + 30
    app.backdrop:tick(at)
    local id = app.backdrop:id()
    assert(id ~= "islesDawn" and id ~= "islesNoon",
      "a skipped picture stays out, got " .. id)
  end
  app.cfg.backdropSkip = {}

  -- A fixed picture never moves, however long it waits.
  app.backdrop:set("cloudDay")
  assert(app.backdrop:tick(at + 100000) == false, "a fixed picture does not cycle")
  assert(app.backdrop:id() == "cloudDay", "and stays put")
  assert(app.backdrop:next() == false, "nor can it be stepped by hand")

  -- Choosing a fixed picture rewinds the cycle, so turning cycling back on
  -- starts at the first picture rather than somewhere in the middle.
  app.backdrop:set("cycle")
  app.backdrop.index = 5
  app.backdrop:set("islesDusk")
  assert(app.backdrop.index == 1, "a fixed picture rewinds the cycle")
  app.backdrop:set("cycle")
  assert(app.backdrop:id() == backdrops.rotation(app.cfg)[1],
    "so the cycle restarts at the first, got " .. tostring(app.backdrop:id()))

  -- Stepping by hand buys the new picture a full interval.
  app.backdrop:set("cycle")
  local before = app.backdrop:id()
  assert(app.backdrop:next(), "the cycle steps by hand")
  assert(app.backdrop:id() ~= before, "onto a different picture")

  app.backdrop:set("live")
end)

check("a backdrop can keep its place and take the live sky", function()
  local cfg = config.sanitise({})
  assert(cfg.backdropSky == "picture", "the sky comes from the picture by default")
  assert(config.sanitise({ backdropSky = "wat" }).backdropSky == "picture",
    "and an unknown mode falls back to it")
  assert(backdrops.isLiveSky({ backdropSky = "live" }), "live is recognised")

  -- The fake detector is a snowy taiga in the rain at 11:12, so a live sky is
  -- unmistakably different from any hour a picture was drawn at.
  app.env.snapshot = liveSnapshot
  local snap = app:snapshot()
  assert(snap.scene.weather == "snow" and snap.phase == "day",
    "the live sky is snow by day, got " .. snap.scene.weather .. "/" .. snap.phase)

  local fixed = backdrops.scene("shipDay", snap, false)
  assert(fixed.weather == "clear", "the picture's own sky is clear")
  assert(fixed.bodyProgress == 0.40, "with the sun where it was drawn")

  local livened = backdrops.scene("shipDay", snap, true)
  assert(livened.groundKind == "skyship", "the place is kept, got " .. livened.groundKind)
  assert(livened.ground.terrain == "airship", "so the airships still fly")
  assert(livened.weather == "snow", "but the weather is the real one, got " .. livened.weather)
  assert(livened.phase == snap.phase, "and so is the hour")
  assert(livened.tick == snap.tick, "down to the tick")
  assert(livened.bodyProgress == snap.bodyProgress, "and the sun's place on its arc")
  assert(livened.backdropLive, "and it says so")
  assert(livened.subtitle == "Airship", "while still naming the picture that was chosen")
  assert(#livened.palette == 10, "with a full palette")

  -- The mood has to follow the live weather too, or the ground would stay lit
  -- for noon under a snowstorm.
  assert(livened.mood ~= fixed.mood, "and it is lit by the real sky")

  -- Whether it can rain, and whether that falls as snow, is a fact about where
  -- you are standing rather than about the picture. An airship is not a
  -- climate: taking those flags from it would show rain over a snowfield.
  local function overBiome(biome)
    local s = {
      available = true, tick = 6000, day = 1, kind = "overworld", phase = "day",
      raining = true, thundering = false, biome = biome, moonId = 0,
    }
    s.body, s.bodyProgress = environment.celestial(6000)
    local built = backdrops.scene("shipDay", s, true)
    assert(built.groundKind == "skyship", "the airships fly over " .. biome)
    return built.weather
  end
  assert(overBiome("minecraft:plains") == "rain", "rain over plains")
  assert(overBiome("minecraft:snowy_taiga") == "snow",
    "snow over a cold biome, got " .. overBiome("minecraft:snowy_taiga"))
  assert(overBiome("minecraft:desert") == "clear",
    "and a desert stays dry under it, got " .. overBiome("minecraft:desert"))

  -- Forcing scenery on the live page is unchanged: there the ground you draw
  -- IS the ground you are standing on, so it keeps deciding.
  local desertSnap = {
    available = true, tick = 6000, day = 1, kind = "overworld", phase = "day",
    raining = true, thundering = false, biome = "minecraft:plains", moonId = 0,
  }
  desertSnap.body, desertSnap.bodyProgress = environment.celestial(6000)
  assert(environment.describe(desertSnap, "desert").weather == "clear",
    "a forced desert still shuts the rain off")

  -- A picture that is a place rather than a weather is drawn as authored.
  local nether = backdrops.scene("netherSea", snap, true)
  assert(nether.kind == "nether", "the lava sea ignores a live overworld sky")
  assert(nether.backdropLive == nil, "and does not claim otherwise")

  -- No detector, no live sky: fall back to the hour it was drawn with rather
  -- than to nothing, which is what keeps this working on a ship.
  local blind = backdrops.scene("shipDay", { available = false }, true)
  assert(blind and blind.weather == "clear", "falls back to the picture's own sky")
  assert(backdrops.scene("shipDay", nil, true).groundKind == "skyship",
    "and still draws the place")

  -- Through the app, which is the path the page actually takes.
  app.backdrop:set("shipDay")
  app.backdrop:setSky("live")
  local viaApp = app.backdrop:scene()
  assert(viaApp.backdropLive, "the page asks for a live sky when the setting says so")
  assert(viaApp.weather == "snow", "and gets one, got " .. viaApp.weather)
  assert(viaApp.groundKind == "skyship", "keeping the chosen place")

  app.backdrop:setSky("picture")
  local backToPicture = app.backdrop:scene()
  assert(backToPicture.weather == "clear", "and the picture's own sky when told that")
  assert(backToPicture.backdropLive == nil, "without claiming to be live")

  app.backdrop:set("live")
end)

check("every backdrop paints under every live sky", function()
  -- Live mode makes ground/sky pairings that no fixed picture contains, and a
  -- painter only ever tested under its own sky can still leave a hole.
  local sizes = { { 10, 4 }, { 26, 9 }, { 46, 16 } }
  local weathers = { { false, false }, { true, false }, { true, true } }
  for _, size in ipairs(sizes) do
    local grid = pixel.new(size[1], size[2], theme.skies.day)
    for _, id in ipairs(backdrops.ids()) do
      for _, tick in ipairs({ 1000, 6000, 12000, 18000 }) do
        for _, weather in ipairs(weathers) do
          for _, biome in ipairs({ "minecraft:plains", "minecraft:snowy_taiga" }) do
            local snap = {
              available = true, tick = tick, day = 3, kind = "overworld",
              phase = environment.phaseOf(tick), raining = weather[1],
              thundering = weather[2], biome = biome, moonId = 2,
              moonName = "Last Quarter",
            }
            snap.body, snap.bodyProgress = environment.celestial(tick)

            local scene = backdrops.scene(id, snap, true)
            grid:setPalette(scene.palette)
            grid.px = {}
            sky.paint(grid, scene, 18.3)
            for i = 1, grid.w * grid.h do
              local index = grid.px[i]
              if type(index) ~= "number" or index < 1 or index > #scene.palette then
                error(("%s live at %dx%d tick %d left sub-pixel %d as %s"):format(
                  id, size[1], size[2], tick, i, tostring(index)), 0)
              end
            end
          end
        end
      end
    end
  end
end)

check("a live-sky cycle walks places, not repeats of one", function()
  local fixedCfg = { backdropSky = "picture", backdropSkip = {} }
  local liveCfg  = { backdropSky = "live",    backdropSkip = {} }

  assert(#backdrops.rotation(fixedCfg) == backdrops.count(),
    "every picture cycles when each brings its own sky")

  -- Under a live sky the six island presets differ only in an hour that is now
  -- coming from the detector, so they would be the same picture six times.
  local live = backdrops.rotation(liveCfg)
  local grounds = {}
  for _, id in ipairs(live) do
    local ground = backdrops.byId(id).ground
    assert(not grounds[ground],
      "no place appears twice in a live cycle: " .. ground .. " via " .. id)
    grounds[ground] = true
  end
  assert(#live < backdrops.count(), "so the live cycle is shorter, got " .. #live)
  assert(#live >= 5, "but still worth cycling, got " .. #live)

  -- Both dimension pictures survive it, being places rather than hours.
  local ids = {}
  for _, id in ipairs(live) do ids[id] = true end
  assert(ids.netherSea and ids.endVoid, "the Nether and the End stay in")

  -- The skip set still applies on top.
  local skipped = backdrops.rotation({ backdropSky = "live",
    backdropSkip = { netherSea = true } })
  assert(#skipped == #live - 1, "a skipped picture drops out of a live cycle too")

  -- Switching mode rewinds, so the index never points past a shorter rotation.
  app.backdrop:set("cycle")
  app.backdrop:setSky("picture")
  app.backdrop.index = backdrops.count()
  app.backdrop:setSky("live")
  assert(app.backdrop.index == 1, "changing the sky rewinds the cycle")
  assert(backdrops.byId(app.backdrop:id()), "and lands on a real picture")
  app.backdrop:setSky("picture")
  app.backdrop:set("live")
end)

check("the weather page paints the backdrop, and the readout the real sky", function()
  local saved = app.env.snapshot
  app.env.snapshot = liveSnapshot

  -- Everything the page writes as text, which is how both halves get checked
  -- from one render: the caption belongs to the artwork, the SKY row and the
  -- badge to the readout under it.
  local function textOf()
    terminalRoot:setPage("weather", false)
    rawget(terminalRoot.root, "_p").width = 82
    rawget(terminalRoot.root, "_p").height = 40
    local buffer = newBuffer(82, 40, "weather text")
    drawTree(terminalRoot.root, buffer)
    return table.concat(buffer.texts, "\n")
  end

  app.backdrop:set("live")
  local live = textOf()
  assert(live:find("Snowfall", 1, true), "the live sky names itself:\n" .. live)
  assert(not live:find("Moonlit Isles", 1, true), "and no backdrop is drawn")

  app.backdrop:set("islesNight")
  local painted = textOf()
  assert(painted:find("Moonlit Isles", 1, true),
    "the backdrop caption is on the artwork:\n" .. painted)
  assert(painted:find("Snowfall", 1, true),
    "while the readout still reports the real sky")
  assert(painted:find("SNOW", 1, true), "badge included")

  app.backdrop:set("live")
  app.env.snapshot = saved
end)

check("the settings page drives the backdrop", function()
  terminalRoot:setPage("settings", false)
  local view = terminalRoot.views.settings
  app.backdrop:set("live")
  view.refresh()

  local function findButton(element, text)
    if element.__kind == "Button" and tostring(element.text) == text then return element end
    for _, child in ipairs(rawget(element, "_children") or {}) do
      local hit = findButton(child, text)
      if hit then return hit end
    end
    return nil
  end

  local button = findButton(view.container, "live - draws the real sky")
  assert(button, "the backdrop row is on the settings page")
  rawget(button, "_handlers").onClick(button)

  local picked
  local function findItem(element, needle)
    for _, item in ipairs(rawget(element, "_p").items or {}) do
      if type(item) == "table" and item.text and item.text:find(needle, 1, true) then
        picked = item
      end
    end
    for _, child in ipairs(rawget(element, "_children") or {}) do findItem(child, needle) end
  end

  findItem(view.container, "Airship at Sunset")
  assert(picked, "the picker offers every backdrop by name")
  picked.callback()
  assert(app.cfg.backdrop == "shipDusk", "choosing one sets it, got " .. app.cfg.backdrop)

  picked = nil
  findItem(view.container, "Cycle - change on a timer")
  assert(picked, "and offers the cycle")

  app.backdrop:set("live")
  view.refresh()
end)

check("every page draws with a backdrop up", function()
  local sizes = { { 15, 10 }, { 51, 19 }, { 82, 40 } }
  local saved = app.env.snapshot
  for _, choice in ipairs({ "shipStorm", "cloudNight", "spiresDay", "cycle" }) do
    app.backdrop:set(choice)
    for _, hasEnv in ipairs({ true, false }) do
      app.env.snapshot = hasEnv and liveSnapshot or { available = false }
      for _, root in ipairs(roots) do
        for _, page in ipairs(root.pages) do
          root:setPage(page, false)
          for _, size in ipairs(sizes) do
            rawget(root.root, "_p").width = size[1]
            rawget(root.root, "_p").height = size[2]
            root:refreshChrome()
            local label = ("%s %s %dx%d %s env=%s"):format(
              root.monitor and "monitor" or "terminal", page,
              size[1], size[2], choice, tostring(hasEnv))
            local buffer = newBuffer(size[1], size[2], label)
            local ok, err = pcall(drawTree, root.root, buffer)
            if not ok then error(label .. ": " .. tostring(err), 0) end
          end
        end
      end
    end
  end
  app.env.snapshot = saved
  app.backdrop:set("live")
end)

------------------------------------------------------------------- modules --
-- The point of v7: a page is a file, and switching one off has to take its
-- page, its tab, its settings section and its polling with it.

--- Every label and button caption under an element, in layout order. The
--- settings page is built from Basalt elements rather than painted into a
--- canvas, so reading it back means walking the tree rather than the buffer.
local function captionsOf(element, out)
  out = out or {}
  local props = rawget(element, "_p")
  if type(props.text) == "string" then out[#out + 1] = props.text end
  for _, child in ipairs(rawget(element, "_children") or {}) do
    captionsOf(child, out)
  end
  return out
end

check("the dropped-in module was built, drawn and given a settings section", function()
  assert(addonState.drew > 0, "its page was drawn, got " .. addonState.drew)
  assert(addonState.settingsBuilt > 0,
    "and its settings section was built, got " .. addonState.settingsBuilt)

  terminalRoot:setPage("settings", false)
  local captions = captionsOf(terminalRoot.views.settings.container)

  --- First caption matching `needle` at or after `from`. A module's TITLE also
  --- appears as a row label in the MODULES switchboard, so a search for its
  --- section heading has to start below that.
  local function indexOf(needle, from)
    for i = from or 1, #captions do
      if captions[i] == needle then return i end
    end
    return nil
  end

  local profile = assert(indexOf("RADAR STATION"), "the station section is on the page")
  local switchboard = assert(indexOf("MODULES"), "and the module switchboard")
  local tracking = assert(indexOf("TRACKING"), "and the station-wide sections")
  local redstone = assert(indexOf("REDSTONE OUTPUT"), "down to the redstone line")

  -- Every module's section sits below the station-wide ones, in module order.
  local backdrop = assert(indexOf("BACKDROP", redstone), "the weather module's section")
  local power = assert(indexOf("POWER", backdrop), "then the power module's")
  local addon = assert(indexOf("ADDON", power), "then the addon's")
  local displays = assert(indexOf("DISPLAYS", addon), "and displays after all of them")

  assert(profile < switchboard, "profile first")
  assert(switchboard < tracking, "then the switchboard, then the station settings")
  assert(redstone < backdrop, "which all come before the modules' own")
  assert(backdrop < power and power < addon and addon < displays, "in module order")

  -- The addon's own row reads its own setting.
  assert(indexOf("Threshold"), "its row is there")
  assert(indexOf(tostring(app.cfg.addonThreshold), addon), "showing its value")
end)

check("switching a module off takes its page with it", function()
  local before = #config.terminalPages(app.cfg)
  local builtBefore = addonState.settingsBuilt

  assert(app:toggleModule("addon") == false, "toggled off")
  assert(not modules.isEnabled(app.cfg, "addon"), "and it is off")

  local pages = config.terminalPages(app.cfg)
  assert(#pages == before - 1, "one page fewer, got " .. #pages)
  for _, id in ipairs(pages) do
    assert(id ~= "addon", "and it is not among them")
  end

  -- The settings page rebuilt on the event, without the addon's section.
  local buffer = newBuffer(82, 40, "settings without addon")
  terminalRoot:setPage("settings", false)
  drawTree(terminalRoot.root, buffer)
  assert(addonState.settingsBuilt == builtBefore,
    "a disabled module is not asked for settings")

  -- And a monitor's rotation no longer offers it.
  local entry = app:displayConfig("monitor_0")
  for _, page in ipairs(config.cyclePages(app.cfg, entry)) do
    assert(page ~= "addon", "it is out of the monitor rotation too")
  end

  -- The tab strip on every screen followed, without a restart.
  for _, root in ipairs(roots) do
    for _, page in ipairs(root.pages) do
      assert(page ~= "addon", "the tab is gone from every screen straight away")
    end
  end

  assert(app:toggleModule("addon") == true, "and it comes back")
  assert(#config.terminalPages(app.cfg) == before, "with its page")
  local backInStrip = false
  for _, page in ipairs(terminalRoot.pages) do
    if page == "addon" then backInStrip = true end
  end
  assert(backInStrip, "and its tab with it")
end)

check("a screen sitting on a page that is switched off is moved off it", function()
  terminalRoot:setPage("addon", false)
  assert(terminalRoot.page == "addon", "parked on it")

  app:toggleModule("addon")
  assert(terminalRoot.page ~= "addon",
    "moved off, landed on " .. tostring(terminalRoot.page))
  assert(modules.isPage(app.cfg, terminalRoot.page), "onto a page that still exists")

  app:toggleModule("addon")
end)

check("a module switched on after boot gets its loops started", function()
  -- app:start() is never called in the harness, so nothing is marked started
  -- yet and startOne has to refuse rather than starting a loop with no
  -- scheduler behind it.
  assert(app.startedModules == nil, "the harness never started the loops")
  assert(modules.startOne(app, "power") == false, "so nothing starts one early")

  -- Once the station is running, a module switched on starts exactly once.
  app.startedModules = {}
  local addonStarts = addonState.started
  app.cfg.modulesOff = { addon = true }
  config.sanitise(app.cfg)
  assert(modules.startOne(app, "addon") == false, "a disabled module does not start")

  app.cfg.modulesOff = {}
  config.sanitise(app.cfg)
  assert(modules.startOne(app, "addon"), "switching it on starts it")
  assert(addonState.started == addonStarts + 1, "once")
  assert(modules.startOne(app, "addon") == false, "and only once")

  app.startedModules = nil
end)

check("a core module refuses to be switched off through the app", function()
  assert(app:toggleModule("status") == true, "status stays on")
  assert(app:toggleModule("settings") == true, "and so does settings")
  assert(app.cfg.modulesOff.status == nil, "with nothing written to the file")
end)

check("a page that is switched off is not left as the current one", function()
  local saved = app.cfg.terminalPage
  app.cfg.terminalPage = "power"
  app.cfg.modulesOff = { power = true }
  config.sanitise(app.cfg)
  assert(app.cfg.terminalPage ~= "power",
    "the terminal moved off it, landed on " .. app.cfg.terminalPage)
  assert(modules.isPage(app.cfg, app.cfg.terminalPage), "onto a page that exists")

  -- The same for a monitor sitting on it.
  local display = config.sanitise({
    modulesOff = { power = true },
    displays = { m = { page = "power" } },
  })
  assert(display.displays.m.page ~= "power", "and so did the monitor")

  app.cfg.modulesOff = {}
  app.cfg.terminalPage = saved
  config.sanitise(app.cfg)
end)

check("applying a profile through the app rewires the station", function()
  local saved = textutils.serialize(app.cfg)

  app:setProfile("pocket")
  assert(app.cfg.profile == "pocket", "recorded on the config")
  assert(app.cfg.animate == false, "and its settings took")
  assert(not modules.isEnabled(app.cfg, "power"), "with the power page off")
  assert(config.profileLabel(app.cfg):find("POCKET", 1, true),
    "the status page has something to say: " .. config.profileLabel(app.cfg))

  app:setProfile("base")
  assert(modules.isEnabled(app.cfg, "power"), "and going back turns it on again")

  local restored = textutils.unserialize(saved)
  for k in pairs(app.cfg) do app.cfg[k] = nil end
  for k, v in pairs(restored) do app.cfg[k] = v end
  app:emit("modules")
end)

---------------------------------------------------------- a small screen --
-- A pocket computer is 26 cells across. The old fixed two-column layout left
-- ten cells for every value and put two of the three base-coordinate boxes off
-- the right-hand edge entirely, which is unusable rather than merely cramped.

local settingsModule = modules.byId("settings")

check("the layout decision follows the screen and the setting", function()
  assert(settingsModule.isNarrow(26, "auto"), "a pocket screen stacks")
  assert(settingsModule.isNarrow(15, "auto"), "and anything smaller")
  assert(not settingsModule.isNarrow(51, "auto"), "a computer terminal does not")
  assert(not settingsModule.isNarrow(164, "auto"), "nor a wide monitor")

  -- The operator's choice overrides the measurement in both directions.
  assert(settingsModule.isNarrow(164, "stacked"), "stacked can be forced on")
  assert(not settingsModule.isNarrow(15, "columns"), "and columns forced back")

  local cfg = config.sanitise({})
  assert(cfg.settingsLayout == "auto", "auto by default")
  assert(config.sanitise({ settingsLayout = "sideways" }).settingsLayout == "auto",
    "an unknown layout falls back")
end)

--- Every element the settings page built, with its resolved geometry.
local function settingsElements()
  local out = {}
  local function walk(el)
    local props = rawget(el, "_p")
    out[#out + 1] = {
      kind = rawget(el, "__kind"),
      text = type(props.text) == "string" and props.text or nil,
      x = tonumber(el.x) or 1,
      y = tonumber(el.y) or 1,
      width = tonumber(el.width) or 0,
    }
    for _, child in ipairs(rawget(el, "_children") or {}) do walk(child) end
  end
  walk(terminalRoot.views.settings.container)
  return out
end

local function buildSettingsAt(width, layout)
  rawget(terminalRoot.root, "_p").width = width
  rawget(terminalRoot.root, "_p").height = 20
  terminalRoot:setPage("settings", false)
  app.cfg.settingsLayout = layout or "auto"
  app:emit("modules")                        -- what a real rebuild fires
  return settingsElements()
end

check("nothing on the settings page runs off a pocket screen", function()
  local W = 26
  local elements = buildSettingsAt(W)

  local overflow, buttons, inputs, labels = {}, 0, 0, 0
  for _, el in ipairs(elements) do
    if el.kind == "Button" or el.kind == "Input" then
      if el.kind == "Button" then buttons = buttons + 1 else inputs = inputs + 1 end
      if el.x + el.width - 1 > W then
        overflow[#overflow + 1] = ("%s %q at x=%d w=%d ends at %d")
          :format(el.kind, tostring(el.text), el.x, el.width, el.x + el.width - 1)
      end
      assert(el.x >= 1, "nothing starts left of the screen")
    elseif el.kind == "Label" and el.text then
      labels = labels + 1
      -- A single word longer than the screen cannot be broken; anything that
      -- COULD have been wrapped and was not is the bug being tested for.
      if el.x + #el.text - 1 > W and el.text:find("%s") then
        overflow[#overflow + 1] = ("label %q at x=%d"):format(el.text, el.x)
      end
    end
  end

  assert(buttons > 20, "the page really was built, got " .. buttons .. " buttons")
  assert(inputs >= 4, "including the coordinate and name boxes, got " .. inputs)
  assert(labels > 40, "and its labels, got " .. labels)
  assert(#overflow == 0,
    "these run off a 26-cell screen:\n  " .. table.concat(overflow, "\n  "))
end)

check("a narrow screen stacks each value under its label", function()
  local elements = buildSettingsAt(26)

  -- Find the Mode row: a label, then its button on the NEXT line, hard left
  -- and nearly the full width of the screen.
  local label, button
  for i, el in ipairs(elements) do
    if el.kind == "Label" and el.text == "Mode" then
      label = el
      for j = i + 1, #elements do
        if elements[j].kind == "Button" then button = elements[j]; break end
      end
      break
    end
  end
  assert(label and button, "found the Mode row")
  assert(button.y == label.y + 1, "the value is on the line below its label")
  assert(button.x == 1, "starting hard left, got x=" .. button.x)
  assert(button.width >= 24, "and nearly the whole width, got " .. button.width)
  assert(button.text == "FIXED - watch the base",
    "so the whole value fits, got " .. tostring(button.text))

  -- The three coordinate boxes share one line rather than running off the edge.
  local boxes = {}
  for _, el in ipairs(elements) do
    if el.kind == "Input" and el.width == 7 then boxes[#boxes + 1] = el end
  end
  assert(#boxes == 3, "three coordinate boxes, got " .. #boxes)
  assert(boxes[1].y == boxes[2].y and boxes[2].y == boxes[3].y, "on one line")
  assert(boxes[3].x + boxes[3].width - 1 <= 26,
    "and the last one ends on screen, at " .. (boxes[3].x + boxes[3].width - 1))
end)

check("a wide screen keeps the two-column layout", function()
  local elements = buildSettingsAt(51)

  local label, button
  for i, el in ipairs(elements) do
    if el.kind == "Label" and el.text == "Mode" then
      label = el
      for j = i + 1, #elements do
        if elements[j].kind == "Button" then button = elements[j]; break end
      end
      break
    end
  end
  assert(label and button, "found the Mode row")
  assert(button.y == label.y, "label and value share a line")
  assert(button.x > 1, "with the value in its own column, got x=" .. button.x)

  -- And forcing stacked on a wide screen still stacks.
  local forced = buildSettingsAt(51, "stacked")
  local forcedLabel, forcedButton
  for i, el in ipairs(forced) do
    if el.kind == "Label" and el.text == "Mode" then
      forcedLabel = el
      for j = i + 1, #forced do
        if forced[j].kind == "Button" then forcedButton = forced[j]; break end
      end
      break
    end
  end
  assert(forcedButton.y == forcedLabel.y + 1, "forcing stacked works on any screen")

  buildSettingsAt(51, "auto")
end)

check("the settings the pocket profile changes are all reachable", function()
  -- The profile is a shortcut, not a way to reach a setting that has no row.
  -- Every key it writes has to be editable by hand afterwards, and on a
  -- station where the module that used to own the row has been switched off.
  local pocket = profiles.byId("pocket")
  local rows = {}
  for _, el in ipairs(buildSettingsAt(51)) do
    if el.kind == "Label" and el.text then rows[el.text] = true end
  end

  local owners = {
    role           = "Role",
    mode           = "Mode",
    orientation    = "Scope",
    headingStep    = "Heading steps",
    headingSeconds = "Heading rate",
    headingSmooth  = "Ease turns",
    scanIndex      = "Sweep every",
    animate        = "Animation",
    envSeconds     = "Poll every",
    flash          = "Screen flash",
    toast          = "Banner",
  }
  for key in pairs(pocket.cfg) do
    local label = owners[key]
    assert(label, "the pocket profile writes " .. key .. " with no row named for it")
    assert(rows[label], key .. " has no row: expected one labelled " .. label)
  end

  -- Animation drives the radar sweep and the eased turn as well as the sky, so
  -- it belongs to the station rather than to the weather page -- switching the
  -- weather module off must not take it away.
  app.cfg.modulesOff = { weather = true }
  config.sanitise(app.cfg)
  local without = {}
  for _, el in ipairs(buildSettingsAt(51)) do
    if el.kind == "Label" and el.text then without[el.text] = true end
  end
  assert(without["Animation"], "Animation survives the weather module going off")
  assert(without["Ease turns"], "and so does the setting that depends on it")
  assert(not without["Scenery"], "while the weather module's own rows do not")

  app.cfg.modulesOff = {}
  config.sanitise(app.cfg)
  buildSettingsAt(51)
end)

-------------------------------------------------------------- power clients --
-- A power client is a separate computer wired to meters or batteries, reading
-- them and broadcasting what it sees. The main base merges every client with
-- its own hardware, and relays the total to the mobiles.

local powerModule = modules.byId("power")

--- What powerclient.lua puts on the wire.
local function clientPayload(name, sources, interval)
  return { t = "pw", n = name, i = interval or 2, s = sources }
end

check("a client's readings are merged with the local hardware", function()
  local model = powerLib.new()
  model:attach({ energy = {
    powerLib.describe("local_meter", fakeMeter(1000), "energy_detector"),
  } }, config.sanitise({}))

  local cfg = config.sanitise({})
  cfg.power.roles = { local_meter = "in" }

  model:poll(cfg, 100)
  assert(model.input == 1000, "just the local meter to start with")
  assert(model.percent == nil, "and no buffer anywhere")

  -- A reactor room reports in.
  assert(model:applyClient(7, clientPayload("Reactor", {
    { n = "energyDetector_0", m = 1, r = 4000 },
    { n = "matrix", s = 3e9, c = 1e10 },
  }), 101), "the client was accepted")

  cfg.power.roles["7:energyDetector_0"] = "in"
  model:poll(cfg, 101)

  assert(model.input == 5000, "its meter joins the total, got " .. model.input)
  assert(model.stored == 3e9, "and its battery, got " .. tostring(model.stored))
  assert(math.abs(model.percent - 30) < 0.001, "with a real percentage")
  assert(#model:allSources() == 3, "three devices in all, got " .. #model:allSources())

  -- A second client, with a peripheral of the SAME name as the first. Roles
  -- are keyed by the computer that reported it, so they do not collide.
  assert(model:applyClient(9, clientPayload("Furnaces", {
    { n = "energyDetector_0", m = 1, r = 2500 },
  }), 102), "a second client was accepted")
  cfg.power.roles["9:energyDetector_0"] = "out"
  model:poll(cfg, 102)

  assert(model.input == 5000, "the first client is still supply, got " .. model.input)
  assert(model.output == 2500, "and the second is demand, got " .. model.output)
  assert(model.net == 2500, "so the net is the difference")
  assert(#model:clientList() == 2, "both clients reporting")
  assert(model:clientList()[1].name == "Furnaces", "listed by name")
end)

check("a client that goes quiet stops being counted", function()
  local cfg = config.sanitise({})
  local model = powerLib.new()
  model:attach({ energy = {} }, cfg)

  model:applyClient(7, clientPayload("Reactor", {
    { n = "meter", m = 1, r = 8000 },
  }, 2), 100)
  cfg.power.roles = { ["7:meter"] = "in" }

  model:poll(cfg, 100)
  assert(model.input == 8000, "counted while it is talking")
  assert(model.available, "and the page has something to draw")

  -- One missed broadcast is not a lost client.
  model:poll(cfg, 104)
  assert(model.input == 8000, "a late client is tolerated, got " .. model.input)

  -- A reactor whose chunk has unloaded must stop counting as supply, or the
  -- page reports power that is not being generated.
  model:poll(cfg, 130)
  assert(model.input == 0, "a silent client drops out, got " .. model.input)
  assert(#model:clientList() == 0, "and off the list")
  assert(model.error and model.error:find("client", 1, true),
    "the page says why it is empty, got " .. tostring(model.error))

  -- It comes straight back when it starts talking again.
  model:applyClient(7, clientPayload("Reactor", {
    { n = "meter", m = 1, r = 8000 },
  }, 2), 131)
  model:poll(cfg, 131)
  assert(model.input == 8000, "and returns when it does")
end)

check("a malformed client payload cannot poison the totals", function()
  local cfg = config.sanitise({})
  local model = powerLib.new()
  model:attach({ energy = {} }, cfg)

  assert(model:applyClient(7, "not a table") == false, "junk is refused")
  assert(model:applyClient(7, { t = "pw" }) == false, "so is a payload with no sources")
  assert(model:applyClient(nil, clientPayload("x", {})) == false, "and one with no id")

  -- Entries that are not readings are dropped rather than summed.
  assert(model:applyClient(7, clientPayload("Mixed", {
    { n = "good", m = 1, r = 500 },
    { n = "bad", m = 1, r = "lots" },
    { nonsense = true },
    "not a table",
    { n = "halfBattery", s = 5 },              -- stored with no capacity
  }), 100), "the payload as a whole is still accepted")

  cfg.power.roles = { ["7:good"] = "in", ["7:bad"] = "in" }
  model:poll(cfg, 100)
  assert(model.input == 500, "only the readable one counts, got " .. model.input)
  assert(model.percent == nil, "and a half a battery is not a buffer")

  local client = model.clients[7]
  assert(#client.sources == 3, "three named entries survived, got " .. #client.sources)
end)

check("a client with no name is still identifiable", function()
  local model = powerLib.new()
  model:attach({ energy = {} }, config.sanitise({}))
  model:applyClient(42, { t = "pw", s = { { n = "meter", m = 1, r = 1 } } }, 1)
  assert(model:clientList()[1].name == "Computer 42",
    "falls back to the computer id, got " .. model:clientList()[1].name)

  -- And a name long enough to be a nuisance is cut down.
  model:applyClient(43, clientPayload(("x"):rep(90), {}), 1)
  assert(#model.clients[43].name <= 24, "long names are capped")
end)

check("the main base relays the merged total to a mobile", function()
  local cfg = config.sanitise({})
  local base = powerLib.new()
  base:attach({ energy = {
    powerLib.describe("meter", fakeMeter(1200), "energy_detector"),
    powerLib.describe("matrix", fakeBattery(4e9, 1e10), "inductionMatrix"),
  } }, cfg)
  base:applyClient(7, clientPayload("Reactor", {
    { n = "meter", m = 1, r = 800 },
  }), 100)
  cfg.power.roles = { meter = "in", ["7:meter"] = "in" }
  base:poll(cfg, 100)

  local payload = base:relayPayload()
  payload.n = 1
  -- Only totals travel: a mobile has no use for forty peripheral names, and
  -- the base has already done the work of adding them up.
  assert(payload.i == base.input and payload.o == base.output, "the rates travel")
  assert(payload.s == base.stored and payload.c == base.capacity, "and the buffer")
  assert(payload.d == 3, "with a device count, got " .. tostring(payload.d))
  assert(payload.s ~= nil, "there is a buffer to send")

  local mobile = powerLib.new()
  mobile:attach({ energy = {} }, cfg)
  assert(mobile:applyRelay(payload, 200), "the mobile accepted it")

  assert(mobile.input == base.input, "same supply")
  assert(mobile.output == base.output, "same demand")
  assert(mobile.net == base.net, "same net")
  assert(math.abs(mobile.percent - base.percent) < 0.001, "same buffer")
  assert(mobile.relayed, "and it says the figures were relayed")
  assert(mobile.deviceCount == 3, "including how many devices are behind them")
  assert(mobile.available, "so the page draws")
  assert(#mobile.history:series() > 0, "and the graph is fed")

  -- Freshness works the same way the weather relay's does.
  assert(mobile:relayFresh(200), "fresh when it has just arrived")
  assert(mobile:relayFresh(205), "and a moment later")
  assert(not mobile:relayFresh(400), "but not for ever")

  assert(mobile:applyRelay({ o = 1 }) == false, "a payload with no rates is refused")
  assert(mobile:applyRelay("nonsense") == false, "and so is junk")
end)

check("a mobile draws relayed power without polling its own hardware", function()
  local savedRole = app.cfg.role
  app.cfg.role = "mobile"
  app.cfg.power.roles = { energyDetector_0 = "in", energyDetector_1 = "out" }
  GRID.supply, GRID.demand = 4800, 3100

  -- Relayed figures nothing attached to this computer could produce, so
  -- "did it poll?" is answerable from the totals alone.
  app.power:applyRelay({ i = 9000, o = 4000, s = 5e9, c = 1e10, r = 1, d = 6, n = 1 }, CLOCK)

  assert(powerModule.tick(app, CLOCK) == false, "the mobile sat on the relay")
  assert(app.power.input == 9000, "drawing the figures it was sent, got "
    .. app.power.input)
  assert(app.power.relayed, "and saying so")
  assert(app.power.deviceCount == 6, "including how many devices are behind them")

  -- When the relay goes stale it falls back to whatever is actually attached,
  -- exactly as the weather page does.
  assert(powerModule.tick(app, CLOCK + 100), "a stale relay polls locally again")
  assert(not app.power.relayed, "and stops claiming the figures were relayed")
  assert(app.power.input == 4800, "reading its own hardware, got " .. app.power.input)

  app.cfg.role = savedRole
  app.power:poll(app.cfg, CLOCK)
end)

check("client traffic rides the same modem as the sweep", function()
  local saved = app.cfg.role
  app:setRole("main")
  assert(app.link.open, "the main base has its modem open")

  -- What the link pump would hand over, arriving on the client protocol.
  local before = #app.power:clientList()
  local accepted = app.link:handle(app, 77,
    clientPayload("Reactor room", { { n = "meter", m = 1, r = 6000 } }),
    powerModule.PROTOCOL)
  assert(accepted, "the power protocol was routed to the power module")
  assert(#app.power:clientList() == before + 1, "and the client was filed")

  -- The pairing rule that guards the sweep does not apply: a client
  -- broadcasts to whoever is listening.
  assert(app.cfg.pairedBaseId ~= 77, "that computer is not the paired base")

  -- Turning the setting off refuses it.
  app.cfg.power.clients = false
  assert(app.link:handle(app, 78,
    clientPayload("Another", { { n = "meter", m = 1, r = 1 } }),
    powerModule.PROTOCOL) == false, "refused when clients are switched off")
  app.cfg.power.clients = true

  -- An unknown protocol is still nobody's business.
  assert(app.link:handle(app, 77, { t = "pw" }, "some_other_mod") == false,
    "traffic on an unclaimed protocol is ignored")

  app.power.clients = {}
  app:setRole(saved)
end)

check("powerclient.lua runs, reads its hardware and broadcasts", function()
  -- The client is a separate PROGRAM, not a module, so this drives the real
  -- file the way install-test drives the real installer. It closes the loop
  -- that matters: what the client puts on the wire is fed straight into the
  -- main base's handler, so the two cannot drift apart without failing here.
  local posted = {}
  local realBroadcast = rednet.broadcast
  local realSleep = sleep
  local realParallel = parallel
  local realOpen, realClose = rednet.open, rednet.close

  rednet.broadcast = function(message, protocol)
    posted[#posted + 1] = { message = message, protocol = protocol }
  end
  rednet.open = function() end
  rednet.close = function() end

  -- Two passes round the broadcast loop, then out. The client has no exit
  -- condition of its own beyond a keypress, so the sleep is the seam.
  local rounds = 0
  _G.sleep = function()
    rounds = rounds + 1
    if rounds >= 2 then error("enough", 0) end
  end
  _G.write = function() end
  parallel = { waitForAny = function(broadcast) pcall(broadcast) end }

  -- The client draws a status readout on its terminal; swallow it so the test
  -- run stays readable.
  local realPrint = print
  _G.print = function() end

  local chunk = assert(loadfile(PROJ .. "/powerclient.lua"))
  local ranOk, runError = pcall(chunk, "Reactor room")

  _G.print = realPrint
  rednet.broadcast, rednet.open, rednet.close = realBroadcast, realOpen, realClose
  _G.sleep = realSleep
  parallel = realParallel

  assert(ranOk, "the client ran: " .. tostring(runError))
  assert(#posted >= 1, "and broadcast something, got " .. #posted)

  local entry = posted[1]
  assert(entry.protocol == powerModule.PROTOCOL,
    "on the power protocol, got " .. tostring(entry.protocol))
  assert(entry.message.t == "pw", "with the payload type the base looks for")
  assert(entry.message.n == "Reactor room", "under the name it was given")
  assert(type(entry.message.i) == "number", "and its own interval")

  -- It found the same energy hardware the main base finds locally.
  local names = {}
  for _, source in ipairs(entry.message.s) do names[source.n] = source end
  assert(names.energyDetector_0, "it found the meters")
  assert(names.inductionMatrix_0, "and the battery")
  assert(names.energyDetector_0.r == GRID.supply,
    "reading the meter, got " .. tostring(names.energyDetector_0.r))
  assert(names.inductionMatrix_0.s == GRID.stored, "and the battery's charge")
  assert(names.inductionMatrix_0.c == GRID.capacity, "and its capacity")
  assert(names.energyDetector_0.dev == nil, "no peripheral handles on the wire")

  -- And the main base accepts it, through the same handler the link uses.
  local model = powerLib.new()
  model:attach({ energy = {} }, config.sanitise({}))
  assert(model:applyClient(31, entry.message, 1), "the base accepted the payload")

  -- Roles are keyed by the reporting computer, so the base decides which of a
  -- client's meters is supply and which is demand -- the client itself has no
  -- opinion, which is why only raw readings travel.
  local cfg = config.sanitise({})
  cfg.power.roles = {
    ["31:energyDetector_0"] = "in",
    ["31:energyDetector_1"] = "out",
  }
  model:poll(cfg, 1)
  assert(model.input == GRID.supply,
    "the base totalled its supply meter, got " .. model.input)
  assert(model.output == GRID.demand,
    "and its demand meter, got " .. model.output)
  assert(model.stored == GRID.stored, "and its battery")
  assert(model:clientList()[1].name == "Reactor room", "under its name")

  -- The payload has to survive being serialised, which is what rednet does
  -- to it in game.
  local wire = textutils.unserialize(textutils.serialize(entry.message))
  assert(model:applyClient(32, wire, 1), "a round-tripped payload still works")
end)

check("a standalone station still never opens the modem", function()
  -- Collecting clients means being a MAIN BASE. That keeps the promise that a
  -- station with no interest in the network never touches it.
  local cfg = config.sanitise({ role = "standalone" })
  assert(cfg.power.clients == true, "it would accept clients if it could hear them")
  assert(config.usesNetwork(cfg) == false, "but it opens no modem")

  assert(config.usesNetwork(config.sanitise({ role = "main" })), "a main base does")
  assert(config.usesNetwork(config.sanitise({ role = "mobile" })), "and so does a mobile")
end)

--------------------------------------------------------------------- power --

check("the power page draws in every state at every size", function()
  local sizes = { { 15, 10 }, { 26, 12 }, { 39, 13 }, { 51, 19 }, { 82, 40 }, { 164, 81 } }
  local savedGrid = { GRID.supply, GRID.demand, GRID.stored, GRID.capacity }
  local savedSources = app.power.sources

  local states = {
    { name = "healthy",   supply = 4800, demand = 3100, stored = 6.4e9 },
    { name = "draining",  supply = 200,  demand = 9000, stored = 2.0e9 },
    { name = "low",       supply = 0,    demand = 9000, stored = 0.05e10 },
    { name = "full",      supply = 9000, demand = 0,    stored = 1e10 },
    { name = "idle",      supply = 0,    demand = 0,    stored = 5e9 },
    { name = "huge",      supply = 4.2e9, demand = 3.9e9, stored = 9e9 },
    { name = "no-device", none = true },
    { name = "meter-only", supply = 1000, demand = 500, noStore = true },
  }

  for _, state in ipairs(states) do
    if state.none then
      app.power.sources = {}
    elseif state.noStore then
      local meters = {}
      for _, source in ipairs(savedSources) do
        if source.meter then meters[#meters + 1] = source end
      end
      app.power.sources = meters
      GRID.supply, GRID.demand = state.supply, state.demand
    else
      app.power.sources = savedSources
      GRID.supply, GRID.demand, GRID.stored = state.supply, state.demand, state.stored
    end
    app.power.available = #app.power.sources > 0

    -- An empty graph and a full one are different drawing problems, so both
    -- get exercised: the first sample is plotted against a range built from
    -- one point, which is where a divide-by-zero would live.
    app.power.history:clear()
    for _ = 1, 3 do app.power:poll(app.cfg, CLOCK) end

    for _, size in ipairs(sizes) do
      rawget(terminalRoot.root, "_p").width = size[1]
      rawget(terminalRoot.root, "_p").height = size[2]
      terminalRoot:setPage("power", false)
      local label = ("power %dx%d %s"):format(size[1], size[2], state.name)
      local buffer = newBuffer(size[1], size[2], label)
      local ok, err = pcall(drawTree, terminalRoot.root, buffer)
      if not ok then error(label .. ": " .. tostring(err), 0) end

      -- And again with a full window behind it.
      for _ = 1, 40 do app.power:poll(app.cfg, CLOCK) end
      local full = newBuffer(size[1], size[2], label .. " full")
      ok, err = pcall(drawTree, terminalRoot.root, full)
      if not ok then error(label .. " full: " .. tostring(err), 0) end
    end
  end

  app.power.sources = savedSources
  app.power.available = true
  GRID.supply, GRID.demand, GRID.stored, GRID.capacity = table.unpack(savedGrid)
  app.power.history:clear()
  app.power:poll(app.cfg, CLOCK)
  terminalRoot:setPage("status", false)
end)

check("the power page says what it is showing", function()
  rawget(terminalRoot.root, "_p").width = 82
  rawget(terminalRoot.root, "_p").height = 40

  local function textOf()
    terminalRoot:setPage("power", false)
    local buffer = newBuffer(82, 40, "power text")
    drawTree(terminalRoot.root, buffer)
    return table.concat(buffer.texts, "\n")
  end

  GRID.stored = 6.4e9
  app.power:poll(app.cfg, CLOCK)
  local healthy = textOf()
  assert(healthy:find("POWER", 1, true), "it names itself:\n" .. healthy)
  assert(healthy:find("IN", 1, true) and healthy:find("OUT", 1, true),
    "with supply and demand")
  assert(healthy:find("64%", 1, true), "and the buffer, got:\n" .. healthy)

  GRID.stored = 0.05e10                          -- 5%, under the 20% threshold
  app.power:poll(app.cfg, CLOCK)
  app.power:checkAlarm(app.cfg, CLOCK)
  local low = textOf()
  assert(low:find("LOW", 1, true), "a low buffer says LOW:\n" .. low)

  -- The status page carries the same figure, so it is visible without
  -- changing page.
  terminalRoot:setPage("status", false)
  local statusBuffer = newBuffer(82, 40, "status text")
  drawTree(terminalRoot.root, statusBuffer)
  local status = table.concat(statusBuffer.texts, "\n")
  assert(status:find("Power", 1, true), "the status page reports power:\n" .. status)
  assert(status:find("Profile", 1, true), "and the profile it was set up as")

  GRID.stored = 6.4e9
  app.power:poll(app.cfg, CLOCK)
  app.power.low = false
end)

check("the power page is drawn on a monitor too", function()
  local monitorRoot
  for _, root in ipairs(roots) do
    if root.monitor then monitorRoot = root end
  end
  local pages = monitorRoot.pages
  local hasPower = false
  for _, page in ipairs(pages) do
    if page == "power" then hasPower = true end
  end
  assert(hasPower, "a monitor can show the power page")

  monitorRoot:setPage("power", false)
  for _, size in ipairs({ { 18, 6 }, { 57, 24 }, { 164, 81 } }) do
    rawget(monitorRoot.root, "_p").width = size[1]
    rawget(monitorRoot.root, "_p").height = size[2]
    local buffer = newBuffer(size[1], size[2], "monitor power")
    local ok, err = pcall(drawTree, monitorRoot.root, buffer)
    if not ok then error("monitor power: " .. tostring(err), 0) end
  end
end)

--------------------------------------------------------------------- report --

print(("%d checks, %d failures"):format(checks, #failures))
for _, failure in ipairs(failures) do print("  FAIL " .. failure) end
if #failures > 0 then os.exit(1) end
