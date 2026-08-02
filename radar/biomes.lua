-- Biome identification, and the ground profile each biome paints with.
--
-- The weather page used to draw one horizon: two green ridges and a row of
-- conifers, whatever the detector said you were standing in. A profile splits
-- that into three independent choices --
--
--   terrain   the silhouette of the ground itself
--   flora     what grows on it
--   colours   land, its shadow, and one accent
--
-- -- so a modded biome that only matches on "snowy" still gets snow-covered
-- ground under whatever trees its name suggests, and a biome nobody has ever
-- heard of lands on plains rather than on nothing at all.
--
-- This module is deliberately free of Basalt and of the peripheral API: it is
-- data, string matching and hex arithmetic. radar.theme turns the hex strings
-- into palette tones, radar.sky does the drawing.

local biomes = {}

-- --------------------------------------------------------------- profiles ---
-- `land` is the lit surface, `shade` the ground in shadow, and `accent` one
-- extra colour whose meaning depends on the terrain: foliage on anything that
-- grows, water on anything wet, glow on anything underground.
--
-- Colours are written as they look at midday. Everything else -- dusk, night,
-- rain, lying snow -- is derived from these by `biomes.shade`, so a biome is
-- one line rather than one line per hour of the day.

biomes.PROFILES = {
  plains = { label = "Plains",
    terrain = "hills", flora = "broadleaf", density = 0.35,
    land = "#57893c", shade = "#33532a", accent = "#3f7a33" },

  meadow = { label = "Meadow",
    terrain = "hills", flora = "broadleaf", density = 0.2,
    land = "#6ea347", shade = "#42702f", accent = "#93c24e" },

  forest = { label = "Forest",
    terrain = "hills", flora = "broadleaf", density = 1.0,
    land = "#3f6f33", shade = "#23431f", accent = "#2f6b2a" },

  birch = { label = "Birch Forest",
    terrain = "hills", flora = "birch", density = 0.9,
    land = "#6a9a4a", shade = "#3d6330", accent = "#8fbf5c" },

  darkForest = { label = "Dark Forest",
    terrain = "hills", flora = "broadleaf", density = 1.4,
    land = "#2c4a26", shade = "#172a14", accent = "#1e3a1a" },

  taiga = { label = "Taiga",
    terrain = "hills", flora = "conifer", density = 1.0,
    land = "#3e6647", shade = "#223b28", accent = "#2a5240" },

  snowyForest = { label = "Snowy Taiga", cold = true,
    terrain = "hills", flora = "conifer", density = 0.9,
    land = "#dfe9f2", shade = "#a9bacb", accent = "#2c4a3c" },

  snowy = { label = "Snowy Plains", cold = true,
    terrain = "flat", flora = "deadTree", density = 0.6,
    land = "#e4edf5", shade = "#b2c2d1", accent = "#5f7186" },

  iceSpikes = { label = "Ice Spikes", cold = true,
    terrain = "flat", flora = "iceSpike", density = 0.8,
    land = "#dbe8f5", shade = "#9fb8d0", accent = "#a8d8ee" },

  snowyPeaks = { label = "Snowy Peaks", cold = true,
    terrain = "peaks", flora = "none", density = 0,
    land = "#d8e4f0", shade = "#6d7f95", accent = "#b9cbdd" },

  peaks = { label = "Mountains",
    terrain = "peaks", flora = "conifer", density = 0.4,
    land = "#7a7d85", shade = "#45484f", accent = "#4c6b3c" },

  desert = { label = "Desert", dry = true,
    terrain = "dunes", flora = "cactus", density = 1.1,
    land = "#dcc07a", shade = "#a98c4d", accent = "#4f8a45" },

  badlands = { label = "Badlands", dry = true,
    terrain = "plateau", flora = "none", density = 0,
    land = "#b9663a", shade = "#6f3a20", accent = "#c9954a" },

  savanna = { label = "Savanna", dry = true,
    terrain = "flat", flora = "acacia", density = 0.5,
    land = "#a89b4e", shade = "#6d6330", accent = "#7d8a3c" },

  jungle = { label = "Jungle",
    terrain = "hills", flora = "broadleaf", density = 1.8,
    land = "#2f6b2c", shade = "#17401a", accent = "#2b8034" },

  bamboo = { label = "Bamboo Jungle",
    terrain = "hills", flora = "bamboo", density = 1.6,
    land = "#4b7a35", shade = "#2a4a20", accent = "#86b23f" },

  cherry = { label = "Cherry Grove",
    terrain = "hills", flora = "broadleaf", density = 0.9,
    land = "#6d9a48", shade = "#3f6630", accent = "#f0a8c8" },

  swamp = { label = "Swamp",
    terrain = "swamp", flora = "deadTree", density = 0.7,
    land = "#445a34", shade = "#26331f", accent = "#1f4436" },

  mangrove = { label = "Mangrove Swamp",
    terrain = "swamp", flora = "broadleaf", density = 1.1,
    land = "#4a5c30", shade = "#29341c", accent = "#3a5a48" },

  mushroom = { label = "Mushroom Fields",
    terrain = "hills", flora = "mushroom", density = 1.0,
    land = "#8f7f9a", shade = "#55475f", accent = "#d05a5a" },

  ocean = { label = "Ocean",
    terrain = "ocean", flora = "none", density = 0,
    land = "#1f4f7a", shade = "#123454", accent = "#7fd0e8" },

  frozenOcean = { label = "Frozen Ocean", cold = true,
    terrain = "ocean", flora = "iceSpike", density = 0.3,
    land = "#7fa8c4", shade = "#4d7c9c", accent = "#dff0fa" },

  river = { label = "River",
    terrain = "shore", flora = "broadleaf", density = 1.0,
    land = "#57893c", shade = "#33532a", accent = "#2f7ea8" },

  shore = { label = "Beach",
    terrain = "shore", flora = "palm", density = 1.2,
    land = "#ddc98d", shade = "#b09a5f", accent = "#2f7ea8" },

  lushCaves = { label = "Lush Caves", dry = true,
    terrain = "cavern", flora = "glowVine", density = 1.0,
    land = "#3d5a2f", shade = "#1f2f18", accent = "#e8b84a" },

  dripstone = { label = "Dripstone Caves", dry = true,
    terrain = "cavern", flora = "none", density = 0,
    land = "#7a6a5c", shade = "#453a32", accent = "#9d8a76" },

  deepDark = { label = "Deep Dark", dry = true,
    terrain = "cavern", flora = "glowVine", density = 0.6,
    land = "#2a3038", shade = "#14181d", accent = "#22b0a0" },

  caves = { label = "Caves", dry = true,
    terrain = "cavern", flora = "none", density = 0,
    land = "#5a5a5e", shade = "#303034", accent = "#6e6e74" },

  volcanic = { label = "Volcanic", dry = true,
    terrain = "peaks", flora = "deadTree", density = 0.3,
    land = "#4a3a34", shade = "#24191a", accent = "#ff7a2b" },

  -- The pack this was tuned against drops you on an airship over nothing at
  -- all, so open sky is a first-class scene rather than an error case.
  void = { label = "Floating Islands",
    terrain = "void", flora = "broadleaf", density = 0.8,
    land = "#8a7a66", shade = "#4a4034", accent = "#57a03c" },

  -- Open air. No rule below resolves to any of these: they are here to be
  -- chosen rather than detected, which is what lets radar.backdrops put a
  -- picture on the weather page that owes nothing to the biome underfoot.
  skyIsles = { label = "Sky Archipelago",
    terrain = "archipelago", flora = "broadleaf", density = 0.7,
    land = "#8a7a66", shade = "#463c30", accent = "#5fa83f" },

  cloudSea = { label = "Cloud Sea", dry = true,
    terrain = "cloudSea", flora = "none", density = 0,
    land = "#8c8579", shade = "#4e4a44", accent = "#b9b2a4" },

  skyship = { label = "Airship", dry = true,
    terrain = "airship", flora = "none", density = 0,
    land = "#d8c9a8", shade = "#4a3a2c", accent = "#c2533f" },

  spires = { label = "Stone Spires", dry = true,
    terrain = "spires", flora = "none", density = 0,
    land = "#8d8377", shade = "#4b443d", accent = "#6fae4a" },

  -- Other dimensions. These never reach the overworld painters; their terrain
  -- ids exist so nothing can accidentally treat them as ground.
  netherWastes = { label = "Nether Wastes", dry = true,
    terrain = "nether", flora = "none", density = 0,
    land = "#8c2f14", shade = "#3d130d", accent = "#ff6a2b" },

  crimsonForest = { label = "Crimson Forest", dry = true,
    terrain = "nether", flora = "fungus", density = 1.2,
    land = "#7a1f22", shade = "#360d12", accent = "#c33d3d" },

  warpedForest = { label = "Warped Forest", dry = true,
    terrain = "nether", flora = "fungus", density = 1.2,
    land = "#1d5a5c", shade = "#0c2a2e", accent = "#2ec4b0" },

  soulValley = { label = "Soul Sand Valley", dry = true,
    terrain = "nether", flora = "deadTree", density = 0.6,
    land = "#5a4a3c", shade = "#241c18", accent = "#3fd0e0" },

  basaltDeltas = { label = "Basalt Deltas", dry = true,
    terrain = "nether", flora = "none", density = 0,
    land = "#4a4348", shade = "#1e1a1e", accent = "#ff8a3c" },

  theEnd = { label = "The End", dry = true,
    terrain = "end", flora = "crystal", density = 0.6,
    land = "#c8bf92", shade = "#4a4260", accent = "#c9a8f0" },
}

-- The picker shows these in this order; anything left out of the list is still
-- reachable by name but sinks to the bottom.
biomes.ORDER = {
  "plains", "meadow", "forest", "birch", "darkForest", "taiga", "cherry",
  "jungle", "bamboo", "mushroom", "savanna", "desert", "badlands", "volcanic",
  "peaks", "snowyPeaks", "snowyForest", "snowy", "iceSpikes",
  "swamp", "mangrove", "river", "shore", "ocean", "frozenOcean",
  "lushCaves", "dripstone", "deepDark", "caves",
  "void", "skyIsles", "cloudSea", "skyship", "spires",
  "netherWastes", "crimsonForest", "warpedForest", "soulValley",
  "basaltDeltas", "theEnd",
}

-- ------------------------------------------------------------- classifying ---
-- Ordered, first match wins, plain substring against the lowercased biome id.
-- Specific names have to come before the general ones they contain, which is
-- why this is an array and not a table.
--
-- A needle written "=name" instead matches the biome path exactly. That is for
-- short words which are a biome in their own right but also turn up inside
-- unrelated ones -- "grove" is its own snowy biome, and it is also the back
-- half of both cherry_grove and mangrove_swamp.

biomes.RULES = {
  -- cold, and the peaks that are usually cold with it
  { "ice_spikes",         "iceSpikes" },
  { "frozen_peaks",       "snowyPeaks" },
  { "jagged_peaks",       "snowyPeaks" },
  { "snowy_slopes",       "snowyPeaks" },
  { "snowy_taiga",        "snowyForest" },
  { "snowy_beach",        "snowy" },
  { "frozen_ocean",       "frozenOcean" },
  { "frozen_river",       "frozenOcean" },
  { "glacier",            "iceSpikes" },
  { "=grove",             "snowyForest" },
  { "tundra",             "snowy" },
  { "snowy",              "snowy" },
  { "frozen",             "snowy" },
  { "arctic",             "snowy" },
  { "alps",               "snowyPeaks" },

  -- height
  { "stony_peaks",        "peaks" },
  { "windswept_savanna",  "savanna" },
  { "windswept",          "peaks" },
  { "mountain",           "peaks" },
  { "highland",           "peaks" },
  { "crag",               "peaks" },
  { "cliff",              "peaks" },
  { "peak",               "peaks" },

  -- hot and dry
  { "basalt_deltas",      "basaltDeltas" },
  { "volcan",             "volcanic" },
  { "ashen",              "volcanic" },
  { "scorched",           "volcanic" },
  { "badlands",           "badlands" },
  { "mesa",               "badlands" },
  { "wasteland",          "badlands" },
  { "savanna",            "savanna" },
  { "desert",             "desert" },
  { "dune",               "desert" },
  { "oasis",              "desert" },
  { "sandy",              "desert" },

  -- wet
  { "mangrove",           "mangrove" },
  { "swamp",              "swamp" },
  { "marsh",              "swamp" },
  { "bayou",              "swamp" },
  { "wetland",            "swamp" },
  { "bog",                "swamp" },
  { "fen",                "swamp" },
  { "stony_shore",        "shore" },
  { "beach",              "shore" },
  { "shore",              "shore" },
  { "coast",              "shore" },
  { "ocean",              "ocean" },
  { "coral",              "ocean" },
  { "reef",               "ocean" },
  { "river",              "river" },
  { "lake",               "river" },

  -- trees
  { "cherry",             "cherry" },
  { "bamboo",             "bamboo" },
  { "jungle",             "jungle" },
  { "rainforest",         "jungle" },
  { "dark_forest",        "darkForest" },
  { "birch",              "birch" },
  { "old_growth",         "taiga" },
  { "taiga",              "taiga" },
  { "redwood",            "taiga" },
  { "conifer",            "taiga" },
  { "spruce",             "taiga" },
  { "pine",               "taiga" },
  { "boreal",             "taiga" },
  { "forest",             "forest" },
  { "woodland",           "forest" },
  { "wooded",             "forest" },
  { "orchard",            "meadow" },

  -- fungal
  { "crimson",            "crimsonForest" },
  { "warped",             "warpedForest" },
  { "mushroom",           "mushroom" },
  { "mycelium",           "mushroom" },
  { "fungi",              "mushroom" },

  -- underground
  { "deep_dark",          "deepDark" },
  { "sculk",              "deepDark" },
  { "lush_cave",          "lushCaves" },
  { "dripstone",          "dripstone" },
  { "cave",               "caves" },
  { "underground",        "caves" },

  -- nether and end, in case the dimension itself is unreadable
  { "soul_sand",          "soulValley" },
  { "nether",             "netherWastes" },
  { "the_end",            "theEnd" },

  -- open sky
  { "void",               "void" },
  { "sky",                "void" },
  { "aether",             "void" },
  { "skyblock",           "void" },

  -- gentle ground
  { "meadow",             "meadow" },
  { "flower",             "meadow" },
  { "lavender",           "meadow" },
  { "sunflower",          "meadow" },
  { "prairie",            "plains" },
  { "steppe",             "plains" },
  { "grassland",          "plains" },
  { "plains",             "plains" },
}

biomes.DEFAULT = "plains"

local function matches(needle, id, path)
  if needle:sub(1, 1) == "=" then return path == needle:sub(2) end
  return id:find(needle, 1, true) ~= nil
end

--- Ground profile id for a biome, given the dimension it sits in.
---@param biomeId string|nil Raw id, e.g. "minecraft:snowy_taiga"
---@param dimensionKind string|nil "overworld", "nether", "the_end" or "other"
---@return string kind A key of biomes.PROFILES
function biomes.classify(biomeId, dimensionKind)
  local id = tostring(biomeId or ""):lower()
  local path = id:gsub("^.*:", "")

  -- The dimension is the more reliable signal: a Nether biome named by a mod
  -- may not contain "nether" anywhere, but the dimension always says so.
  if dimensionKind == "the_end" then return "theEnd" end
  if dimensionKind == "nether" then
    for _, rule in ipairs(biomes.RULES) do
      local kind = rule[2]
      if biomes.PROFILES[kind].terrain == "nether" and matches(rule[1], id, path) then
        return kind
      end
    end
    return "netherWastes"
  end

  for _, rule in ipairs(biomes.RULES) do
    if matches(rule[1], id, path) then return rule[2] end
  end
  return biomes.DEFAULT
end

function biomes.profile(kind)
  return biomes.PROFILES[kind] or biomes.PROFILES[biomes.DEFAULT]
end

function biomes.label(kind)
  return biomes.profile(kind).label
end

--- Every profile id, in picker order, with any stragglers appended.
function biomes.ids()
  local out, seen = {}, {}
  for _, id in ipairs(biomes.ORDER) do
    if biomes.PROFILES[id] then out[#out + 1] = id; seen[id] = true end
  end
  local rest = {}
  for id in pairs(biomes.PROFILES) do
    if not seen[id] then rest[#rest + 1] = id end
  end
  table.sort(rest)
  for _, id in ipairs(rest) do out[#out + 1] = id end
  return out
end

-- ------------------------------------------------------------------ moods ---
-- One transform per lighting condition, applied to the profile's midday
-- colours. `mix` pulls the colour toward `tint` before `gain` dims it, so the
-- ground picks up the colour of the sky above it as well as losing light.

biomes.MOODS = {
  day       = { gain = 1.00 },
  dawn      = { gain = 0.82, tint = "#ff9d5c", mix = 0.22 },
  dusk      = { gain = 0.76, tint = "#ff7a45", mix = 0.24 },
  night     = { gain = 0.34, tint = "#4a6ab0", mix = 0.30 },
  rain      = { gain = 0.68, tint = "#6b7887", mix = 0.30 },
  rainNight = { gain = 0.28, tint = "#3d4757", mix = 0.36 },
  storm     = { gain = 0.50, tint = "#39434f", mix = 0.36 },
  -- Falling snow settles: the ground goes white whatever it started as.
  snow      = { gain = 0.94, tint = "#e6eef7", mix = 0.62 },
  snowNight = { gain = 0.42, tint = "#8e9cb5", mix = 0.58 },
}

--- Which mood a described scene is lit by.
function biomes.moodFor(scene)
  if not scene then return "day" end
  if scene.weather == "storm" then return "storm" end
  if scene.weather == "snow" then return scene.night and "snowNight" or "snow" end
  if scene.weather == "rain" then return scene.night and "rainNight" or "rain" end
  return biomes.MOODS[scene.phase] and scene.phase or "day"
end

-- ------------------------------------------------------------- hex colours ---

local floor, min, max = math.floor, math.min, math.max

local function toRGB(hex)
  local n = tonumber(tostring(hex):sub(2), 16) or 0
  return floor(n / 65536) % 256, floor(n / 256) % 256, n % 256
end

local function toHex(r, g, b)
  local function byte(v) return min(255, max(0, floor(v + 0.5))) end
  return ("#%02x%02x%02x"):format(byte(r), byte(g), byte(b))
end

biomes.toRGB, biomes.toHex = toRGB, toHex

--- Applies a mood to one of a profile's colours.
---@param hex string "#RRGGBB" as it looks at midday
---@param mood string A key of biomes.MOODS
---@return string hex
function biomes.shade(hex, mood)
  local m = biomes.MOODS[mood] or biomes.MOODS.day
  local r, g, b = toRGB(hex)
  if m.tint and m.mix and m.mix > 0 then
    local tr, tg, tb = toRGB(m.tint)
    r = r + (tr - r) * m.mix
    g = g + (tg - g) * m.mix
    b = b + (tb - b) * m.mix
  end
  local gain = m.gain or 1
  return toHex(r * gain, g * gain, b * gain)
end

--- The three ground colours of a profile under a mood, in palette order:
--- land, its shadow, and the accent.
---@return string land
---@return string shade
---@return string accent
function biomes.groundColors(kind, mood)
  local p = biomes.profile(kind)
  return biomes.shade(p.land, mood),
         biomes.shade(p.shade, mood),
         biomes.shade(p.accent, mood)
end

return biomes
