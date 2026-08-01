-- Colour palette for the whole station.
--
-- Basalt keeps a registry of custom RGB colours and assigns them to the 16
-- hardware palette slots of each terminal, per frame, based on what is
-- actually on screen. Anything past 16 falls back to the nearest slot that IS
-- on screen, so there is a budget to respect:
--
--   chrome (9)  available to every page
--   sky    (9)  only on the weather page
--
-- The weather page paints its sky palette plus the neutral chrome entries
-- only, so no single page exceeds sixteen live colours. Check that before
-- adding colours to a view.
--
-- On a non-advanced computer or monitor there is no setPaletteColor and
-- Basalt maps every custom colour to the closest of the sixteen defaults.
-- Everything still renders, just flatter.

local basalt = require("basalt")
local biomes = require("radar.biomes")

local theme = {}

--- Registers a colour and returns a "tone": the Basalt colour handle plus the
--- perceived luminance, which the sub-pixel grid needs to decide which two of
--- a cell's six colours survive into the cell's foreground/background pair.
---@param hex string "#RRGGBB"
---@return table tone { c = colour handle, l = luminance 0..1 }
local function tone(hex)
  local n = tonumber(hex:sub(2), 16)
  local r = math.floor(n / 65536) % 256 / 255
  local g = math.floor(n / 256) % 256 / 255
  local b = n % 256 / 255
  return { c = basalt.rgb(hex), l = 0.2126 * r + 0.7152 * g + 0.0722 * b }
end

theme.tone = tone

-- ---------------------------------------------------------------- chrome ---

theme.tones = {
  bg     = tone("#0a0d13"), -- page background
  panel  = tone("#161c27"), -- raised card
  line   = tone("#2a3444"), -- rules, range rings, inactive chrome
  text   = tone("#d3dcea"), -- primary text
  dim    = tone("#6b7a93"), -- secondary text
  accent = tone("#46d6c8"), -- brand, active tab, radar sweep
  alarm  = tone("#ff5265"), -- close contact, errors
  warn   = tone("#ffb454"), -- medium contact, warnings
  good   = tone("#7ee787"), -- healthy state
}

-- Flat handles, for assigning straight to Basalt element properties.
for name, t in pairs(theme.tones) do theme[name] = t.c end

-- Contact bands, nearest first. The labels also appear in the log.
theme.zones = {
  { max = 50,        label = "CLOSE",   tone = theme.tones.alarm },
  { max = 150,       label = "MEDIUM",  tone = theme.tones.warn },
  { max = 300,       label = "FAR",     tone = theme.tones.accent },
  { max = math.huge, label = "EXTREME", tone = theme.tones.dim },
}

--- Band label and colour handle for a horizontal distance.
function theme.zoneFor(dist)
  for _, z in ipairs(theme.zones) do
    if dist <= z.max then return z.label, z.tone.c, z.tone end
  end
  return "EXTREME", theme.dim, theme.tones.dim
end

-- --------------------------------------------------------------- scenery ---
-- Every sky palette holds exactly ten tones in the same order, so the scene
-- painter can index them positionally:
--
--   1 skyHigh   2 skyMid   3 skyLow   4 body   5 glow
--   6 cloud     7 cloudShade          8 land   9 landShade   10 ground accent
--
-- "body" is the sun or moon disc, "glow" its halo (and the shadowed side of a
-- waning moon). "land" and "landShade" are the horizon silhouette, and the
-- accent is whatever that particular ground needs a third colour for: leaves
-- on a forest, water on a coast, glow on a cave.
--
-- Slots 8, 9 and 10 are the only ones a biome may replace. Everything above
-- them belongs to the sky and stays put whatever you are standing in, which is
-- what keeps a biome from costing any extra palette slots.

local function sky(...)
  local out = {}
  for i, hex in ipairs({ ... }) do out[i] = tone(hex) end
  return out
end

theme.skies = {
  -- overworld, clear, by phase
  dawn  = sky("#2a3f6b", "#7b5f8c", "#f2a25c", "#ffe9b0", "#ff9d5c",
              "#f7c9a8", "#b47f86", "#241f33", "#151327", "#3a5c33"),
  day   = sky("#3f7fd4", "#63a4e8", "#a8d4f2", "#fff4c9", "#ffd978",
              "#ffffff", "#c2d4e8", "#2f4a2c", "#1c2e1c", "#3f7a33"),
  dusk  = sky("#1e2a52", "#5c3f75", "#e8724f", "#ffd9a0", "#ff7a45",
              "#e8a48f", "#8f5a6b", "#1f1c2e", "#121022", "#33502c"),
  night = sky("#070b1c", "#101838", "#1d2a52", "#e8eefc", "#8fa8d8",
              "#2a3454", "#161d33", "#0d1020", "#070912", "#16301a"),

  -- weather replaces the clear sky wholesale
  rain  = sky("#2b3440", "#3d4753", "#586470", "#8fa0b0", "#6b7887",
              "#5b6773", "#3f4a56", "#232b28", "#161c1a", "#2c4a2a"),
  storm = sky("#14181f", "#1f262f", "#2c3540", "#c9d4e3", "#7a8798",
              "#39434f", "#242c36", "#161b19", "#0d100f", "#20351f"),
  snow  = sky("#5b6b80", "#7b8b9e", "#a8b6c4", "#f2f6fb", "#c9d6e3",
              "#cfd9e3", "#a3b0bd", "#dfe7ef", "#b6c2ce", "#8fa2b5"),

  -- night-time weather is darker than its daytime counterpart
  rainNight  = sky("#111722", "#1a2130", "#252e3f", "#5b6b80", "#3d4757",
                   "#2b3442", "#1c232e", "#101519", "#0a0d0f", "#182c18"),
  snowNight  = sky("#161d2e", "#222b41", "#333e57", "#dae3f2", "#8e9cb5",
                   "#3b465e", "#2a3346", "#93a1b5", "#6b7688", "#59677a"),

  -- other dimensions ignore time of day entirely
  nether = sky("#2b0d0d", "#571a12", "#8c2f14", "#ffb054", "#ff6a2b",
               "#6b2416", "#3d130d", "#2a1410", "#160a08", "#ff6a2b"),
  theEnd = sky("#0b0714", "#150d24", "#221338", "#e0d7f2", "#8a6fb8",
               "#2a1c42", "#180f28", "#161022", "#0b0714", "#c9a8f0"),
}

-- ---------------------------------------------------------- ground colours ---
-- A biome's three ground tones are derived from hex, so they cannot come out
-- of a fixed table the way the skies do. Building them costs a colour
-- registration each, and the same handful of combinations come back every
-- frame, so the results are cached: at most one entry per biome per mood, and
-- in practice one or two for the whole session.

local groundCache = {}

--- Land, shade and accent tones for a biome profile under a lighting mood.
---@param kind string A radar.biomes profile id
---@param mood string A radar.biomes mood id
---@return table land
---@return table shade
---@return table accent
function theme.groundTones(kind, mood)
  local key = kind .. "/" .. mood
  local hit = groundCache[key]
  if not hit then
    local land, shade, accent = biomes.groundColors(kind, mood)
    hit = { tone(land), tone(shade), tone(accent) }
    groundCache[key] = hit
  end
  return hit[1], hit[2], hit[3]
end

-- Merged sky-plus-ground palettes are cached the same way, keyed off the base
-- palette table so two skies never share one another's ground.
local paletteCache = setmetatable({}, { __mode = "k" })

--- A complete ten-tone scene palette: a sky, with a biome's ground under it.
---@param base table One of theme.skies
---@param kind string A radar.biomes profile id
---@param mood string A radar.biomes mood id
---@return table palette
function theme.scenePalette(base, kind, mood)
  local perBase = paletteCache[base]
  if not perBase then perBase = {}; paletteCache[base] = perBase end

  local key = kind .. "/" .. mood
  local hit = perBase[key]
  if not hit then
    hit = { base[1], base[2], base[3], base[4], base[5], base[6], base[7] }
    hit[8], hit[9], hit[10] = theme.groundTones(kind, mood)
    perBase[key] = hit
  end
  return hit
end

return theme
