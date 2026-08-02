-- Renders what CC will actually display: the pixel grid is compiled to
-- teletext cells exactly as in game, then each cell is expanded back into its
-- 2x3 sub-pixels using the two colours that survived. Output is a PNG, which
-- is what the README embeds, so there is no conversion step in between.
--
--   lua preview/render-preview.lua . preview

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

----------------------------------------------------------------------- PNG --
-- The README embeds PNGs, so the renderer writes them directly rather than
-- leaving a manual conversion step between "run the tool" and "commit the
-- picture". Everything a PNG needs -- CRC32, Adler32 and a deflate encoder --
-- is below, because the one useful property of this script is that it depends
-- on nothing but the drawing code it is there to exercise. None of it is in a
-- hot path: it runs once, on a desktop, to produce nine files.

--- 32-bit exclusive or, across every Lua a desktop might have. 5.3+ has the
--- operator (compiled through load, so 5.1 does not choke parsing it), 5.2 has
--- bit32, and 5.1 gets the arithmetic long way round.
local bxor
do
  if type(bit32) == "table" and bit32.bxor then
    bxor = bit32.bxor
  else
    local built = load("return function(a, b) return (a ~ b) & 0xFFFFFFFF end")
    if built then
      local fn = built()
      if fn and fn(5, 3) == 6 then bxor = fn end
    end
  end
  if not bxor then
    bxor = function(a, b)
      local result, place = 0, 1
      for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if x ~= y then result = result + place end
        a, b, place = (a - x) / 2, (b - y) / 2, place * 2
      end
      return result
    end
  end
end

local CRC_TABLE
local function crc32(bytes)
  if not CRC_TABLE then
    CRC_TABLE = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if c % 2 == 1 then c = bxor(0xEDB88320, math.floor(c / 2))
        else c = math.floor(c / 2) end
      end
      CRC_TABLE[i] = c
    end
  end
  local crc = 0xFFFFFFFF
  -- Byte at a time through a chunked unpack: string.byte over a range is far
  -- cheaper than one call per character on an image-sized string.
  for start = 1, #bytes, 4096 do
    local stop = math.min(start + 4095, #bytes)
    for offset = start, stop do
      crc = bxor(CRC_TABLE[bxor(crc % 256, bytes:byte(offset))], math.floor(crc / 256))
    end
  end
  return bxor(crc, 0xFFFFFFFF)
end

local function adler32(bytes)
  local a, b = 1, 0
  for i = 1, #bytes do
    a = (a + bytes:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local function be32(v)
  return string.char(
    math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
    math.floor(v / 256) % 256, v % 256)
end

local function chunk(kind, data)
  return be32(#data) .. kind .. data .. be32(crc32(kind .. data))
end

------------------------------------------------------------------- deflate --
-- One fixed-Huffman block with greedy LZ77 matching (RFC 1951). Not the best
-- compressor in the world, but these sheets are flat colour scaled up threefold
-- -- every run is at least three bytes long and every third scanline is
-- identical to the one above it -- so it lands within a few percent of what a
-- real encoder manages, and turns a 2 MB file into a 40 KB one.

-- Bases and extra-bit counts for the length and distance alphabets.
local LEN_BASE = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,
                   67,83,99,115,131,163,195,227,258 }
local LEN_EXTRA = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0 }
local DIST_BASE = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,
                    1025,1537,2049,3073,4097,6145,8193,12289,16385,24577 }
local DIST_EXTRA = { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 }

-- Which length code covers each match length, so the encoder never searches.
local LEN_INDEX = {}
for index = 1, #LEN_BASE do
  local last = (index < #LEN_BASE) and (LEN_BASE[index + 1] - 1) or 258
  for length = LEN_BASE[index], last do LEN_INDEX[length] = index end
end

local WINDOW = 32768
local MIN_MATCH, MAX_MATCH = 3, 258
-- How many earlier positions with the same three-byte prefix to try. Flat
-- artwork finds its match almost immediately, so a short chain costs nothing.
local MAX_CHAIN = 32

local function deflate(data)
  local n = #data

  -- One number per byte. string.byte over a range beats a call per character,
  -- and the range has to be chunked or it overflows the C stack.
  local bytes = {}
  for start = 1, n, 4096 do
    local stop = math.min(start + 4095, n)
    local block = { data:byte(start, stop) }
    for k = 1, #block do bytes[start + k - 1] = block[k] end
  end

  local out, cursor = {}, 0
  local bitBuffer, bitCount = 0, 0

  --- Deflate packs bits into bytes least-significant first.
  local function writeBits(value, count)
    bitBuffer = bitBuffer + value * 2 ^ bitCount
    bitCount = bitCount + count
    while bitCount >= 8 do
      cursor = cursor + 1
      out[cursor] = string.char(bitBuffer % 256)
      bitBuffer = math.floor(bitBuffer / 256)
      bitCount = bitCount - 8
    end
  end

  --- Huffman codes are the other way round -- most-significant bit first --
  --- so they go in reversed and the bit writer puts them back the right way.
  local function writeCode(code, count)
    local reversed = 0
    for _ = 1, count do
      reversed = reversed * 2 + code % 2
      code = math.floor(code / 2)
    end
    writeBits(reversed, count)
  end

  -- The fixed literal/length alphabet of RFC 1951 section 3.2.6.
  local function emitLiteral(byte)
    if byte <= 143 then writeCode(0x30 + byte, 8)
    else writeCode(0x190 + byte - 144, 9) end
  end

  local function emitLengthCode(code)
    if code <= 279 then writeCode(code - 256, 7)
    else writeCode(0xC0 + code - 280, 8) end
  end

  writeBits(1, 1)                            -- BFINAL: this is the only block
  writeBits(1, 2)                            -- BTYPE 01: fixed Huffman

  local head, prev = {}, {}
  local position = 1

  while position <= n do
    local bestLength, bestDistance = 0, 0

    if position + MIN_MATCH - 1 <= n then
      local key = (bytes[position] * 7919 + bytes[position + 1] * 271
                   + bytes[position + 2]) % WINDOW
      local candidate = head[key]
      local limit = math.min(MAX_MATCH, n - position + 1)
      local tried = 0

      while candidate and position - candidate <= WINDOW and tried < MAX_CHAIN do
        local length = 0
        while length < limit
              and bytes[candidate + length] == bytes[position + length] do
          length = length + 1
        end
        if length > bestLength then
          bestLength, bestDistance = length, position - candidate
          if length >= limit then break end
        end
        candidate = prev[candidate]
        tried = tried + 1
      end

      prev[position] = head[key]
      head[key] = position
    end

    if bestLength >= MIN_MATCH then
      local lengthIndex = LEN_INDEX[bestLength]
      emitLengthCode(256 + lengthIndex)
      if LEN_EXTRA[lengthIndex] > 0 then
        writeBits(bestLength - LEN_BASE[lengthIndex], LEN_EXTRA[lengthIndex])
      end

      local distanceIndex = #DIST_BASE
      while distanceIndex > 1 and DIST_BASE[distanceIndex] > bestDistance do
        distanceIndex = distanceIndex - 1
      end
      writeCode(distanceIndex - 1, 5)
      if DIST_EXTRA[distanceIndex] > 0 then
        writeBits(bestDistance - DIST_BASE[distanceIndex], DIST_EXTRA[distanceIndex])
      end

      -- Everything the match swallowed still has to be indexed, or the next
      -- search cannot see back past it.
      for skipped = position + 1, position + bestLength - 1 do
        if skipped + MIN_MATCH - 1 <= n then
          local key = (bytes[skipped] * 7919 + bytes[skipped + 1] * 271
                       + bytes[skipped + 2]) % WINDOW
          prev[skipped] = head[key]
          head[key] = skipped
        end
      end
      position = position + bestLength
    else
      emitLiteral(bytes[position])
      position = position + 1
    end
  end

  emitLengthCode(256)                        -- end of block
  if bitCount > 0 then
    cursor = cursor + 1
    out[cursor] = string.char(bitBuffer % 256)
  end

  return "\120\001" .. table.concat(out) .. be32(adler32(data))
end

local function writePNG(path, width, height, pixels, scale)
  scale = scale or 1
  local w, h = width * scale, height * scale

  -- Filter type 2 (Up) subtracts the row above. Scaling threefold means two
  -- rows in every three are identical to their predecessor and filter to a
  -- run of zeroes, which is the single biggest win available here.
  local raw, previous = {}, nil
  for y = 1, h do
    local sourceY = math.floor((y - 1) / scale) + 1
    local row = {}
    for x = 1, w do
      local sourceX = math.floor((x - 1) / scale) + 1
      local hex = (pixels[sourceY] or {})[sourceX] or "#ff00ff"
      local r, g, b = hexToRGB(hex)
      local at = (x - 1) * 3
      row[at + 1], row[at + 2], row[at + 3] = r, g, b
    end

    local line = {}
    if previous then
      line[1] = "\2"
      for i = 1, #row do line[i + 1] = string.char((row[i] - previous[i]) % 256) end
    else
      line[1] = "\0"
      for i = 1, #row do line[i + 1] = string.char(row[i]) end
    end
    raw[y] = table.concat(line)
    previous = row
  end

  local header = be32(w) .. be32(h) .. string.char(8, 2, 0, 0, 0)
  local file = assert(io.open(path, "wb"))
  file:write("\137PNG\13\10\26\10")
  file:write(chunk("IHDR", header))
  file:write(chunk("IDAT", deflate(table.concat(raw))))
  file:write(chunk("IEND", ""))
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

local function sheet(path, tiles, scale, columns)
  local cols = columns or COLS
  local rows = math.ceil(#tiles / cols)
  local tw, th = TILE_W * 2, TILE_H * 3
  local gap = 2
  local width = cols * (tw + gap) + gap
  local height = rows * (th + gap) + gap
  local canvas = {}
  for y = 1, height do
    canvas[y] = {}
    for x = 1, width do canvas[y][x] = "#000000" end
  end

  for index, tile in ipairs(tiles) do
    local col = (index - 1) % cols
    local row = math.floor((index - 1) / cols)
    local ox = gap + col * (tw + gap)
    local oy = gap + row * (th + gap)
    local block = renderTile(tile)
    for y = 1, th do
      for x = 1, tw do
        canvas[oy + y][ox + x] = (block[y] or {})[x] or "#ff00ff"
      end
    end
  end

  local target = path:gsub("%.bmp$", ".png")
  writePNG(target, width, height, canvas, scale or 3)
  print(("wrote %s  (%d tiles, %dx%d cells each)"):format(target, #tiles, TILE_W, TILE_H))
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

------------------------------------------------------------------ backdrops --
-- Every picture the weather page can be told to draw instead of the live sky,
-- in the order the settings picker offers them.

local backdrops = require("radar.backdrops")

local function backdropTile(id, anim)
  return function(grid)
    local scene = backdrops.scene(id, nil)
    grid:setPalette(scene.palette)
    sky.paint(grid, scene, anim or 6.2)
  end
end

local backdropTiles = {}
for i, id in ipairs(backdrops.ids()) do
  backdropTiles[i] = backdropTile(id, 6.2 + i * 1.7)
end
sheet(OUT .. "/backdrops.bmp", backdropTiles, 3)

-- The same picture with its sky set to live: one place, the real hour and the
-- real weather. Whether it rains or snows comes from the biome, not the
-- picture, which is why the airship snows over a taiga and stays dry over sand.
local function liveTile(id, tick, raining, thundering, biome, anim)
  return function(grid)
    local snap = {
      available = true, tick = tick, day = 142, kind = "overworld",
      phase = environment.phaseOf(tick), raining = raining,
      thundering = thundering, biome = biome or "minecraft:plains",
      moonId = 6, moonName = "First Quarter",
    }
    snap.body, snap.bodyProgress = environment.celestial(tick)
    local scene = backdrops.scene(id, snap, true)
    grid:setPalette(scene.palette)
    sky.paint(grid, scene, anim or 6.2)
  end
end

sheet(OUT .. "/backdrops-live.bmp", {
  liveTile("shipDay", 23400, false, false, nil, 3.1),          -- airship, sunrise
  liveTile("shipDay", 6000,  false, false, nil, 8.4),          -- airship, noon
  liveTile("shipDay", 12200, false, false, nil, 12.7),         -- airship, sunset
  liveTile("shipDay", 18000, false, false, nil, 17.2),         -- airship, night
  liveTile("shipDay", 6000,  true,  false, nil, 21.5),         -- airship, rain
  liveTile("shipDay", 6000,  true,  true,  nil, 25.9),         -- airship, storm
  liveTile("shipDay", 4000, true, false, "minecraft:snowy_taiga", 30.3),
  liveTile("shipDay", 6000, true, false, "minecraft:desert", 34.8),
  liveTile("islesDawn", 18000, false, false, nil, 39.1),       -- isles, night
  liveTile("islesDawn", 6000, true, true, nil, 43.6),          -- isles, storm
  liveTile("cloudDay", 12200, false, false, nil, 48.0),        -- cloud sea, dusk
  liveTile("spiresDay", 23400, false, false, nil, 52.4),       -- spires, sunrise
}, 3)

--------------------------------------------------------------------- power --
-- The POWER page's plot area: a buffer gauge over a rolling chart of supply
-- and demand. The palette is spelled out here rather than required off the
-- module, exactly as the radar scope above is, so this script keeps its one
-- useful property -- it loads the drawing code and nothing else.

local chart = require("radar.chart")

local POWER_PALETTE = {
  theme.tones.bg,        -- 1 background
  theme.tones.panel,     -- 2 the buffer, drawn as a backdrop behind the rates
  theme.tones.line,      -- 3 rules and ticks
  theme.tones.good,      -- 4 supply
  theme.tones.warn,      -- 5 demand
  theme.tones.accent,    -- 6 the gauge fill
  theme.tones.alarm,     -- 7 a buffer under the alarm threshold
  theme.tones.dim,       -- 8
}

local P_BG, P_PANEL, P_LINE, P_IN, P_OUT, P_BANK, P_ALARM = 1, 2, 3, 4, 5, 6, 7

--- Builds a plausible few minutes of readings.
---@param shape function(t) -> supply, demand, bufferPercent   t runs 0..1
local function series(shape, count)
  local ins, outs, pct = {}, {}, {}
  for i = 1, count do
    local supply, demand, buffer = shape((i - 1) / (count - 1), i)
    ins[i], outs[i], pct[i] = supply, demand, buffer
  end
  return ins, outs, pct
end

local function powerTile(shape, level, count)
  return function(grid)
    grid:setPalette(POWER_PALETTE)
    grid:clear(P_BG)

    local low = level <= 0.2

    -- The gauge, one cell tall at the top.
    local gauge = { x = 1, y = 1, w = grid.w, h = 2 }
    chart.gauge(grid, gauge, level, low and P_ALARM or P_BANK, P_PANEL)
    chart.gaugeTicks(grid, gauge, 0.25, P_LINE)
    grid:set(math.floor(1 + (grid.w - 1) * 0.2 + 0.5), 3, P_ALARM)

    -- The chart underneath it.
    local box = { x = 1, y = 6, w = grid.w, h = grid.h - 5 }
    local ins, outs, pct = series(shape, count or 240)

    chart.ticks(grid, box, 4, P_LINE)
    chart.line(grid, box, {
      { values = pct, index = P_PANEL, fill = true, fillIndex = P_PANEL },
    }, { count = 300, min = 0, max = 100 })
    local lo, hi = chart.line(grid, box, {
      { values = ins, index = P_IN },
      { values = outs, index = P_OUT },
    }, { count = 300, zero = true })
    chart.rule(grid, box, 0, lo, hi, P_LINE, 2)
  end
end

sheet(OUT .. "/power-graph.bmp", {
  -- Steady supply over a demand that breathes: the healthy base.
  powerTile(function(t)
    return 5200 + math.sin(t * 9) * 300,
           3800 + math.sin(t * 21) * 900,
           62 + math.sin(t * 5) * 4
  end, 0.64),

  -- A furnace array switching on: demand steps up and the buffer starts down.
  powerTile(function(t)
    local demand = t < 0.35 and 2400 or 9200 + math.sin(t * 30) * 600
    return 5000, demand, t < 0.35 and 88 or (88 - (t - 0.35) * 95)
  end, 0.31),

  -- Under the threshold: the gauge and the alarm mark both go red.
  powerTile(function(t)
    return 900 + math.sin(t * 14) * 200,
           7400 + math.sin(t * 40) * 1500,
           math.max(4, 40 - t * 38)
  end, 0.08),

  -- Charging back up after the reactor restarts.
  powerTile(function(t)
    return t < 0.2 and 600 or 12000 - math.sin(t * 6) * 800,
           3100,
           math.min(99, 12 + t * 92)
  end, 0.97),

  -- A grid doing nothing at all: the flat case a chart has to survive.
  powerTile(function() return 1500, 1500, 50 end, 0.50),

  -- Rate only, from an Energy Detector with no battery behind it.
  powerTile(function(t, i)
    local spike = (i % 47 < 4) and 14000 or 0
    return 4200 + math.sin(t * 55) * 2600 + spike, 4100 + math.sin(t * 12) * 500, nil
  end, 0),
}, 3)
