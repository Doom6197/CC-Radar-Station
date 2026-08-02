-- Backdrops: pictures for the weather page that owe nothing to the weather.
--
-- The weather page normally draws what the Environment Detector reports: the
-- real hour, the real sky, the biome underfoot. On a pack where every
-- dimension is floating islands and you live on an airship that is often
-- either wrong or missing entirely -- a contraption is not made of world
-- blocks, so a detector riding on one has nothing to report at all.
--
-- A backdrop is a whole scene chosen by hand: a sky palette, a ground, a fixed
-- hour. It is assembled from exactly the pieces the live scene is built from
-- (radar.theme skies, radar.biomes grounds, radar.sky painters), so it costs
-- no extra palette slots and adds no second drawing path.
--
-- Only the PICTURE is replaced. The readout beneath it, the badge in the
-- header and the status page all keep reporting what the detector actually
-- says, so a decorative sky never misrepresents the real one.

-- A backdrop has two halves, and they can be chosen separately: the PLACE
-- (which ground, and therefore which painter) and the SKY (the hour, the
-- weather, where the sun is). Keep the place and let the sky run live and you
-- get an airship that flies through the real dusk and the real rain.

local biomes = require("radar.biomes")

-- Both required on first use rather than up top: radar.config validates
-- backdrop ids while loading settings, and must not drag Basalt in through
-- the theme to do it.
local theme, environment

local backdrops = {}

-- `sky` names a radar.theme.skies palette and `ground` a radar.biomes profile.
-- `phase` and `weather` are what radar.sky branches on. `at` is where the sun
-- or moon sits on its arc: 0 at the eastern horizon, 1 at the western.
backdrops.LIST = {
  -- The islands themselves, right round a day.
  { id = "islesDawn",   label = "Isles at Dawn",       hint = "sunrise over the archipelago",
    sky = "dawn",  ground = "skyIsles", phase = "dawn",  body = "sun",  at = 0.10 },
  { id = "islesNoon",   label = "Isles at Noon",       hint = "high sun, fair weather",
    sky = "day",   ground = "skyIsles", phase = "day",   body = "sun",  at = 0.50 },
  { id = "islesDusk",   label = "Isles at Sunset",     hint = "the long light",
    sky = "dusk",  ground = "skyIsles", phase = "dusk",  body = "sun",  at = 0.90 },
  { id = "islesNight",  label = "Moonlit Isles",       hint = "a clear night over open air",
    sky = "night", ground = "skyIsles", phase = "night", body = "moon", at = 0.45 },
  { id = "islesStorm",  label = "Storm over the Isles", hint = "thunder in the archipelago",
    sky = "storm", ground = "skyIsles", phase = "day",   weather = "storm" },
  { id = "islesSnow",   label = "Snow over the Isles", hint = "falling snow, open air",
    sky = "snow",  ground = "skyIsles", phase = "day",   weather = "snow" },

  -- Above the weather.
  { id = "cloudDawn",   label = "Cloud Sea at Dawn",   hint = "peaks breaking the deck",
    sky = "dawn",  ground = "cloudSea", phase = "dawn",  body = "sun",  at = 0.14 },
  { id = "cloudDay",    label = "Above the Clouds",    hint = "level flight in clear air",
    sky = "day",   ground = "cloudSea", phase = "day",   body = "sun",  at = 0.55 },
  { id = "cloudDusk",   label = "Cloud Sea at Dusk",   hint = "the deck turning gold",
    sky = "dusk",  ground = "cloudSea", phase = "dusk",  body = "sun",  at = 0.88 },
  { id = "cloudNight",  label = "Cloud Sea by Night",  hint = "moonlight on the deck",
    sky = "night", ground = "cloudSea", phase = "night", body = "moon", at = 0.50 },

  -- Under way.
  { id = "shipDay",     label = "Airship, Fair Weather", hint = "under way in clear air",
    sky = "day",   ground = "skyship",  phase = "day",   body = "sun",  at = 0.40 },
  { id = "shipDusk",    label = "Airship at Sunset",   hint = "running for home",
    sky = "dusk",  ground = "skyship",  phase = "dusk",  body = "sun",  at = 0.86 },
  { id = "shipNight",   label = "Airship by Moonlight", hint = "a night passage",
    sky = "night", ground = "skyship",  phase = "night", body = "moon", at = 0.55 },
  { id = "shipRain",    label = "Airship in the Rain", hint = "a wet passage",
    sky = "rain",  ground = "skyship",  phase = "day",   weather = "rain" },
  { id = "shipStorm",   label = "Airship in a Storm",  hint = "weather on the beam",
    sky = "storm", ground = "skyship",  phase = "day",   weather = "storm" },

  -- Landmarks.
  { id = "spiresDay",   label = "Stone Spires",        hint = "towers standing in haze",
    sky = "day",   ground = "spires",   phase = "day",   body = "sun",  at = 0.62 },
  { id = "spiresDusk",  label = "Spires at Dusk",      hint = "last light on the towers",
    sky = "dusk",  ground = "spires",   phase = "dusk",  body = "sun",  at = 0.92 },
  { id = "spiresNight", label = "Spires by Night",     hint = "the towers after dark",
    sky = "night", ground = "spires",   phase = "night", body = "moon", at = 0.40 },

  -- The other dimensions, which on a pack like this are islands too. These are
  -- places rather than weathers -- there is no overworld dusk over the lava
  -- sea -- so they are drawn as authored even when the sky is set to live.
  { id = "netherSea",   label = "Over the Lava Sea",   hint = "the Nether, from above",
    sky = "nether", ground = "netherWastes", kind = "nether",  phase = "day",
    fixedSky = true },
  { id = "endVoid",     label = "The Far End",         hint = "an island in the void",
    sky = "theEnd", ground = "theEnd",       kind = "the_end", phase = "night",
    fixedSky = true },
}

local byId = {}
for _, entry in ipairs(backdrops.LIST) do byId[entry.id] = entry end

function backdrops.byId(id) return byId[id] end

function backdrops.label(id)
  local entry = byId[id]
  return entry and entry.label or tostring(id)
end

--- Every backdrop id, in the order the picker shows them.
function backdrops.ids()
  local out = {}
  for i, entry in ipairs(backdrops.LIST) do out[i] = entry.id end
  return out
end

function backdrops.count() return #backdrops.LIST end

--- Whether this configuration draws its backdrops under the real sky.
function backdrops.isLiveSky(cfg)
  return cfg.backdropSky == "live"
end

--- Backdrops in the cycle, in list order. `backdropSkip` holds the ones left
--- OUT, so a picture added in a later version joins the cycle by default
--- rather than silently going missing from it. Never returns an empty list:
--- a cycle with nothing in it would leave the page with nothing to draw.
---
--- Under a live sky the six presets that share the archipelago differ only in
--- the hour they were drawn at -- and the hour is coming from the detector --
--- so the cycle walks distinct PLACES instead, rather than showing the same
--- picture six times running.
function backdrops.rotation(cfg)
  local skip = type(cfg.backdropSkip) == "table" and cfg.backdropSkip or {}
  local live = backdrops.isLiveSky(cfg)
  local out, seenGround = {}, {}

  for _, entry in ipairs(backdrops.LIST) do
    local duplicate = live and not entry.fixedSky and seenGround[entry.ground]
    if not skip[entry.id] and not duplicate then
      out[#out + 1] = entry.id
      seenGround[entry.ground] = true
    end
  end

  if #out == 0 then return { backdrops.LIST[1].id } end
  return out
end

--- Builds a scene in exactly the shape radar.environment.describe produces, so
--- radar.sky paints it without knowing where it came from.
---
--- With `liveSky` the picture keeps only its ground and the rest of the scene
--- is the real one -- the hour, the weather, where the sun is, the dimension.
--- That is the same path the live weather page takes with its scenery forced,
--- so an airship under a live sky is lit exactly as the ground beneath it
--- would have been. With no detector to ask there is no live sky to use, so
--- the picture falls back to the hour it was drawn with rather than to
--- nothing -- which is what keeps it working on a ship.
---@param id string A backdrop id
---@param snap table|nil The live snapshot
---@param liveSky? boolean Take the sky from `snap` instead of from the picture
---@return table|nil scene
function backdrops.scene(id, snap, liveSky)
  local entry = byId[id]
  if not entry then return nil end

  if liveSky and not entry.fixedSky and snap and snap.available then
    environment = environment or require("radar.environment")
    -- The picture says what to draw; the biome you are actually in says
    -- whether it can rain and whether that falls as snow. An airship is not a
    -- climate, so taking those flags from the picture would show rain over a
    -- snowfield -- and nothing at all over a desert.
    local realGround = biomes.profile(biomes.classify(snap.biome, snap.kind))
    local scene = environment.describe(snap, entry.ground, realGround)
    scene.backdrop = id
    scene.backdropLive = true
    -- describe() names the weather in the title; the subtitle is where the
    -- chosen picture gets to say which place this is.
    scene.subtitle = biomes.label(entry.ground)
    return scene
  end

  theme = theme or require("radar.theme")

  local scene = {
    backdrop = id,
    kind = entry.kind or "overworld",
    phase = entry.phase or "day",
    tick = entry.tick or 6000,
    body = entry.body or "none",
    bodyProgress = entry.at or 0.5,
    -- The real moon phase is a free detail whenever there is a detector to
    -- ask; with none, a full moon is the one that reads at any size.
    moonPhase = (snap and snap.available and snap.moonId) or 0,
    night = (entry.phase == "night"),
    weather = entry.weather or "clear",
    title = entry.label,
    subtitle = entry.hint,
  }

  scene.groundKind = entry.ground
  scene.ground = biomes.profile(entry.ground)
  scene.groundLabel = scene.ground.label
  scene.groundForced = true
  scene.mood = biomes.moodFor(scene)
  scene.palette = theme.scenePalette(
    theme.skies[entry.sky] or theme.skies.day, scene.groundKind, scene.mood)
  return scene
end

return backdrops
