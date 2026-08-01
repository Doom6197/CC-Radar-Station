-- Renders what CC will actually display: the pixel grid is compiled to
-- teletext cells exactly as in game, then each cell is expanded back into its
-- 2x3 sub-pixels using the two colours that survived. Output is a BMP.

local PROJ, OUT = ...
package.path = PROJ .. "/?.lua;" .. package.path

colors = {}
local names = { "white","orange","magenta","lightBlue","yellow","lime","pink",
  "gray","lightGray","cyan","purple","blue","brown","green","red","black" }
for i, n in ipairs(names) do colors[n] = 2 ^ (i - 1) end

-- basalt.rgb hands back the hex string itself, so the preview can read real
-- colours straight out of the palette tones.
package.loaded.basalt = { rgb = function(hex) return hex end }

local pixel  = require("radar.pixel")
local theme  = require("radar.theme")
local glyphs = require("radar.glyphs")
local sky    = require("radar.sky")
local util   = require("radar.util")
local biomes = require("radar.biomes")
local environment = require("radar.environment")

local function hexToRGB(hex)
  local n = tonumber(hex:sub(2), 16)
  return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

------------------------------------------------------------------- capture --

local Capture = {}
Capture.__index = Capture
local function newCapture() return setmetatable({ rows = {} }, Capture) end
function Capture:colorBlit(x, y, str, fgs, bgs)
  local row = { x = x, str = str, fg = {}, bg = {} }
  for i = 1, #str do row.fg[i], row.bg[i] = fgs[i], bgs[i] end
  self.rows[y] = row
end
function Capture:fill() end
function Capture:blit() end

--- Expands captured cells back into sub-pixels: [y][x] = "#RRGGBB".
local function expand(capture, cellW, cellH)
  local out = {}
  for py = 1, cellH * 3 do out[py] = {} end
  for cy = 1, cellH do
    local row = capture.rows[cy]
    if row then
      for cx = 1, cellW do
        local ch = row.str:sub(cx, cx)
        local fg, bg = row.fg[cx], row.bg[cx]
        local bits = { false, false, false, false, false, false }
        if ch ~= " " then
          local mask = ch:byte() - 128
          for i = 1, 5 do bits[i] = math.floor(mask / 2 ^ (i - 1)) % 2 == 1 end
        end
        for i = 1, 6 do
          local sx = (cx - 1) * 2 + ((i - 1) % 2) + 1
          local sy = (cy - 1) * 3 + math.floor((i - 1) / 2) + 1
          out[sy][sx] = bits[i] and fg or bg
        end
      end
    end
  end
  return out
end

----------------------------------------------------------------------- BMP --

local function writeBMP(path, width, height, pixels, scale)
  scale = scale or 1
  local w, h = width * scale, height * scale
  local rowBytes = w * 3
  local pad = (4 - rowBytes % 4) % 4
  local size = 54 + (rowBytes + pad) * h

  local function u32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
      math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end

  local parts = { "BM", u32(size), u32(0), u32(54),
    u32(40), u32(w), u32(h), u16(1), u16(24), u32(0), u32(0),
    u32(2835), u32(2835), u32(0), u32(0) }

  local padding = string.rep("\0", pad)
  for y = h, 1, -1 do                       -- BMP rows run bottom-up
    local sourceY = math.floor((y - 1) / scale) + 1
    local line = {}
    for x = 1, w do
      local sourceX = math.floor((x - 1) / scale) + 1
      local hex = (pixels[sourceY] or {})[sourceX] or "#ff00ff"
      local r, g, b = hexToRGB(hex)
      line[x] = string.char(b, g, r)        -- BMP is BGR
    end
    parts[#parts + 1] = table.concat(line) .. padding
  end

  local file = assert(io.open(path, "wb"))
  file:write(table.concat(parts))
  file:close()
end

--------------------------------------------------------------------- sheet --

local TILE_W, TILE_H = 42, 15              -- cells per tile
local COLS = 3

--- Renders one tile and returns its expanded sub-pixel block.
local function renderTile(paint)
  local grid = pixel.new(TILE_W, TILE_H, theme.skies.day)
  paint(grid)
  local capture = newCapture()
  grid:blitTo(capture, 1, 1)
  return expand(capture, TILE_W, TILE_H)
end

local function sheet(path, tiles, scale)
  local rows = math.ceil(#tiles / COLS)
  local tw, th = TILE_W * 2, TILE_H * 3
  local gap = 2
  local width = COLS * (tw + gap) + gap
  local height = rows * (th + gap) + gap
  local canvas = {}
  for y = 1, height do
    canvas[y] = {}
    for x = 1, width do canvas[y][x] = "#000000" end
  end

  for index, tile in ipairs(tiles) do
    local col = (index - 1) % COLS
    local row = math.floor((index - 1) / COLS)
    local ox = gap + col * (tw + gap)
    local oy = gap + row * (th + gap)
    local block = renderTile(tile)
    for y = 1, th do
      for x = 1, tw do
        canvas[oy + y][ox + x] = (block[y] or {})[x] or "#ff00ff"
      end
    end
  end

  writeBMP(path, width, height, canvas, scale or 3)
  print(("wrote %s  (%d tiles, %dx%d cells each)"):format(path, #tiles, TILE_W, TILE_H))
end

--------------------------------------------------------------------- scenes --

local function sceneAt(tick, raining, thundering, biome, dimension, moon, ground)
  local snap = {
    tick = tick, day = 142,
    kind = environment.dimensionKind(dimension or "minecraft:overworld"),
    phase = environment.phaseOf(tick),
    raining = raining, thundering = thundering,
    biome = biome or "minecraft:plains",
    moonId = moon or 0,
    moonName = "Full Moon",
  }
  snap.body, snap.bodyProgress = environment.celestial(tick)
  return environment.describe(snap, ground), snap
end

local function skyTile(tick, raining, thundering, biome, dimension, moon, anim, clock, ground)
  return function(grid)
    local scene, snap = sceneAt(tick, raining, thundering, biome, dimension, moon, ground)
    grid:setPalette(scene.palette)
    sky.paint(grid, scene, anim or 6.2)
    if clock then
      local text = environment.clockOf(snap.tick)
      glyphs.drawShadowed(grid, 3, 3, text, 4, 9, 2)
    end
  end
end

sheet(OUT .. "/sky-scenes.bmp", {
  skyTile(23400, false, false),                       -- sunrise
  skyTile(2000,  false, false),                       -- morning
  skyTile(6000,  false, false, nil, nil, nil, 6.2, true), -- noon, with clock
  skyTile(11800, false, false),                       -- sunset
  skyTile(14500, false, false, nil, nil, 0),          -- night, full moon
  skyTile(18000, false, false, nil, nil, 6),          -- midnight, first quarter
  skyTile(5000,  true,  false),                       -- rain, day
  skyTile(17000, true,  false),                       -- rain, night
  skyTile(5000,  true,  true),                        -- thunderstorm
  skyTile(5000,  true,  false, "minecraft:snowy_taiga"),      -- snow, day
  skyTile(17000, true,  false, "minecraft:snowy_slopes"),     -- snow, night
  skyTile(6000,  false, false, nil, "minecraft:the_nether"),  -- nether
})

-- Find an animation time on which the lightning hash actually fires.
local strikeAnim = 0
for slot = 0, 400 do
  if util.hash01(slot, 907) >= 0.86 then strikeAnim = slot / 1.6 + 0.1 break end
end
print("lightning strikes at anim = " .. strikeAnim)

sheet(OUT .. "/sky-detail.bmp", {
  skyTile(6000, false, false, nil, "minecraft:the_end"),
  skyTile(5000, true, true, nil, nil, nil, strikeAnim),  -- storm, mid-strike
  skyTile(12300, false, false),                        -- last light
  -- every moon phase, at the same hour
  skyTile(18000, false, false, nil, nil, 0),
  skyTile(18000, false, false, nil, nil, 2),
  skyTile(18000, false, false, nil, nil, 4),
  skyTile(18000, false, false, nil, nil, 5),
  skyTile(18000, false, false, nil, nil, 6),
  skyTile(18000, false, false, nil, nil, 7),
}, 3)

--------------------------------------------------------------- the biomes --
-- Every ground profile at the same hour, so the sheets compare terrain and
-- flora rather than lighting. The nether and end profiles are rendered in
-- their own dimensions, since that is the only place they are ever drawn.

do
  local overworld, elsewhere = {}, {}
  local names = {}
  for _, kind in ipairs(biomes.ids()) do
    local profile = biomes.PROFILES[kind]
    local dim = "minecraft:overworld"
    if profile.terrain == "nether" then dim = "minecraft:the_nether"
    elseif profile.terrain == "end" then dim = "minecraft:the_end" end

    local tile = skyTile(6000, false, false, nil, dim, 0, 8.4, false, kind)
    if dim == "minecraft:overworld" then
      overworld[#overworld + 1] = tile
      names[#names + 1] = profile.label
    else
      elsewhere[#elsewhere + 1] = tile
    end
  end
  sheet(OUT .. "/biomes.bmp", overworld, 2)
  sheet(OUT .. "/biomes-dimensions.bmp", elsewhere, 3)
  print("biome scenes: " .. table.concat(names, ", "))
end

-- The same biome round the clock and through the weather, to check that the
-- ground picks up the light rather than staying stuck at midday.
sheet(OUT .. "/biome-moods.bmp", {
  skyTile(23400, false, false, nil, nil, 0, 8.4, false, "forest"),   -- dawn
  skyTile(6000,  false, false, nil, nil, 0, 8.4, false, "forest"),   -- noon
  skyTile(12200, false, false, nil, nil, 0, 8.4, false, "forest"),   -- dusk
  skyTile(18000, false, false, nil, nil, 0, 8.4, false, "forest"),   -- night
  skyTile(6000,  true,  false, nil, nil, 0, 8.4, false, "forest"),   -- rain
  skyTile(6000,  true,  true,  nil, nil, 0, 8.4, false, "forest"),   -- storm
  skyTile(6000,  true,  false, nil, nil, 0, 8.4, false, "snowyForest"),
  skyTile(18000, true,  false, nil, nil, 0, 8.4, false, "snowyForest"),
  skyTile(6000,  false, false, nil, nil, 0, 8.4, false, "void"),
}, 3)

------------------------------------------------------------ moon close-up --
-- Big discs, so the terminator geometry can actually be judged.
do
  local names = { [0]="full", "waning gibbous", "last quarter", "waning crescent",
    "new", "waxing crescent", "first quarter", "waxing gibbous" }
  local tiles = {}
  for phase = 0, 7 do
    tiles[#tiles + 1] = function(grid)
      grid:setPalette(theme.skies.night)
      grid:clear(1)
      local scene = {
        kind = "overworld", phase = "night", weather = "clear",
        palette = theme.skies.night, body = "moon", bodyProgress = 0.5,
        moonPhase = phase, night = true,
      }
      sky.paint(grid, scene, 0)
    end
    print(("phase %d = %s"):format(phase, names[phase]))
  end
  sheet(OUT .. "/moon-phases.bmp", tiles, 4)
end

---------------------------------------------------------------------- radar --

local RADAR_PALETTE = {
  theme.tones.bg, theme.tones.line, theme.tones.panel, theme.tones.accent,
  theme.tones.alarm, theme.tones.warn, theme.tones.dim, theme.tones.good,
  theme.tones.text,
}

local function radarTile(anim, contacts, rotation)
  return function(grid)
    grid:setPalette(RADAR_PALETTE)
    grid:clear(1)
    local w, h = grid.w, grid.h
    local cx, cy = w / 2, h / 2
    local radius = math.max(3, math.min(w / 2 - 2, h / 2 - 4))
    for _, fraction in ipairs({ 0.34, 0.67, 1.0 }) do
      grid:dashedRing(cx, cy, radius * fraction, 2, 4, 3)
    end
    for i = -radius, radius, 3 do
      grid:set(cx + i, cy, 2); grid:set(cx, cy + i, 2)
    end
    local lead = (anim * 72) % 360
    for back = 1, 7 do
      local a = math.rad(lead - back * 7 - 90)
      grid:line(cx, cy, cx + math.cos(a) * radius, cy + math.sin(a) * radius, 3)
    end
    local a = math.rad(lead - 90)
    grid:line(cx, cy, cx + math.cos(a) * radius, cy + math.sin(a) * radius, 4)
    grid:hline(cx - 2, cx + 2, cy, 9)
    grid:vline(cx, cy - 2, cy + 2, 9)
    for i = #contacts, 1, -1 do
      local contact = contacts[i]
      local rx, rz = util.rotateXZ(contact[1], contact[2], rotation or 0)
      local scale = radius / 320
      local px, py = cx + rx * scale, cy + rz * scale
      grid:disc(px, py, 1.2, contact[3])
      if i == 1 then grid:ring(px, py, 3, contact[3]) end
    end
  end
end

local contacts = {
  { 40, -60, 5 }, { -180, 120, 6 }, { 260, 240, 4 }, { -300, -40, 7 }, { 90, 300, 8 },
}
sheet(OUT .. "/radar-scope.bmp", {
  radarTile(0, contacts),
  radarTile(1.4, contacts),
  radarTile(2.8, contacts),
  radarTile(0, contacts, 90),
  radarTile(0, {}),
  radarTile(4.2, contacts, 225),
}, 3)
