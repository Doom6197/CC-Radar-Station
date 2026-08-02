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

local biomes = require("radar.biomes")

-- Required on first use rather than up top: radar.config validates backdrop
-- ids while loading settings, and must not drag Basalt in through the theme
-- to do it.
local theme

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

  -- The other dimensions, which on a pack like this are islands too.
  { id = "netherSea",   label = "Over the Lava Sea",   hint = "the Nether, from above",
    sky = "nether", ground = "netherWastes", kind = "nether",  phase = "day" },
  { id = "endVoid",     label = "The Far End",         hint = "an island in the void",
    sky = "theEnd", ground = "theEnd",       kind = "the_end", phase = "night" },
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

--- Backdrops in the cycle, in list order. `backdropSkip` holds the ones left
--- OUT, so a picture added in a later version joins the cycle by default
--- rather than silently going missing from it. Never returns an empty list:
--- a cycle with nothing in it would leave the page with nothing to draw.
function backdrops.rotation(cfg)
  local skip = type(cfg.backdropSkip) == "table" and cfg.backdropSkip or {}
  local out = {}
  for _, entry in ipairs(backdrops.LIST) do
    if not skip[entry.id] then out[#out + 1] = entry.id end
  end
  if #out == 0 then return { backdrops.LIST[1].id } end
  return out
end

--- Builds a scene in exactly the shape radar.environment.describe produces, so
--- radar.sky paints it without knowing where it came from.
---@param id string A backdrop id
---@param snap table|nil The live snapshot; only the moon phase is borrowed
---@return table|nil scene
function backdrops.scene(id, snap)
  local entry = byId[id]
  if not entry then return nil end
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
