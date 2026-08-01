-- Procedural sky, weather and horizon painting.
--
-- Rather than shipping a fixed picture per weather type, the scene is drawn
-- from the live snapshot: the sun and moon really do climb and set along the
-- Minecraft day, the moon shows its actual phase, clouds drift, rain slants,
-- lightning strikes, and the palette shifts with the hour. Dawn, noon, dusk,
-- night, rain, snow, thunder, the Nether and the End each look distinct.
--
-- Everything is painted by palette INDEX into a radar.pixel grid, using only
-- the nine entries a sky palette defines:
--
--   1 skyHigh  2 skyMid  3 skyLow  4 body  5 glow
--   6 cloud    7 cloudShade        8 land  9 landShade
--
-- No colour outside that set is used, which is what keeps the weather page
-- inside the sixteen hardware palette slots.

local util = require("radar.util")

local sky = {}

local SKY_HIGH, SKY_MID, SKY_LOW = 1, 2, 3
local BODY, GLOW = 4, 5
local CLOUD, CLOUD_SHADE = 6, 7
local LAND, LAND_SHADE = 8, 9

local floor, sin, cos, pi, sqrt = math.floor, math.sin, math.cos, math.pi, math.sqrt
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

--- Two overlapping ridge lines: a distant one and a darker near one.
--- The ground is laid down as a solid block first: a ridge that happens to dip
--- below the horizon must not leave unpainted pixels behind it.
local function terrain(grid, w, h, horizon)
  local depth = h - horizon
  if depth < 1 then return end
  grid:rect(1, horizon, w, depth + 1, LAND)

  for x = 1, w do
    local t = x / w
    local ridge = sin(t * 5.7) * 0.45 + sin(t * 12.9 + 1.7) * 0.22 + sin(t * 2.1 + 0.6) * 0.33
    grid:vline(x, horizon - ridge * depth * 0.55, h, LAND)
  end
  for x = 1, w do
    local t = x / w
    local ridge = sin(t * 3.1 + 2.2) * 0.55 + sin(t * 8.3 + 0.4) * 0.25
    grid:vline(x, horizon + depth * 0.42 - ridge * depth * 0.3, h, LAND_SHADE)
  end
end

--- Conifer silhouettes along the far ridge. Skipped when there is no room.
local function trees(grid, w, h, horizon)
  local depth = h - horizon
  if depth < 7 then return end
  local count = math.max(2, floor(w / 14))
  for i = 1, count do
    local x = floor(hash(i, 41) * (w - 4)) + 2
    local th = 4 + floor(hash(i, 42) * 3)
    local base = horizon + depth * 0.30
    grid:vline(x, base - 1, base + 1, LAND_SHADE)
    for row = 0, th - 1 do
      local halfWidth = floor((th - row) * 0.6)
      grid:hline(x - halfWidth, x + halfWidth, base - 1 - row, LAND_SHADE)
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
  local step = math.max(3, floor(horizon / 6))
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

-- ------------------------------------------------------------ dimensions ---

local function paintNether(grid, w, h, anim)
  grid:ditherGradient(1, h, { SKY_HIGH, SKY_MID, SKY_LOW })

  -- Netherrack ceiling with stalactites, in the darkest tone so it separates
  -- from the red haze behind it.
  local ceiling = math.max(2, floor(h * 0.22))
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
  for i = 1, math.max(4, floor(w / 6)) do
    local x = (hash(i, 31) * w + anim * (2 + hash(i, 32) * 3)) % w
    grid:set(x, surface + 2 + hash(i, 33) * (h - surface - 2), BODY)
  end

  -- Ash motes drifting upward.
  for i = 1, math.max(8, floor(w / 3)) do
    local sx, sy = hash(i, 51), hash(i, 52)
    local x = sx * w + sin(anim * 0.7 + i) * 2
    local y = h - ((sy * h + anim * (3 + sy * 4)) % (h - ceiling))
    grid:set(x, y, hash(i, 53) > 0.5 and BODY or CLOUD)
  end
end

local function paintEnd(grid, w, h, anim)
  grid:ditherGradient(1, h, { SKY_HIGH, SKY_MID, SKY_LOW })
  stars(grid, w, h, anim, math.max(14, floor(w * h / 26)), BODY, GLOW)

  -- A floating island: end stone on top, tapering to a dark root. The top is
  -- deliberately not BODY, which the stars own; a near-white slab across the
  -- middle of the frame reads as a stray line rather than terrain.
  local cx, top = floor(w / 2), floor(h * 0.54)
  local halfWidth = math.max(4, floor(w * 0.30))
  local depth = math.max(3, floor(h * 0.26))
  for row = 0, depth do
    local taper = floor(halfWidth * (1 - (row / (depth + 1)) ^ 1.6))
    if taper > 0 then
      grid:hline(cx - taper, cx + taper, top + row,
        row < 2 and GLOW or (row < 4 and CLOUD or (row < depth * 0.6 and LAND or LAND_SHADE)))
    end
  end

  -- An obsidian pillar with a lit crystal, so the scene is unmistakably the End.
  local pillarWidth = math.max(1, floor(w * 0.025))
  local pillarHeight = math.max(4, floor(h * 0.22))
  grid:rect(cx - pillarWidth, top - pillarHeight, pillarWidth * 2 + 1, pillarHeight, LAND_SHADE)
  grid:disc(cx, top - pillarHeight, math.max(1, pillarWidth), BODY)

  -- Endermen-purple haze drifting over the void.
  for i = 1, math.max(5, floor(w / 8)) do
    local x = (hash(i, 81) * (w + 20) + anim * (1 + hash(i, 82) * 2)) % (w + 20) - 10
    grid:disc(x, h * 0.82 + sin(anim * 0.5 + i) * 2, 2 + hash(i, 83) * 2, CLOUD_SHADE)
  end
end

-- ------------------------------------------------------------------ main ---

--- Paints a complete scene into a pixel grid.
---@param grid table radar.pixel grid, already sized and given scene.palette
---@param scene table Descriptor from radar.environment.describe
---@param anim number Free-running seconds, drives all motion
function sky.paint(grid, scene, anim)
  anim = anim or 0
  local w, h = grid.w, grid.h

  if scene.kind == "nether" then return paintNether(grid, w, h, anim) end
  if scene.kind == "the_end" then return paintEnd(grid, w, h, anim) end

  -- Sky above, ground below. Between them the two together must cover every
  -- pixel: the cell compiler reads all six sub-pixels of every cell, and an
  -- unpainted one has no palette index at all.
  local horizon = math.max(2, floor(h * 0.72))
  grid:ditherGradient(1, horizon, { SKY_HIGH, SKY_MID, SKY_LOW })
  if h > horizon then grid:rect(1, horizon + 1, w, h - horizon, LAND) end

  -- Tiny surfaces get the palette and the celestial body only; anything more
  -- turns to mush below about four character rows.
  local roomy = h >= 12 and w >= 20

  -- Stars belong to the night. At dusk the palette's bright entries are warm
  -- orange, so a star field there reads as drifting embers rather than sky.
  if scene.weather == "clear" and scene.phase == "night" then
    stars(grid, w, horizon, anim, math.max(10, floor(w * horizon / 30)), BODY, GLOW)
  end

  -- Overcast skies are filled from the top; fair-weather cloud sits low, out
  -- of the sun's way.
  if roomy then
    if scene.weather == "storm" then
      clouds(grid, w, horizon, anim, 3, math.max(3, floor(w / 12)), 5, 0.10, 0.50)
    elseif scene.weather == "rain" then
      clouds(grid, w, horizon, anim, 3, math.max(3, floor(w / 14)), 2, 0.12, 0.48)
    elseif scene.weather == "snow" then
      clouds(grid, w, horizon, anim, 2, math.max(2, floor(w / 18)), 8, 0.18, 0.45)
    elseif scene.phase ~= "night" then
      clouds(grid, w, horizon, anim, 2, math.max(1, floor(w / 30)), 1, 0.52, 0.26)
    end
  end

  -- Sun or moon last, riding the arc its real time of day puts it on. Drawing
  -- it over the fair-weather cloud keeps it unmistakable: a sun half behind a
  -- cloud looks exactly like a crescent moon at this resolution.
  if scene.body == "sun" or scene.body == "moon" then
    local u = util.clamp(scene.bodyProgress or 0.5, 0, 1)
    local r = util.clamp(math.min(w, h) * 0.11, 2, 9)
    local margin = math.max(3, w * 0.1)
    local cx = util.lerp(margin, w - margin, u)
    -- The arc has to top out low enough that the halo still fits on screen,
    -- or the sun and moon lose their top edge every noon and midnight.
    local peak = math.min(horizon - 1, math.max(r * 1.9, h * 0.10))
    local cy = horizon - sin(pi * u) * (horizon - peak)
    if scene.body == "sun" then
      sun(grid, cx, cy, r)
    else
      moon(grid, cx, cy, r, scene.moonPhase or 0)
    end
  end

  terrain(grid, w, h, horizon)
  if roomy then trees(grid, w, h, horizon) end

  if scene.weather == "rain" then
    rain(grid, w, h, horizon, anim, math.max(10, floor(w * 0.9)), BODY)
  elseif scene.weather == "storm" then
    local struck = lightning(grid, w, horizon, anim)
    rain(grid, w, h, horizon, anim, math.max(14, floor(w * 1.4)), struck and LAND or BODY)
  elseif scene.weather == "snow" then
    snowfall(grid, w, h, horizon, anim, math.max(12, floor(w * 1.1)), BODY)
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

return sky
