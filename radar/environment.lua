-- Environment Detector polling, and the scene description derived from it.
--
-- Every Advanced Peripherals call runs on the server main thread, so each one
-- costs a yield. Time and weather move constantly and are read on every poll;
-- biome, dimension and moon phase barely move at all and are read on a slower
-- cadence. The result is a single flat snapshot table plus a `scene` table
-- that the sky painter consumes without knowing anything about peripherals.

local util  = require("radar.util")
local theme = require("radar.theme")

local environment = {}
environment.__index = environment

local DAY = 24000

-- Blocks where precipitation falls as snow rather than rain.
local COLD_BIOME = {
  "snowy", "frozen", "ice_spikes", "grove", "jagged_peaks", "frozen_peaks",
}
-- Blocks where it never visibly precipitates at all, however wet the world is.
local DRY_BIOME = {
  "desert", "badlands", "savanna", "mesa", "nether", "basalt_deltas",
  "crimson_forest", "warped_forest", "soul_sand_valley",
}

local function matchesAny(text, list)
  if not text then return false end
  for _, needle in ipairs(list) do
    if text:find(needle, 1, true) then return true end
  end
  return false
end

--- "minecraft:the_nether" -> "nether"
local function dimensionKind(id)
  if not id then return "unknown" end
  local path = id:gsub("^.*:", "")
  if path == "overworld" then return "overworld" end
  if path == "the_nether" or path:find("nether", 1, true) then return "nether" end
  if path == "the_end" or path:find("end", 1, true) then return "the_end" end
  return "other"
end

environment.dimensionKind = dimensionKind

-- ------------------------------------------------------------------ time ---

--- Minecraft clock from a day-time tick. Tick 0 is 06:00.
function environment.clockOf(tick)
  local hour = math.floor(tick / 1000 + 6) % 24
  local minute = math.floor((tick % 1000) * 0.06)
  return string.format("%02d:%02d", hour, minute), hour, minute
end

function environment.phaseOf(tick)
  if tick >= 23000 or tick < 1000 then return "dawn" end
  if tick < 11000 then return "day" end
  if tick < 13500 then return "dusk" end
  return "night"
end

--- Which body is in the sky and how far across its arc it has travelled.
---@return string body "sun", "moon" or "none"
---@return number progress 0 at the eastern horizon, 1 at the western one
function environment.celestial(tick)
  if tick >= 12500 and tick < 23000 then
    return "moon", (tick - 12500) / 10500
  end
  if tick >= 23000 then return "sun", (tick - 23000) / 13500 end
  return "sun", (tick + 1000) / 13500
end

environment.MOON_NAMES = {
  [0] = "Full Moon", [1] = "Waning Gibbous", [2] = "Last Quarter",
  [3] = "Waning Crescent", [4] = "New Moon", [5] = "Waxing Crescent",
  [6] = "First Quarter", [7] = "Waxing Gibbous",
}

--- Illuminated fraction (0..1) and which limb is lit, for a Minecraft phase.
function environment.moonShape(phase)
  local fractions = { [0] = 1, 0.75, 0.5, 0.25, 0, 0.25, 0.5, 0.75 }
  return fractions[phase] or 1, (phase >= 5 or phase == 0)
end

-- ---------------------------------------------------------------- polling ---

function environment.new()
  return setmetatable({
    snapshot = { available = false },
    _slowAt = -math.huge,
    _slow = {},
  }, environment)
end

local function call(dev, method, ...)
  local ok, value = pcall(dev[method], ...)
  if ok then return value end
  return nil
end

--- Reads the detector and rebuilds the snapshot.
---@param kit table Hardware kit from radar.hardware
---@param cfg table Settings
---@param force? boolean Refresh the slow-moving fields too
function environment:poll(kit, cfg, force)
  local dev = kit.env
  if not dev or not cfg.env then
    self.snapshot = { available = false, reason = dev and "disabled" or "no detector" }
    return self.snapshot
  end

  local snap = { available = true }

  local raw = call(dev, "getTime")
  if type(raw) ~= "number" then
    self.snapshot = { available = false, reason = "detector error" }
    return self.snapshot
  end

  snap.rawTime = raw
  snap.tick = math.floor(raw % DAY)
  snap.day = math.floor(raw / DAY)
  snap.clock, snap.hour, snap.minute = environment.clockOf(snap.tick)
  snap.phase = environment.phaseOf(snap.tick)
  snap.body, snap.bodyProgress = environment.celestial(snap.tick)

  snap.raining = call(dev, "isRaining") == true
  snap.thundering = call(dev, "isThunder") == true

  local now = os.clock()
  if force or (now - self._slowAt) >= 10 then
    self._slowAt = now
    local slow = {}
    slow.biome = call(dev, "getBiome")
    slow.dimension = call(dev, "getDimension")
    slow.moonId = call(dev, "getMoonId")
    slow.skyLight = call(dev, "getSkyLightLevel")
    slow.blockLight = call(dev, "getBlockLightLevel")
    slow.dayLight = call(dev, "getDayLightLevel")
    slow.slimeChunk = call(dev, "isSlimeChunk") == true
    self._slow = slow
  end
  for k, v in pairs(self._slow) do snap[k] = v end

  snap.biomeName = util.prettyId(snap.biome)
  snap.dimensionName = util.prettyId(snap.dimension)
  snap.kind = dimensionKind(snap.dimension)
  snap.moonName = environment.MOON_NAMES[snap.moonId or 0] or "Unknown"

  snap.scene = environment.describe(snap)
  self.snapshot = snap
  return snap
end

-- ----------------------------------------------------------------- scenes ---

--- Turns a snapshot into everything the sky painter needs: which palette to
--- use, what is falling out of the sky, and where the sun or moon sits.
function environment.describe(snap)
  local scene = {
    kind = snap.kind,
    phase = snap.phase,
    tick = snap.tick,
    body = snap.body,
    bodyProgress = snap.bodyProgress,
    moonPhase = snap.moonId or 0,
    night = (snap.phase == "night"),
  }

  if snap.kind == "nether" then
    scene.weather = "clear"
    scene.palette = theme.skies.nether
    scene.body = "none"
    scene.title = "The Nether"
    scene.subtitle = "Ash and firelight"
    return scene
  end

  if snap.kind == "the_end" then
    scene.weather = "clear"
    scene.palette = theme.skies.theEnd
    scene.body = "none"
    scene.title = "The End"
    scene.subtitle = "Void sky"
    return scene
  end

  local dry = matchesAny(snap.biome, DRY_BIOME)
  local cold = matchesAny(snap.biome, COLD_BIOME)

  if snap.thundering and not dry then
    scene.weather = "storm"
    scene.palette = theme.skies.storm
    scene.body = "none"
    scene.title = "Thunderstorm"
  elseif snap.raining and not dry then
    if cold then
      scene.weather = "snow"
      scene.palette = scene.night and theme.skies.snowNight or theme.skies.snow
      scene.title = "Snowfall"
    else
      scene.weather = "rain"
      scene.palette = scene.night and theme.skies.rainNight or theme.skies.rain
      scene.title = "Rain"
    end
    scene.body = "none"
  else
    scene.weather = "clear"
    scene.palette = theme.skies[snap.phase] or theme.skies.day
    local titles = {
      dawn = "Sunrise", day = "Clear Skies",
      dusk = "Sunset", night = "Clear Night",
    }
    scene.title = titles[snap.phase] or "Clear"
    if snap.raining and dry then
      scene.subtitle = "Raining elsewhere; this biome stays dry"
    end
  end

  if not scene.subtitle then
    if scene.body == "moon" then
      scene.subtitle = snap.moonName
    else
      local phases = {
        dawn = "Early morning", day = "Daytime",
        dusk = "Evening", night = "After dark",
      }
      scene.subtitle = phases[snap.phase] or ""
    end
  end

  return scene
end

--- One-line summary for compact displays.
function environment.headline(snap)
  if not snap or not snap.available then return "environment offline" end
  local scene = snap.scene or {}
  return string.format("%s  %s  D%d", snap.clock or "--:--",
    scene.title or "?", snap.day or 0)
end

return environment
