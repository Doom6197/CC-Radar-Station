-- Procedural sky, weather, ground and horizon painting.
--
-- Rather than shipping a fixed picture per weather type, the scene is drawn
-- from the live snapshot: the sun and moon really do climb and set along the
-- Minecraft day, the moon shows its actual phase, clouds drift, rain slants,
-- lightning strikes, and the palette shifts with the hour. Dawn, noon, dusk,
-- night, rain, snow, thunder, the Nether and the End each look distinct.
--
-- Under all of that sits the ground, and the ground comes from the biome. A
-- profile from radar.biomes picks a terrain silhouette and a kind of plant to
-- grow on it, so a desert gets dunes and cactus, a coast gets surf, a cave
-- gets a ceiling, and a skyblock world gets floating islands over open air.
--
-- Everything is painted by palette INDEX into a radar.pixel grid, using only
-- the ten entries a sky palette defines:
--
--   1 skyHigh  2 skyMid  3 skyLow  4 body   5 glow
--   6 cloud    7 cloudShade        8 land   9 landShade   10 accent
--
-- No colour outside that set is used, which is what keeps the weather page
-- inside the sixteen hardware palette slots. The biome only ever replaces
-- 8, 9 and 10, so a change of scenery costs no extra colours at all.

local util   = require("radar.util")
local biomes = require("radar.biomes")

local sky = {}

local SKY_HIGH, SKY_MID, SKY_LOW = 1, 2, 3
local BODY, GLOW = 4, 5
local CLOUD, CLOUD_SHADE = 6, 7
local LAND, LAND_SHADE, ACCENT = 8, 9, 10

local floor, sin, cos, pi, sqrt = math.floor, math.sin, math.cos, math.pi, math.sqrt
local min, max, abs = math.min, math.max, math.abs
local hash = util.hash01

-- ---------------------------------------------------------------- pieces ---

--- One cumulus blob: a shaded underside with a lit cap sitting on top.
local function cloud(grid, x, y, r, top, shade)
  grid:disc(x, y + r * 0.45, r * 1.05, shade)
  grid:disc(x - r * 1.1, y + r * 0.5, r * 0.75, shade)
  grid:disc(x + r * 1.1, y + r * 0.5, r * 0.8, shade)
  grid:disc(x, y, r, top)
  grid:disc(x - r * 1.05, y + r * 0.15, r * 0.7, top)
  grid:disc(x + r * 1.05, y + r * 0.1, r * 0.75, top)
end

--- Parallax cloud bands. Higher layers are smaller, paler and slower.
--- `top` and `spread` place the bands as fractions of the sky height: fair
--- weather keeps them low so they do not swallow the sun, while overcast
--- weather fills the sky from the top down.
local function clouds(grid, w, horizon, anim, layers, perLayer, seed, top, spread)
  top, spread = top or 0.16, spread or 0.42
  for layer = 1, layers do
    local depth = layer / layers                    -- 0 = far, 1 = near
    local y = horizon * (top + spread * depth)
    local r = 2 + depth * 3.5
    local speed = 1.5 + depth * 4.5
    local span = w + r * 12
    for i = 1, perLayer do
      local offset = hash(i * 3.7, layer * 11 + seed) * span
      local x = (offset + anim * speed) % span - r * 6
      local wobble = sin(anim * 0.35 + i + layer) * 0.6
      cloud(grid, x, y + wobble, r, CLOUD, CLOUD_SHADE)
    end
  end
end

--- Fixed star field with a slow twinkle. Positions come from a hash, so the
--- sky is the same every redraw instead of boiling.
local function stars(grid, w, horizon, anim, count, brightIndex, faintIndex)
  local frame = floor(anim * 2)
  for i = 1, count do
    local x = floor(hash(i, 1) * w) + 1
    local y = floor(hash(i, 2) * (horizon - 2)) + 1
    local twinkle = hash(i, frame % 97)
    if twinkle > 0.22 then
      grid:set(x, y, twinkle > 0.72 and brightIndex or faintIndex)
    end
  end
end

--- The sun: a hot core inside a soft halo.
local function sun(grid, cx, cy, r)
  grid:disc(cx, cy, r * 1.75, GLOW)
  grid:disc(cx, cy, r, BODY)
end

-- Minecraft phase ids: 0 full, 1 waning gibbous, 2 last quarter, 3 waning
-- crescent, 4 new, 5 waxing crescent, 6 first quarter, 7 waxing gibbous.
local MOON_LIT = { [0] = 1, 0.75, 0.5, 0.25, 0, 0.25, 0.5, 0.75 }

--- The moon, shaded to its real phase: a dark disc inside a halo, with the
--- lit part carved out of it. The terminator is the ellipse whose half-width
--- is cos(pi * litFraction) of the disc radius, so a half moon (0.5) gives a
--- straight edge and a full moon (1) covers the whole disc.
local function moon(grid, cx, cy, r, phase)
  local lit = MOON_LIT[phase] or 1
  local waxing = (phase >= 5)                 -- lit on the right-hand limb
  local terminator = cos(pi * lit)

  grid:disc(cx, cy, r * 1.7, GLOW)
  grid:disc(cx, cy, r, CLOUD_SHADE)
  if lit <= 0 then return end                 -- new moon: halo and shadow only

  for dy = -floor(r), floor(r) do
    local span = r * r - dy * dy
    if span >= 0 then
      local half = sqrt(span)
      local edge = terminator * half
      local x0, x1
      if waxing then x0, x1 = cx + edge, cx + half
      else x0, x1 = cx - half, cx - edge end
      if x1 > x0 then grid:hline(x0, x1, cy + dy, BODY) end
    end
  end
end

local function rain(grid, w, h, horizon, anim, density, index)
  local reach = horizon + 4
  for i = 1, density do
    local sx, sy = hash(i, 61), hash(i, 62)
    local speed = 26 + sy * 18
    local x = floor(sx * (w + 12)) - 6 + floor(anim * 3)
    local y = (sy * h + anim * speed) % reach
    grid:line(x, y, x - 1, y + 3, index)
  end
end

local function snowfall(grid, w, h, horizon, anim, density, index)
  local reach = horizon + 6
  for i = 1, density do
    local sx, sy = hash(i, 71), hash(i, 72)
    local sway = sin(anim * 0.9 + i * 1.7) * 2.5
    local x = sx * w + sway
    local y = (sy * h + anim * (5 + sy * 4)) % reach
    grid:set(x, y, index)
  end
end

--- A forked bolt, drawn only on the frames the strike hash selects.
local function lightning(grid, w, horizon, anim)
  local slot = floor(anim * 1.6)
  if hash(slot, 907) < 0.86 then return false end

  -- Wash the whole sky out for the duration of the strike.
  grid:ditherGradient(1, horizon, { BODY, GLOW, GLOW })

  -- The bolt is a negative against the washed-out sky. Two parallel strokes
  -- in the darkest tone keep it distinct from the rain drawn over it.
  local x = 6 + hash(slot, 3) * (w - 12)
  local y = 1
  local step = max(3, floor(horizon / 6))
  while y < horizon do
    local nx = x + (hash(slot, y) * 2 - 1) * step
    grid:line(x, y, nx, y + step, LAND_SHADE)
    grid:line(x + 1, y, nx + 1, y + step, LAND_SHADE)
    if hash(slot, y + 500) > 0.7 then
      local branch = nx + (hash(slot, y + 9) * 2 - 1) * step
      grid:line(nx, y + step, branch, y + step * 2, LAND_SHADE)
    end
    x, y = nx, y + step
  end
  return true
end

-- ---------------------------------------------------------------- terrain ---
-- One painter per ground silhouette. Each covers every pixel from `horizon`
-- down -- the cell compiler reads all six sub-pixels of every cell, and an
-- unpainted one has no palette index at all -- and returns:
--
--   groundAt(x)   the row a plant standing at x grows from, or nil where
--                 nothing can grow (open water, the gap between islands)
--   foreground()  optional, run AFTER the flora, so a near ridge can stand in
--                 front of the trees on the ridge behind it
--
-- `p` is the radar.biomes profile, which is what makes ACCENT mean foliage on
-- a forest, water on a coast and glow underground.

local TERRAIN = {}

function TERRAIN.hills(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND)
  if depth < 2 then return function() return horizon end end

  local function far(x)
    local t = x / w
    local ridge = sin(t * 5.7) * 0.45 + sin(t * 12.9 + 1.7) * 0.22 + sin(t * 2.1 + 0.6) * 0.33
    return horizon - ridge * depth * 0.55
  end
  for x = 1, w do grid:vline(x, far(x), h, LAND) end

  return far, function()
    for x = 1, w do
      local t = x / w
      local ridge = sin(t * 3.1 + 2.2) * 0.55 + sin(t * 8.3 + 0.4) * 0.25
      grid:vline(x, horizon + depth * 0.42 - ridge * depth * 0.3, h, LAND_SHADE)
    end
  end
end

function TERRAIN.flat(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND)
  if depth < 2 then return function() return horizon end end

  local function surface(x)
    local t = x / w
    return horizon - (sin(t * 6.1) * 0.14 + sin(t * 15.3 + 1.1) * 0.07) * depth
  end
  for x = 1, w do grid:vline(x, surface(x), h, LAND) end

  return surface, function()
    for x = 1, w do
      local t = x / w
      grid:vline(x, horizon + depth * (0.62 + sin(t * 4.3) * 0.08), h, LAND_SHADE)
    end
  end
end

function TERRAIN.dunes(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND)
  if depth < 2 then return function() return horizon end end

  local function crest(x)
    local t = x / w
    return horizon - (sin(t * 4.1) * 0.4 + sin(t * 9.7 + 2.3) * 0.25) * depth * 0.5
  end
  for x = 1, w do grid:vline(x, crest(x), h, LAND) end

  -- The lee side of each dune, in shadow. Offsetting the same wave rather
  -- than inventing a second one is what makes the shadow sit on the dune.
  -- Unlike a ridge line this is not a foreground pass: there is nothing in
  -- front of it, and drawing it after the flora would bury the cactus.
  for x = 1, w do
    local t = x / w
    grid:vline(x, horizon + depth * 0.34 - sin(t * 4.1 - 1.15) * depth * 0.22, h, LAND_SHADE)
  end

  return crest
end

function TERRAIN.peaks(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND_SHADE)
  if depth < 2 then return function() return horizon end end

  local tops = {}
  for x = 1, w do tops[x] = horizon end

  -- Two ranges: a tall pale one behind, a shorter dark one in front.
  for pass = 1, 2 do
    local index = (pass == 1) and LAND or LAND_SHADE
    local count = max(2, floor(w / (pass == 1 and 15 or 11)))
    local footing = horizon + depth * (pass == 1 and 0.34 or 0.66)
    for i = 0, count do
      local cx = (i + 0.5 + (hash(i, 20 + pass) - 0.5) * 0.7) * (w / count)
      local halfW = (w / count) * (0.7 + hash(i, 30 + pass) * 0.7)
      local top = footing - depth * (0.55 + hash(i, 40 + pass) * 0.85)
        * (pass == 1 and 1.0 or 0.55)
      local x0, x1 = max(1, floor(cx - halfW)), min(w, floor(cx + halfW))
      for x = x0, x1 do
        local slope = top + abs(x - cx) / max(1, halfW) * (footing - top)
        grid:vline(x, slope, h, index)
        if pass == 1 and slope < tops[x] then tops[x] = slope end
        -- Snow, or a treeline, depending on how cold the biome is: either way
        -- the very top of the ridge is a different colour from its flanks.
        local capTo = top + depth * 0.22
        if p.cold and slope < capTo then
          grid:vline(x, slope, capTo, ACCENT)
        end
      end
    end
  end

  return function(x)
    return tops[util.clamp(floor(x), 1, w)] or horizon
  end
end

function TERRAIN.plateau(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND_SHADE)
  if depth < 2 then return function() return horizon end end

  -- Flat-topped steps rather than a smooth ridge: that squared-off skyline is
  -- most of what makes badlands read as badlands.
  local steps = max(3, floor(w / 11))
  local tops = {}
  for x = 1, w do
    local step = floor((x - 1) / w * steps)
    tops[x] = horizon - depth * (0.12 + hash(step, 61) * 0.55)
    grid:vline(x, tops[x], h, LAND)
  end

  -- Horizontal strata banding the exposed rock face.
  local bandHeight = max(1, depth / 8)
  for row = 0, floor(depth * 1.2) do
    local y = horizon - depth * 0.7 + row
    local band = floor(row / bandHeight) % 3
    if band ~= 0 then
      local index = (band == 1) and LAND_SHADE or ACCENT
      for x = 1, w do
        if y >= tops[x] then grid:set(x, y, index) end
      end
    end
  end

  return function(x)
    return tops[util.clamp(floor(x), 1, w)] or horizon
  end
end

function TERRAIN.ocean(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND)
  if depth < 2 then return function() return nil end end

  -- Deeper water in the foreground, with a slow swell along the join.
  for x = 1, w do
    grid:vline(x, horizon + depth * 0.55 + sin(x * 0.18 + anim * 1.1) * max(1, depth * 0.07),
      h, LAND_SHADE)
  end

  -- Crests, packed tighter toward the horizon where the swell foreshortens.
  local rows = max(2, floor(depth))
  for r = 1, rows do
    local t = (r / rows) ^ 1.7
    local y = horizon + t * depth
    local drift = anim * (2 + t * 8) + r * 2.7
    local period = max(4, floor(4 + (1 - t) * 12))
    for x = 1, w do
      if floor(x + drift + sin(x * 0.25 + r) * 2) % period == 0 then
        grid:set(x, y, ACCENT)
      end
    end
  end

  -- Ice floes float; trees do not.
  return function(x)
    if p.flora == "iceSpike" then return horizon + depth * 0.2 end
    return nil
  end
end

function TERRAIN.shore(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND)
  if depth < 2 then return function() return horizon end end

  -- The waterline runs from the horizon down and to the right, so the sand
  -- widens toward the viewer the way a beach actually does.
  local function strand(y)
    local t = (y - horizon) / max(1, depth)
    return w * (0.14 + t * 0.30)
  end

  for y = floor(horizon), h do
    local edge = strand(y)
    grid:hline(1, edge, y, ACCENT)
    -- Surf: a band of wet sand that creeps up and down the beach.
    grid:hline(edge, edge + 1.5 + sin(y * 0.9 + anim * 1.6) * 1.2, y, LAND_SHADE)
  end

  -- Only the dry side, well clear of the surf, can hold a tree.
  local dryFrom = strand(h) + max(2, w * 0.06)
  return function(x)
    if x < dryFrom then return nil end
    return horizon + depth * 0.12
  end
end

function TERRAIN.swamp(grid, w, h, horizon, p, anim)
  local depth = h - horizon
  grid:rect(1, horizon, w, depth + 1, LAND)
  if depth < 2 then return function() return horizon end end

  for x = 1, w do
    grid:vline(x, horizon - sin(x / w * 7.3) * depth * 0.08, h, LAND)
  end
  grid:rect(1, floor(horizon + depth * 0.7), w, h, LAND_SHADE)

  -- Standing water, in flat pools rather than a single sheet.
  local pools = {}
  for i = 1, max(2, floor(w / 16)) do
    local cx = hash(i, 71) * w
    local halfW = w * (0.05 + hash(i, 72) * 0.09)
    local y = horizon + depth * (0.22 + hash(i, 73) * 0.62)
    local rows = max(1, floor(depth * 0.14))
    pools[i] = { cx = cx, halfW = halfW, y = y, rows = rows }
    for row = 0, rows do
      -- Pools narrow as they recede, so they read as lying flat.
      local squeeze = halfW * (1 - row / (rows + 2) * 0.3)
      grid:hline(cx - squeeze, cx + squeeze, y + row, ACCENT)
    end
  end

  return function(x)
    for _, pool in ipairs(pools) do
      if x > pool.cx - pool.halfW and x < pool.cx + pool.halfW then return nil end
    end
    return horizon + depth * 0.1
  end
end

--- Skyblock: no ground at all, just rock hanging in open air. The islands are
--- painted straight into the sky gradient, which already covers the frame.
function TERRAIN.void(grid, w, h, horizon, p, anim)
  local isles = {}
  local count = max(1, floor(w / 24))
  for i = 0, count do
    local cx = (i + 0.5 + (hash(i, 91) - 0.5) * 0.6) * (w / (count + 1))
    local halfW = w * (0.07 + hash(i, 92) * 0.10)
    -- A slow bob, so the scene is alive even with nothing else moving.
    local top = h * (0.40 + hash(i, 93) * 0.34) + sin(anim * 0.2 + i * 1.7) * max(1, h * 0.02)
    local deep = max(3, halfW * 1.6)

    for row = 0, deep do
      local taper = halfW * (1 - (row / (deep + 1)) ^ 1.5)
      if taper >= 0.5 then
        local index = LAND_SHADE
        if row < 1 then index = ACCENT               -- grass cap
        elseif row < deep * 0.4 then index = LAND end
        grid:hline(cx - taper, cx + taper, top + row, index)
      end
    end
    isles[#isles + 1] = { cx = cx, halfW = halfW, top = top }
  end

  return function(x)
    for _, isle in ipairs(isles) do
      if x > isle.cx - isle.halfW * 0.65 and x < isle.cx + isle.halfW * 0.65 then
        return isle.top
      end
    end
    return nil
  end
end

-- --------------------------------------------------------- open-air scenes ---
-- Grounds for a world with no ground. Everything below hangs in open air, so
-- these paint over the sky gradient rather than under a horizon line. No biome
-- id resolves to any of them: they exist to be picked, which is what lets
-- radar.backdrops put a scene on screen that owes nothing to the detector.

--- Layered floating islands. The far bands drift for parallax; the near band
--- is deliberately held still, because paintFlora places trees at a fixed x
--- and a tree whose island slides out from under it looks as wrong as it
--- sounds.
function TERRAIN.archipelago(grid, w, h, horizon, p, anim)
  local near = {}
  local bands = (w >= 30 and h >= 12) and 3 or 2

  for band = 1, bands do
    local depth = band / bands                       -- 0 far .. 1 near
    local nearest = (band == bands)
    -- Sparse on purpose. A skyful of islands reads as rubble and leaves the
    -- sun nowhere to be, which is most of what makes the scene.
    local count = max(1, floor(w / (52 - band * 10)))
    local span = w + 30
    local drift = nearest and 0 or anim * (0.5 + depth * 0.8)

    for i = 0, count do
      local cx = nearest
        and ((i + 0.5 + (hash(i, 90 + band) - 0.5) * 0.6) * (w / (count + 1)))
        or (((hash(i, 90 + band) * span + drift) % span) - 15)
      local halfW = max(1.5, w * (0.03 + depth * 0.075) * (0.7 + hash(i, 95 + band) * 0.6))
      local top = h * (0.16 + hash(i, 97 + band) * 0.50)
        + sin(anim * 0.22 + i * 1.3) * max(0.4, h * 0.012)
      local deep = max(2, halfW * (1.1 + hash(i, 99 + band) * 0.7))

      for row = 0, deep do
        local taper = halfW * (1 - (row / (deep + 1)) ^ 1.4)
        if taper >= 0.5 then
          local index = LAND_SHADE
          if nearest then
            if row < 1 then index = ACCENT               -- grass cap
            elseif row < deep * 0.4 then index = LAND end
          elseif row < deep * 0.35 then
            index = LAND
          end
          grid:hline(cx - taper, cx + taper, top + row, index)
        end
      end

      -- Water pouring off the underside. At this size it is the one detail
      -- that reads as "island" rather than as "rock" -- but only if it stops
      -- short: a line all the way to the frame edge reads as rain instead.
      local base = top + deep
      if nearest and base < h - 4 and hash(i, 101) > 0.5 then
        grid:vline(cx + (hash(i, 102) - 0.5) * halfW, base - deep * 0.3,
          base + (h - base) * (0.18 + hash(i, 103) * 0.22), CLOUD)
      end

      if nearest then near[#near + 1] = { cx = cx, halfW = halfW, top = top } end
    end
  end

  return function(x)
    for _, isle in ipairs(near) do
      if x > isle.cx - isle.halfW * 0.6 and x < isle.cx + isle.halfW * 0.6 then
        return isle.top
      end
    end
    return nil
  end
end

--- A sea of cloud with peaks breaking through it: the world as seen from an
--- airship at altitude, where the weather is below you rather than around you.
function TERRAIN.cloudSea(grid, w, h, horizon, p, anim)
  local sea = h * 0.60
  local base = sea + max(2, h * 0.14)
  local peaks = {}

  local count = max(2, floor(w / 16))
  for i = 0, count do
    local cx = (i + 0.5) * (w / (count + 1)) + (hash(i, 61) - 0.5) * w * 0.05
    local halfW = max(2, w * (0.04 + hash(i, 62) * 0.06))
    local top = sea - h * (0.08 + hash(i, 63) * 0.34)
    for x = floor(cx - halfW), floor(cx + halfW) do
      local t = abs(x - cx) / halfW
      -- Lit on the left, shaded on the right, the same way round on every
      -- peak: one consistent light is what makes them read as solid.
      grid:vline(x, top + t * t * (base - top), base, x < cx and LAND or LAND_SHADE)
    end
    peaks[#peaks + 1] = { cx = cx, halfW = halfW, top = top }
  end

  -- The deck, over the peaks so only their summits stay clear of it. Drawn as
  -- overlapping billows rather than a filled line: a flat band of one colour
  -- reads as paint, not as cloud.
  grid:rect(1, floor(sea), w, h - floor(sea) + 1, CLOUD)
  local lobes = max(3, floor(w / 8))
  for i = 0, lobes do
    local x = (i + 0.5) / (lobes + 1) * w + sin(anim * 0.15 + i * 1.7) * max(0.5, w * 0.012)
    local r = max(1.5, h * (0.035 + hash(i, 71) * 0.05))
    grid:disc(x, sea + r * 0.4, r, CLOUD)
    grid:disc(x - r * 0.9, sea + r * 0.8, r * 0.6, CLOUD)
  end

  -- Crevices between the billows, drifting slowly through the deck.
  for i = 1, max(2, floor(w / 12)) do
    local x = (hash(i, 73) * (w + 24) + anim * (0.5 + hash(i, 74) * 0.8)) % (w + 24) - 12
    local y = sea + h * (0.10 + hash(i, 75) * 0.16)
    grid:disc(x, y, max(1.5, h * 0.045), CLOUD_SHADE)
    grid:hline(x - h * 0.09, x + h * 0.09, y + h * 0.05, CLOUD_SHADE)
  end

  -- A shaded near edge along the bottom, which is what gives the deck depth.
  for x = 1, w do
    grid:vline(x, h - max(2, h * 0.10)
      + sin(x / w * 4.1 - anim * 0.25) * max(1, h * 0.02), h, CLOUD_SHADE)
  end

  return function(x)
    for _, peak in ipairs(peaks) do
      if x > peak.cx - peak.halfW * 0.4 and x < peak.cx + peak.halfW * 0.4 then
        return peak.top
      end
    end
    return nil
  end
end

--- One airship: an envelope with a lit top and a shaded underside, fins at the
--- blunt end so which way it is heading is never in doubt, and a gondola slung
--- underneath on rigging.
local function airshipAt(grid, cx, cy, len, tall)
  for dx = -len, len do
    local t = dx / len
    local half = tall * sqrt(max(0, 1 - t * t))
    grid:vline(cx + dx, cy - half, cy + half, LAND)
    grid:vline(cx + dx, cy + half * 0.3, cy + half, LAND_SHADE)
  end
  grid:hline(cx - len * 0.88, cx + len * 0.88, cy - tall * 0.3, ACCENT)

  local tx = cx - len
  grid:line(tx, cy, tx - len * 0.3, cy - tall * 1.1, LAND_SHADE)
  grid:line(tx, cy, tx - len * 0.3, cy + tall * 1.1, LAND_SHADE)
  grid:line(tx - len * 0.3, cy - tall * 1.1, tx - len * 0.3, cy + tall * 1.1, LAND_SHADE)

  local gy = cy + tall + max(1, tall * 0.5)
  grid:rect(cx - len * 0.2, gy, max(2, len * 0.4), max(1, floor(tall * 0.5)), LAND_SHADE)
  grid:line(cx - len * 0.18, gy, cx - len * 0.3, cy + tall * 0.8, ACCENT)
  grid:line(cx + len * 0.18, gy, cx + len * 0.3, cy + tall * 0.8, ACCENT)
end

--- Airships under way, with islands beneath them for scale. Nothing grows
--- here: everything in the frame is moving, and flora is placed at a fixed x.
function TERRAIN.airship(grid, w, h, horizon, p, anim)
  local count = max(1, floor(w / 26))
  for i = 0, count do
    local cx = ((hash(i, 111) * (w + 24) + anim * 0.35) % (w + 24)) - 12
    local halfW = max(1.5, w * (0.03 + hash(i, 112) * 0.04))
    local top = h * (0.68 + hash(i, 113) * 0.20)
    local deep = max(2, halfW * 1.3)
    for row = 0, deep do
      local taper = halfW * (1 - (row / (deep + 1)) ^ 1.4)
      if taper >= 0.5 then
        grid:hline(cx - taper, cx + taper, top + row, row < 1 and ACCENT or LAND_SHADE)
      end
    end
  end

  -- A small one in the distance, then the near one over the top of it.
  if w >= 30 and h >= 12 then
    local len = max(2, w * 0.05)
    airshipAt(grid, ((anim * 0.9 + w * 0.35) % (w + len * 6)) - len * 3,
      h * 0.26, len, max(1, len * 0.42))
  end

  local len = max(3, w * 0.13)
  airshipAt(grid, ((anim * 2.0) % (w + len * 8)) - len * 4,
    h * 0.44 + sin(anim * 0.5) * max(0.5, h * 0.03), len, max(1.5, len * 0.42))

  return function() return nil end
end

--- Stone spires standing in haze: the shape a world of floating islands leaves
--- behind where the islands are columns rather than plates.
function TERRAIN.spires(grid, w, h, horizon, p, anim)
  local tops = {}
  local count = max(2, floor(w / 12))
  for i = 0, count do
    local cx = (i + 0.5) * (w / (count + 1)) + (hash(i, 81) - 0.5) * w * 0.06
    local halfW = max(1, w * (0.012 + hash(i, 82) * 0.02))
    local top = h * (0.08 + hash(i, 83) * 0.38)
    local reach = max(1, h * (0.74 + hash(i, 84) * 0.24) - top)
    local index = hash(i, 85) > 0.5 and LAND or LAND_SHADE
    for row = 0, reach do
      local flare = halfW * (1 + (row / reach) ^ 2 * 1.1)
      grid:hline(cx - flare, cx + flare, top + row, index)
    end
    grid:hline(cx - halfW * 1.5, cx + halfW * 1.5, top, ACCENT)
    tops[#tops + 1] = { cx = cx, halfW = halfW * 1.5, top = top }
  end

  -- Haze pooling around the feet, so the towers fade out rather than being
  -- sliced off by the bottom of the frame. Its top edge is lumpy for the same
  -- reason the cloud deck's is: a straight line reads as a painted band.
  local haze = h * 0.80
  grid:rect(1, floor(haze), w, h - floor(haze) + 1, CLOUD_SHADE)
  for i = 0, max(3, floor(w / 9)) do
    local x = (hash(i, 86) * (w + 20) + anim * (0.3 + hash(i, 87) * 0.5)) % (w + 20) - 10
    local r = max(1.5, h * (0.03 + hash(i, 88) * 0.04))
    grid:disc(x, haze + r * 0.5, r, CLOUD_SHADE)
  end
  for x = 1, w do
    local t = x / w
    grid:vline(x, h * 0.91 + sin(t * 3.1 - anim * 0.2) * max(1, h * 0.02), h, CLOUD)
  end

  return function(x)
    for _, spire in ipairs(tops) do
      if x > spire.cx - spire.halfW and x < spire.cx + spire.halfW then return spire.top end
    end
    return nil
  end
end

-- ----------------------------------------------------------------- flora ---
-- One painter per kind of plant. `base` is the row it grows from, `growth` a
-- height budget derived from the room below the horizon, and `seed` its index
-- so the same plant keeps the same shape between frames.

local FLORA = {}

function FLORA.conifer(grid, x, base, growth, seed)
  local height = max(3, floor(growth * 0.5) + floor(hash(seed, 42) * 3))
  grid:vline(x, base - 1, base + 1, LAND_SHADE)
  for row = 0, height - 1 do
    local halfW = floor((height - row) * 0.6)
    grid:hline(x - halfW, x + halfW, base - 1 - row, ACCENT)
  end
end

function FLORA.broadleaf(grid, x, base, growth, seed)
  local trunk = max(2, floor(growth * 0.3) + floor(hash(seed, 42) * 3))
  local r = max(1.5, trunk * 0.62)
  grid:vline(x, base - trunk, base + 1, LAND_SHADE)
  grid:disc(x, base - trunk - r * 0.4, r, ACCENT)
  grid:disc(x - r * 0.75, base - trunk + r * 0.2, r * 0.6, ACCENT)
  grid:disc(x + r * 0.75, base - trunk + r * 0.15, r * 0.65, ACCENT)
end

--- Pale trunks are the whole point of a birch, so they borrow the cloud tone
--- rather than the ground shadow every other tree uses.
function FLORA.birch(grid, x, base, growth, seed)
  local trunk = max(3, floor(growth * 0.45) + floor(hash(seed, 42) * 3))
  local r = max(1.2, trunk * 0.4)
  grid:vline(x, base - trunk, base + 1, CLOUD)
  grid:disc(x, base - trunk - r * 0.3, r, ACCENT)
  grid:disc(x - r * 0.6, base - trunk + r * 0.3, r * 0.55, ACCENT)
end

function FLORA.acacia(grid, x, base, growth, seed)
  local trunk = max(3, floor(growth * 0.42) + floor(hash(seed, 42) * 2))
  local spread = max(2, floor(trunk * 0.95))
  grid:line(x, base + 1, x - 1, base - trunk, LAND_SHADE)
  grid:line(x, base + 1, x + 2, base - trunk + 1, LAND_SHADE)
  grid:hline(x - spread, x + spread, base - trunk, ACCENT)
  grid:hline(x - spread + 1, x + spread - 1, base - trunk - 1, ACCENT)
end

-- A cactus is the smallest thing anything grows, and the cell compiler keeps
-- only the two commonest colours in each cell: a two-by-three splash of green
-- loses to the sand around it and disappears. Hence the generous proportions.
function FLORA.cactus(grid, x, base, growth, seed)
  local height = max(4, floor(growth * 0.5) + floor(hash(seed, 42) * 3))
  grid:rect(x, base - height, 2, height + 1, ACCENT)
  if hash(seed, 43) > 0.35 then
    local arm = base - height + max(2, floor(height * 0.45))
    local reach = max(2, floor(height * 0.4))
    grid:hline(x - reach, x, arm, ACCENT)
    grid:vline(x - reach, arm - max(2, floor(height * 0.35)), arm, ACCENT)
  end
end

function FLORA.bamboo(grid, x, base, growth, seed)
  local height = max(3, floor(growth * 0.7) + floor(hash(seed, 42) * 4))
  for k = -1, 1 do
    local sx = x + k
    local top = base - height + floor(hash(seed, 44 + k) * 3)
    grid:vline(sx, top, base + 1, ACCENT)
    grid:set(sx + (k >= 0 and 1 or -1), top - 1, ACCENT)
  end
end

function FLORA.mushroom(grid, x, base, growth, seed)
  local stem = max(2, floor(growth * 0.3) + floor(hash(seed, 42) * 3))
  local r = max(2, stem * 0.9)
  grid:vline(x, base - stem, base + 1, CLOUD)
  -- The upper half of a disc only, so the cap sits on the stem as a dome.
  for row = 0, floor(r) do
    local span = r * r - row * row
    if span >= 0 then
      local half = sqrt(span)
      grid:hline(x - half, x + half, base - stem - row, ACCENT)
    end
  end
end

function FLORA.iceSpike(grid, x, base, growth, seed)
  local height = max(3, floor(growth * 0.75) + floor(hash(seed, 42) * 4))
  local halfW = max(1, floor(height * 0.22))
  for row = 0, height do
    local taper = floor(halfW * (1 - row / height))
    grid:hline(x - taper, x + taper, base - row, row > height * 0.55 and CLOUD or ACCENT)
  end
end

--- Bare branches, drawn in the accent rather than the ground shadow: on snow
--- the shadow tone is very nearly the ground itself, and a tree that cannot be
--- told apart from the field it stands in is not worth drawing.
function FLORA.deadTree(grid, x, base, growth, seed)
  local trunk = max(3, floor(growth * 0.45) + floor(hash(seed, 42) * 3))
  local reach = max(2, floor(trunk * 0.5))
  grid:vline(x, base - trunk, base + 1, ACCENT)
  local fork = base - trunk + floor(trunk * 0.35)
  grid:line(x, fork, x - reach, fork - floor(trunk * 0.45), ACCENT)
  grid:line(x, fork - 1, x + reach, fork - floor(trunk * 0.5), ACCENT)
end

function FLORA.palm(grid, x, base, growth, seed)
  local height = max(4, floor(growth * 0.6) + floor(hash(seed, 42) * 3))
  local lean = (hash(seed, 43) > 0.5) and 1 or -1
  local tipX, tipY = x, base - height
  for row = 0, height do
    tipX = x + lean * (row / height) ^ 2 * height * 0.35
    tipY = base - row
    grid:set(tipX, tipY, LAND_SHADE)
  end
  for frond = -2, 2 do
    grid:line(tipX, tipY,
      tipX + frond * height * 0.3,
      tipY + abs(frond) * height * 0.16 - height * 0.12, ACCENT)
  end
end

--- Hangs downward from `base` rather than growing up from it: this is what a
--- lush or sculk cave ceiling is wearing.
function FLORA.glowVine(grid, x, base, growth, seed)
  local length = max(2, floor(growth * 0.5) + floor(hash(seed, 42) * 3))
  grid:vline(x, base, base + length, ACCENT)
  grid:set(x - 1, base + length, ACCENT)
  grid:set(x + 1, base + floor(length * 0.6), ACCENT)
end

function FLORA.fungus(grid, x, base, growth, seed)
  local stem = max(3, floor(growth * 0.5) + floor(hash(seed, 42) * 3))
  grid:vline(x, base - stem, base + 1, LAND_SHADE)
  grid:disc(x, base - stem, max(2, stem * 0.45), ACCENT)
  grid:disc(x - stem * 0.35, base - stem + stem * 0.25, max(1, stem * 0.3), ACCENT)
end

function FLORA.crystal(grid, x, base, growth, seed)
  local height = max(3, floor(growth * 0.5) + floor(hash(seed, 42) * 3))
  for row = 0, height do
    local taper = max(0, floor((1 - abs(row / height * 2 - 1)) * height * 0.24))
    grid:hline(x - taper, x + taper, base - row, ACCENT)
  end
end

--- Scatters a biome's flora across the ground. Positions come from a hash, so
--- the same trees stand in the same places every frame.
local function paintFlora(grid, w, growth, profile, groundAt, anim)
  local painter = FLORA[profile.flora]
  if not painter or growth < 5 then return end

  local count = max(1, floor(w / 14 * (profile.density or 1)))
  for i = 1, count do
    local x = floor(hash(i, 41) * (w - 4)) + 2
    local base = groundAt and groundAt(x) or nil
    if base then
      painter(grid, x, floor(base), growth, i, anim, profile)
    end
  end
end

-- ------------------------------------------------------------ dimensions ---

local function paintNether(grid, w, h, anim, scene)
  local profile = scene and scene.ground or biomes.PROFILES.netherWastes
  grid:ditherGradient(1, h, { SKY_HIGH, SKY_MID, SKY_LOW })

  -- Netherrack ceiling with stalactites, in the darkest tone so it separates
  -- from the red haze behind it.
  local ceiling = max(2, floor(h * 0.22))
  for x = 1, w do
    local t = x / w
    local drip = sin(t * 9.1) * 0.4 + sin(t * 21.3 + 2.1) * 0.25
    grid:vline(x, 1, ceiling + drip * ceiling, LAND_SHADE)
  end
  grid:hline(1, w, 1, LAND)

  -- Lava sea: a hot surface line over a cooler body, with a slow swell.
  local surface = floor(h * 0.74)
  for x = 1, w do
    local wave = sin(x * 0.28 + anim * 1.6) * 0.9 + sin(x * 0.11 - anim * 0.9) * 0.6
    grid:vline(x, surface + wave, h, GLOW)
    grid:vline(x, surface + wave, surface + wave + 1, BODY)
  end
  for i = 1, max(4, floor(w / 6)) do
    local x = (hash(i, 31) * w + anim * (2 + hash(i, 32) * 3)) % w
    grid:set(x, surface + 2 + hash(i, 33) * (h - surface - 2), BODY)
  end

  -- Whatever grows on the shore of it. Crimson and warped forests are the
  -- only real scenery the Nether has.
  local growth = max(0, surface - ceiling)
  if h >= 12 and w >= 20 then
    paintFlora(grid, w, growth * 0.6, profile,
      function() return surface end, anim)
  end

  -- Ash motes drifting upward.
  for i = 1, max(8, floor(w / 3)) do
    local sx, sy = hash(i, 51), hash(i, 52)
    local x = sx * w + sin(anim * 0.7 + i) * 2
    local y = h - ((sy * h + anim * (3 + sy * 4)) % (h - ceiling))
    grid:set(x, y, hash(i, 53) > 0.5 and BODY or CLOUD)
  end
end

local function paintEnd(grid, w, h, anim, scene)
  grid:ditherGradient(1, h, { SKY_HIGH, SKY_MID, SKY_LOW })
  stars(grid, w, h, anim, max(14, floor(w * h / 26)), BODY, GLOW)

  -- A floating island: end stone on top, tapering to a dark root. The top is
  -- deliberately not BODY, which the stars own; a near-white slab across the
  -- middle of the frame reads as a stray line rather than terrain.
  local cx, top = floor(w / 2), floor(h * 0.54)
  local halfWidth = max(4, floor(w * 0.30))
  local depth = max(3, floor(h * 0.26))
  for row = 0, depth do
    local taper = floor(halfWidth * (1 - (row / (depth + 1)) ^ 1.6))
    if taper > 0 then
      grid:hline(cx - taper, cx + taper, top + row,
        row < 2 and GLOW or (row < 4 and CLOUD or (row < depth * 0.6 and LAND or LAND_SHADE)))
    end
  end

  -- An obsidian pillar with a lit crystal, so the scene is unmistakably the End.
  local pillarWidth = max(1, floor(w * 0.025))
  local pillarHeight = max(4, floor(h * 0.22))
  grid:rect(cx - pillarWidth, top - pillarHeight, pillarWidth * 2 + 1, pillarHeight, LAND_SHADE)
  grid:disc(cx, top - pillarHeight, max(1, pillarWidth), BODY)

  -- Chorus-purple shards along the rim of the island.
  if h >= 12 and w >= 20 then
    local profile = scene and scene.ground or biomes.PROFILES.theEnd
    paintFlora(grid, w, depth, profile, function(x)
      if x > cx - halfWidth * 0.8 and x < cx + halfWidth * 0.8 then return top end
      return nil
    end, anim)
  end

  -- Endermen-purple haze drifting over the void.
  for i = 1, max(5, floor(w / 8)) do
    local x = (hash(i, 81) * (w + 20) + anim * (1 + hash(i, 82) * 2)) % (w + 20) - 10
    grid:disc(x, h * 0.82 + sin(anim * 0.5 + i) * 2, 2 + hash(i, 83) * 2, CLOUD_SHADE)
  end
end

--- Underground there is no sky to paint: the whole frame is rock, with a
--- chamber cut out of the middle of it.
local function paintCavern(grid, w, h, profile, anim, roomy)
  grid:rect(1, 1, w, h, LAND_SHADE)

  local ceiling = max(1, floor(h * 0.26))
  local floorY = h - max(1, floor(h * 0.26))

  for x = 1, w do
    local drip = sin(x * 0.29) * 0.45 + sin(x * 0.13 + 2.1) * 0.3 + sin(x * 0.71 + 1.1) * 0.2
    grid:vline(x, 1, ceiling + drip * ceiling, LAND)
  end
  for x = 1, w do
    local bump = sin(x * 0.23 + 1.4) * 0.4 + sin(x * 0.61 + 0.3) * 0.25
    grid:vline(x, floorY - bump * max(1, h - floorY), h, LAND)
  end

  if roomy then
    paintFlora(grid, w, max(0, floorY - ceiling), profile,
      function(x)
        local drip = sin(x * 0.29) * 0.45 + sin(x * 0.13 + 2.1) * 0.3
        return ceiling + drip * ceiling
      end, anim)
  end

  -- Motes of light in the dark, so the chamber is not a flat silhouette.
  for i = 1, max(5, floor(w / 5)) do
    local x = hash(i, 101) * w
    local y = ceiling + hash(i, 102) * max(1, floorY - ceiling)
    if hash(i, floor(anim * 1.5) % 89) > 0.55 then grid:set(x, y, ACCENT) end
  end
end

-- ------------------------------------------------------------------ main ---

-- Grounds that change the shape of the frame itself rather than just the
-- silhouette at the bottom of it.
local ENCLOSED = { cavern = true }     -- no sky at all
-- Sky all the way down, no horizon: the ground, where there is any, hangs in it.
local OPEN_SKY = {
  void = true, archipelago = true, cloudSea = true, airship = true, spires = true,
}

--- Paints a complete scene into a pixel grid.
---@param grid table radar.pixel grid, already sized and given scene.palette
---@param scene table Descriptor from radar.environment.describe
---@param anim number Free-running seconds, drives all motion
function sky.paint(grid, scene, anim)
  anim = anim or 0
  local w, h = grid.w, grid.h

  if scene.kind == "nether" then return paintNether(grid, w, h, anim, scene) end
  if scene.kind == "the_end" then return paintEnd(grid, w, h, anim, scene) end

  local profile = scene.ground or biomes.PROFILES[biomes.DEFAULT]
  local shape = profile.terrain

  -- Tiny surfaces get the palette and the celestial body only; anything more
  -- turns to mush below about four character rows.
  local roomy = h >= 12 and w >= 20

  if ENCLOSED[shape] then
    return paintCavern(grid, w, h, profile, anim, roomy)
  end

  -- Sky above, ground below. Between them the two together must cover every
  -- pixel: the cell compiler reads all six sub-pixels of every cell, and an
  -- unpainted one has no palette index at all.
  local openSky = OPEN_SKY[shape] == true
  local horizon = openSky and h or max(2, floor(h * 0.72))
  grid:ditherGradient(1, horizon, { SKY_HIGH, SKY_MID, SKY_LOW })
  if not openSky and h > horizon then grid:rect(1, horizon + 1, w, h - horizon, LAND) end

  -- Stars belong to the night. At dusk the palette's bright entries are warm
  -- orange, so a star field there reads as drifting embers rather than sky.
  if scene.weather == "clear" and scene.phase == "night" then
    stars(grid, w, horizon, anim, max(10, floor(w * horizon / 30)), BODY, GLOW)
  end

  -- Overcast skies are filled from the top; fair-weather cloud sits low, out
  -- of the sun's way.
  if roomy then
    if scene.weather == "storm" then
      clouds(grid, w, horizon, anim, 3, max(3, floor(w / 12)), 5, 0.10, 0.50)
    elseif scene.weather == "rain" then
      clouds(grid, w, horizon, anim, 3, max(3, floor(w / 14)), 2, 0.12, 0.48)
    elseif scene.weather == "snow" then
      clouds(grid, w, horizon, anim, 2, max(2, floor(w / 18)), 8, 0.18, 0.45)
    elseif scene.phase ~= "night" then
      clouds(grid, w, horizon, anim, 2, max(1, floor(w / 30)), 1, 0.52, 0.26)
    end
  end

  -- Sun or moon last, riding the arc its real time of day puts it on. Drawing
  -- it over the fair-weather cloud keeps it unmistakable: a sun half behind a
  -- cloud looks exactly like a crescent moon at this resolution.
  if scene.body == "sun" or scene.body == "moon" then
    local u = util.clamp(scene.bodyProgress or 0.5, 0, 1)
    local r = util.clamp(min(w, h) * 0.11, 2, 9)
    local margin = max(3, w * 0.1)
    local cx = util.lerp(margin, w - margin, u)
    -- The arc has to top out low enough that the halo still fits on screen,
    -- or the sun and moon lose their top edge every noon and midnight.
    local peak = min(horizon - 1, max(r * 1.9, h * 0.10))
    local cy = horizon - sin(pi * u) * (horizon - peak)
    if scene.body == "sun" then
      sun(grid, cx, cy, r)
    else
      moon(grid, cx, cy, r, scene.moonPhase or 0)
    end
  end

  -- The ground, whatever shape this biome makes it.
  local painter = TERRAIN[shape] or TERRAIN.hills
  local groundAt, foreground = painter(grid, w, h, horizon, profile, anim)

  -- Open sky has no horizon to measure a tree against, so island plants get a
  -- height budget from the frame instead.
  local growth = openSky and max(3, floor(h * 0.16)) or (h - horizon)
  if roomy then paintFlora(grid, w, growth, profile, groundAt, anim) end
  if foreground then foreground() end

  if scene.weather == "rain" then
    rain(grid, w, h, horizon, anim, max(10, floor(w * 0.9)), BODY)
  elseif scene.weather == "storm" then
    local struck = lightning(grid, w, horizon, anim)
    rain(grid, w, h, horizon, anim, max(14, floor(w * 1.4)), struck and LAND or BODY)
  elseif scene.weather == "snow" then
    snowfall(grid, w, h, horizon, anim, max(12, floor(w * 1.1)), BODY)
  end
end

--- Short uppercase word for headers and tab strips.
function sky.badge(scene)
  if not scene then return "----" end
  if scene.kind == "nether" then return "NETHER" end
  if scene.kind == "the_end" then return "END" end
  if scene.weather == "storm" then return "STORM" end
  if scene.weather == "rain" then return "RAIN" end
  if scene.weather == "snow" then return "SNOW" end
  local byPhase = { dawn = "DAWN", day = "CLEAR", dusk = "DUSK", night = "NIGHT" }
  return byPhase[scene.phase] or "CLEAR"
end

sky.TERRAIN, sky.FLORA = TERRAIN, FLORA

return sky
