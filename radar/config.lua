-- Settings, detection log and ignore list: load, sanitise, save.
--
-- Files live next to the program. Settings from Radar Station v3 (and from
-- the older pocket version it grew out of) are imported on first run, so an
-- existing station keeps its base coordinates, ignore list and history.

local util      = require("radar.util")
local biomes    = require("radar.biomes")
local backdrops = require("radar.backdrops")

local config = {}

config.VERSION = "6.1"

config.FILES = {
  cfg    = "radar.cfg",
  log    = "radar_log.cfg",
  ignore = "radar_ignore.cfg",
}

-- Read once, only when the v4 file is missing.
config.LEGACY = {
  cfg    = { "pocket_radar.cfg" },
  log    = { "pocket_radar_log.cfg" },
  ignore = { "pocket_radar_ignore.cfg" },
}

config.MAX_LOG_ENTRIES = 250

-- Station names ride on every announcement, so they are kept short.
config.MAX_STATION_NAME = 24

config.RANGES = {
  { value = 25,     label = "25" },
  { value = 50,     label = "50" },
  { value = 100,    label = "100" },
  { value = 250,    label = "250" },
  { value = 500,    label = "500" },
  { value = 1000,   label = "1k" },
  { value = 2500,   label = "2.5k" },
  { value = 5000,   label = "5k" },
  { value = 10000,  label = "10k" },
  { value = 100000, label = "MAX" },
}
config.MAX_RANGE_INDEX = #config.RANGES

config.SCAN_INTERVALS = { 0.5, 1, 2, 3, 5 }

-- Page ids a display can show. "settings" is deliberately absent: it is
-- reachable from the terminal only, since monitors have no keyboard.
config.PAGES = { "radar", "contacts", "weather", "log", "status" }

-- ------------------------------------------------------------ orientation ---
-- FIXED keeps a chosen bearing at the top of the scope for a monitor bolted to
-- a wall. HEADING unlocks it and turns the picture with the operator, which is
-- what you want on anything that moves.

config.ORIENTATIONS = {
  { id = "fixed",   label = "Locked",   hint = "a chosen bearing stays at the top" },
  { id = "heading", label = "Unlocked", hint = "the scope turns with you" },
}

config.HEADING_STEPS = {
  { value = 0,  label = "Smooth - free rotation" },
  { value = 5,  label = "5 deg steps" },
  { value = 15, label = "15 deg steps" },
  { value = 45, label = "45 deg steps - 8 point compass" },
  { value = 90, label = "90 deg steps - quarter turns" },
}

config.HEADING_INTERVALS = { 0.25, 0.5, 1, 2 }

-- ------------------------------------------------------------------- roles ---
-- A ship assembled by Create: Aeronautics is a contraption, not world blocks,
-- so getPlayersInRange() aboard one comes back empty. getPlayerPos(name) is an
-- entity lookup and keeps working, so a station on the ground can see the
-- pilot wherever they fly. BASE detects and relays; SHIP only draws.

config.ROLES = {
  { id = "station", label = "STATION", hint = "stands alone, no network" },
  { id = "base",    label = "BASE",    hint = "scans, and relays to a ship" },
  { id = "ship",    label = "SHIP",    hint = "draws what a base relays" },
}

-- How long a monitor rests on a page before the rotation moves it along.
config.CYCLE_INTERVALS = { 5, 10, 15, 20, 30, 45, 60, 120, 300 }

-- How long the weather page holds a backdrop before changing to the next. Kept
-- separate from CYCLE_INTERVALS, and slower at the top end: a picture you are
-- looking at wants longer than a page you are glancing at.
config.BACKDROP_INTERVALS = { 10, 15, 30, 60, 120, 300, 600, 900, 1800 }

-- A backdrop is a place plus a sky, and the two are chosen separately: keep
-- the place and let the sky run live, and the picture follows the real hour
-- and the real weather.
config.BACKDROP_SKIES = {
  { id = "picture", label = "From the picture",
    hint = "the hour and weather it was drawn with" },
  { id = "live",    label = "Live",
    hint = "the real hour, weather and sun" },
}

config.RS_MODES = {
  { id = "pulse",  label = "Pulse",  hint = "brief blip on each new contact" },
  { id = "hold",   label = "Hold",   hint = "on while anyone is in range" },
  { id = "analog", label = "Analog", hint = "strength 1-15 by how close" },
}

config.RS_PULSE_OPTIONS = { 0.2, 0.5, 1, 2, 5, 10 }

-- Vanilla 1.21 sound event ids, passed straight to speaker.playSound().
config.SOUNDS = {
  { id = "minecraft:block.note_block.pling",        label = "Note: Pling" },
  { id = "minecraft:block.note_block.bell",         label = "Note: Bell" },
  { id = "minecraft:block.note_block.harp",         label = "Note: Harp" },
  { id = "minecraft:block.note_block.bass",         label = "Note: Bass" },
  { id = "minecraft:block.note_block.didgeridoo",   label = "Note: Didgeridoo" },
  { id = "minecraft:block.bell.use",                label = "Bell Ring" },
  { id = "minecraft:block.beacon.activate",         label = "Beacon Hum" },
  { id = "minecraft:block.conduit.activate",        label = "Conduit" },
  { id = "minecraft:block.anvil.land",              label = "Anvil Clang" },
  { id = "minecraft:block.lever.click",             label = "Lever Click" },
  { id = "minecraft:block.dispenser.fail",          label = "Dispenser Fail" },
  { id = "minecraft:block.portal.trigger",          label = "Portal Whoosh" },
  { id = "minecraft:ui.button.click",               label = "UI Click" },
  { id = "minecraft:entity.experience_orb.pickup",  label = "XP Pickup" },
  { id = "minecraft:entity.player.levelup",         label = "Level Up" },
  { id = "minecraft:entity.arrow.hit_player",       label = "Arrow Hit" },
  { id = "minecraft:entity.creeper.primed",         label = "Creeper Hiss" },
  { id = "minecraft:entity.villager.no",            label = "Villager No" },
  { id = "minecraft:entity.villager.yes",           label = "Villager Yes" },
  { id = "minecraft:entity.wither.spawn",           label = "Wither Spawn" },
  { id = "minecraft:entity.ender_dragon.growl",     label = "Dragon Growl" },
  { id = "minecraft:entity.elder_guardian.curse",   label = "Elder Curse" },
  { id = "minecraft:entity.warden.nearby_closest",  label = "Warden Heartbeat" },
  { id = "minecraft:entity.evoker.prepare_attack",  label = "Evoker Chant" },
  { id = "minecraft:entity.lightning_bolt.thunder", label = "Thunder" },
  { id = "minecraft:item.trident.thunder",          label = "Trident Thunder" },
  { id = "minecraft:entity.ghast.warn",             label = "Ghast Scream" },
  { id = "minecraft:music_disc.pigstep",            label = "Disc: Pigstep" },
}

-- ------------------------------------------------------------------- i/o ---

local function loadTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local raw = h.readAll()
  h.close()
  local ok, data = pcall(textutils.unserialize, raw)
  if ok and type(data) == "table" then return data end
  return nil
end

local function saveTable(path, data)
  local h = fs.open(path, "w")
  if not h then return false end
  h.write(textutils.serialize(data))
  h.close()
  return true
end

config.loadTable = loadTable
config.saveTable = saveTable

--- Loads path, falling back to the legacy names in order.
---@return table|nil data
---@return boolean imported True when the data came from a legacy file
local function loadWithLegacy(path, legacy)
  local data = loadTable(path)
  if data then return data, false end
  for _, old in ipairs(legacy or {}) do
    data = loadTable(old)
    if data then return data, true end
  end
  return nil, false
end

-- --------------------------------------------------------------- defaults ---

--- Name this station announces itself under, before the operator picks one.
function config.defaultStationName()
  local id = (os.getComputerID and os.getComputerID()) or 0
  return "Base " .. tostring(id)
end

function config.defaults()
  return {
    version = config.VERSION,

    role          = "station",         -- see config.ROLES
    stationName   = nil,               -- filled in by sanitise
    relayWeather  = false,             -- a base also relays the environment
    pairedBaseId  = nil,               -- the one base a ship listens to
    pairedBaseName = nil,              -- its friendly name, for the UI

    myName = nil,
    mode   = "fixed",                    -- "fixed" measures from baseX/Y/Z
    baseX = nil, baseY = nil, baseZ = nil, baseDim = nil,

    rangeIndex      = config.MAX_RANGE_INDEX,
    alertRangeIndex = config.MAX_RANGE_INDEX,
    scanIndex       = 2,                 -- SCAN_INTERVALS[2] = 1 second

    orientation     = "fixed",           -- "fixed" or "heading"
    rotation        = 0,                 -- bearing at the top while fixed
    headingStep     = 0,                 -- snap the heading; 0 = free rotation
    headingSeconds  = 0.5,               -- how often the yaw is re-read
    headingSmooth   = true,              -- ease into a turn instead of jumping

    alert     = true,                    -- master alert switch
    flash     = true,                    -- flash every screen red
    toast     = true,                    -- pop a banner on the terminal
    dimFilter = true,                    -- hide players in other dimensions

    env        = true,                   -- poll the environment detector
    envSeconds = 2,                      -- how often, in seconds
    animate    = true,                   -- animate the sky and radar sweep
    biomeScene = "auto",                 -- weather-page scenery, or a forced one

    -- The weather page's picture. "live" draws the real sky, "cycle" walks the
    -- chosen set on a timer, anything else is one radar.backdrops id.
    backdrop        = "live",
    backdropSky     = "picture",         -- or "live": follow the real sky
    backdropSeconds = 60,
    backdropSkip    = {},                -- backdrops left OUT of the cycle

    terminalPage = "status",
    tapCycle     = true,                 -- tapping a monitor moves it on a page

    sound = {
      enabled = true,
      index   = 2,                       -- Note: Bell
      volume  = 2.0,
      pitch   = 1.0,
      repeats = 2,
    },

    rs = {
      enabled    = false,
      side       = "back",
      mode       = "pulse",
      pulse      = 1,
      rangeIndex = config.MAX_RANGE_INDEX,
      invert     = false,
    },

    displays = {},                       -- [peripheralName] = displayDefaults()
  }
end

--- Per-monitor settings. `cycleSkip` holds the pages left OUT of the automatic
--- rotation, so a page added in a later version joins the rotation by default
--- rather than silently disappearing from it.
function config.displayDefaults()
  return {
    page         = "radar",
    scale        = 0.5,
    cycle        = false,
    cycleSeconds = 15,
    cycleSkip    = {},
  }
end

--- Pages a display rotates through, in PAGES order. Never returns an empty
--- list: a rotation that excluded everything would strand the monitor.
function config.cyclePages(entry)
  local skip = type(entry) == "table" and entry.cycleSkip or {}
  local pages = {}
  for _, page in ipairs(config.PAGES) do
    if not skip[page] then pages[#pages + 1] = page end
  end
  if #pages == 0 then return { config.PAGES[1] } end
  return pages
end

-- -------------------------------------------------------------- sanitising ---

local clamp = util.clamp

local function indexOfId(list, id)
  for i, entry in ipairs(list) do
    if entry.id == id or entry == id then return i end
  end
  return nil
end

--- Nearest legal entry of a { value = , label = } list.
local function snapToValue(list, value, fallback)
  value = tonumber(value)
  if not value then return fallback end
  local best, bestGap = fallback, math.huge
  for _, entry in ipairs(list) do
    local gap = math.abs(entry.value - value)
    if gap < bestGap then best, bestGap = entry.value, gap end
  end
  return best
end

--- Nearest legal entry of a plain array of numbers.
local function snapToNumber(list, value, fallback)
  value = tonumber(value)
  if not value then return fallback end
  local best, bestGap = fallback, math.huge
  for _, entry in ipairs(list) do
    local gap = math.abs(entry - value)
    if gap < bestGap then best, bestGap = entry, gap end
  end
  return best
end

--- Fills in missing keys and forces every value back into a legal range, so a
--- hand-edited or half-written file can never crash a draw call.
function config.sanitise(cfg)
  local d = config.defaults()

  for k, v in pairs(d) do
    if cfg[k] == nil then
      cfg[k] = v
    elseif type(v) == "table" and type(cfg[k]) ~= "table" then
      cfg[k] = v
    elseif type(v) == "table" then
      for k2, v2 in pairs(v) do
        if cfg[k][k2] == nil then cfg[k][k2] = v2 end
      end
    end
  end

  cfg.rangeIndex      = clamp(math.floor(tonumber(cfg.rangeIndex) or config.MAX_RANGE_INDEX), 1, #config.RANGES)
  cfg.alertRangeIndex = clamp(math.floor(tonumber(cfg.alertRangeIndex) or config.MAX_RANGE_INDEX), 1, #config.RANGES)
  cfg.scanIndex       = clamp(math.floor(tonumber(cfg.scanIndex) or 2), 1, #config.SCAN_INTERVALS)
  cfg.rotation        = math.floor(tonumber(cfg.rotation) or 0) % 360
  cfg.envSeconds      = clamp(tonumber(cfg.envSeconds) or 2, 1, 30)

  if not indexOfId(config.ORIENTATIONS, cfg.orientation) then cfg.orientation = "fixed" end
  cfg.headingStep    = snapToValue(config.HEADING_STEPS, cfg.headingStep, 0)
  cfg.headingSeconds = snapToNumber(config.HEADING_INTERVALS, cfg.headingSeconds, 0.5)

  cfg.sound.index   = clamp(math.floor(tonumber(cfg.sound.index) or 1), 1, #config.SOUNDS)
  cfg.sound.volume  = clamp(tonumber(cfg.sound.volume) or 2, 0, 3)
  cfg.sound.pitch   = clamp(tonumber(cfg.sound.pitch) or 1, 0.5, 2)
  cfg.sound.repeats = clamp(math.floor(tonumber(cfg.sound.repeats) or 1), 1, 5)

  cfg.rs.rangeIndex = clamp(math.floor(tonumber(cfg.rs.rangeIndex) or config.MAX_RANGE_INDEX), 1, #config.RANGES)
  cfg.rs.pulse      = tonumber(cfg.rs.pulse) or 1
  if not indexOfId(config.RS_MODES, cfg.rs.mode) then cfg.rs.mode = "pulse" end
  if type(cfg.rs.side) ~= "string" then cfg.rs.side = "back" end

  if cfg.mode ~= "self" and cfg.mode ~= "fixed" then cfg.mode = "fixed" end
  if type(cfg.myName) ~= "string" or #cfg.myName == 0 then cfg.myName = nil end

  -- A settings file written before v5 has no role at all, and must come out of
  -- here as a plain stand-alone station with nothing networked turned on.
  if not indexOfId(config.ROLES, cfg.role) then cfg.role = "station" end
  if type(cfg.stationName) ~= "string" or #cfg.stationName == 0 then
    cfg.stationName = config.defaultStationName()
  end
  cfg.stationName = cfg.stationName:sub(1, config.MAX_STATION_NAME)
  cfg.relayWeather = cfg.relayWeather == true
  local paired = tonumber(cfg.pairedBaseId)
  cfg.pairedBaseId = paired and math.floor(paired) or nil
  if type(cfg.pairedBaseName) ~= "string" or #cfg.pairedBaseName == 0 then
    cfg.pairedBaseName = nil
  end

  if not config.isPage(cfg.terminalPage) then cfg.terminalPage = "status" end
  cfg.tapCycle = cfg.tapCycle ~= false

  if cfg.biomeScene ~= "auto" and not biomes.PROFILES[cfg.biomeScene] then
    cfg.biomeScene = "auto"
  end

  -- A settings file written before v6 has no backdrop at all, and must come
  -- out of here drawing the live sky exactly as it did.
  if cfg.backdrop ~= "live" and cfg.backdrop ~= "cycle"
     and not backdrops.byId(cfg.backdrop) then
    cfg.backdrop = "live"
  end
  cfg.backdropSeconds = snapToNumber(config.BACKDROP_INTERVALS, cfg.backdropSeconds, 60)
  if not indexOfId(config.BACKDROP_SKIES, cfg.backdropSky) then
    cfg.backdropSky = "picture"
  end

  -- Only real backdrop ids may sit in the skip set, and it may never cover
  -- every picture: a cycle with nothing in it would leave the page blank.
  local skipped, keptPictures = {}, 0
  if type(cfg.backdropSkip) == "table" then
    for id, on in pairs(cfg.backdropSkip) do
      if on and backdrops.byId(id) then skipped[id] = true end
    end
  end
  for _, id in ipairs(backdrops.ids()) do
    if not skipped[id] then keptPictures = keptPictures + 1 end
  end
  cfg.backdropSkip = keptPictures > 0 and skipped or {}

  if type(cfg.displays) ~= "table" then cfg.displays = {} end
  for name, entry in pairs(cfg.displays) do
    if type(entry) ~= "table" then
      cfg.displays[name] = config.displayDefaults()
    else
      for key, value in pairs(config.displayDefaults()) do
        if entry[key] == nil then entry[key] = value end
      end
      if not config.isPage(entry.page) then entry.page = "radar" end
      entry.scale = clamp(tonumber(entry.scale) or 0.5, 0.5, 5)
      entry.cycle = entry.cycle == true
      entry.cycleSeconds = snapToNumber(config.CYCLE_INTERVALS, entry.cycleSeconds, 15)

      -- Only real page ids may sit in the skip set, and it may never cover
      -- every page: a rotation with nothing in it would freeze the monitor.
      local skip = {}
      if type(entry.cycleSkip) == "table" then
        for page, on in pairs(entry.cycleSkip) do
          if on and config.isPage(page) then skip[page] = true end
        end
      end
      local kept = 0
      for _, page in ipairs(config.PAGES) do
        if not skip[page] then kept = kept + 1 end
      end
      entry.cycleSkip = kept > 0 and skip or {}
    end
  end

  cfg.version = config.VERSION
  return cfg
end

function config.isPage(id)
  for _, page in ipairs(config.PAGES) do
    if page == id then return true end
  end
  return false
end

-- --------------------------------------------------------------- migration ---

-- v3 stored a display style index into { radar, grid, list, log, status }.
local V3_STYLE_TO_PAGE = { "radar", "radar", "contacts", "log", "status" }

local function migrate(cfg)
  if cfg.termStyleIndex and not config.isPage(cfg.terminalPage) then
    cfg.terminalPage = V3_STYLE_TO_PAGE[tonumber(cfg.termStyleIndex) or 5] or "status"
  end
  -- The pocket build called it styleIndex.
  if cfg.styleIndex and not cfg.terminalPage then
    cfg.terminalPage = V3_STYLE_TO_PAGE[tonumber(cfg.styleIndex) or 1] or "radar"
  end
  cfg.termStyleIndex, cfg.styleIndex = nil, nil

  if type(cfg.displays) == "table" then
    for _, entry in pairs(cfg.displays) do
      if type(entry) == "table" and entry.styleIndex and not entry.page then
        entry.page = V3_STYLE_TO_PAGE[tonumber(entry.styleIndex) or 1] or "radar"
        entry.styleIndex = nil
      end
    end
  end
  return cfg
end

-- ------------------------------------------------------------------- api ---

--- Loads settings, log and ignore list, importing older files when needed.
---@return table cfg
---@return table log
---@return table ignore
---@return boolean imported
function config.load()
  local raw, importedCfg = loadWithLegacy(config.FILES.cfg, config.LEGACY.cfg)
  -- Settings written by v3 carry no version field; anything from a legacy
  -- filename obviously predates v4 too.
  local upgraded = raw ~= nil and raw.version ~= config.VERSION
  local cfg = config.sanitise(migrate(raw or config.defaults()))

  local logData, importedLog = loadWithLegacy(config.FILES.log, config.LEGACY.log)
  local ignore, importedIgnore = loadWithLegacy(config.FILES.ignore, config.LEGACY.ignore)

  local imported = importedCfg or importedLog or importedIgnore or upgraded
  return cfg, logData or {}, ignore or {}, imported
end

function config.saveConfig(cfg) return saveTable(config.FILES.cfg, cfg) end
function config.saveLog(log)    return saveTable(config.FILES.log, log) end
function config.saveIgnore(ig)  return saveTable(config.FILES.ignore, ig) end

-- ------------------------------------------------------------- accessors ---

function config.range(cfg)          return config.RANGES[cfg.rangeIndex].value end
function config.rangeLabel(cfg)     return config.RANGES[cfg.rangeIndex].label end
function config.alertRange(cfg)     return config.RANGES[cfg.alertRangeIndex].value end
function config.alertRangeLabel(cfg) return config.RANGES[cfg.alertRangeIndex].label end
function config.scanInterval(cfg)   return config.SCAN_INTERVALS[cfg.scanIndex] end
function config.sound(cfg)          return config.SOUNDS[cfg.sound.index] end

local UP_NAMES = {
  [0] = "N up", [45] = "NE up", [90] = "E up", [135] = "SE up",
  [180] = "S up", [225] = "SW up", [270] = "W up", [315] = "NW up",
}

function config.rotationLabel(cfg)
  local name = UP_NAMES[cfg.rotation]
  return cfg.rotation .. (name and (" deg, " .. name) or " deg")
end

function config.headingStepLabel(cfg)
  for _, entry in ipairs(config.HEADING_STEPS) do
    if entry.value == cfg.headingStep then return entry.label end
  end
  return cfg.headingStep .. " deg steps"
end

function config.isUnlocked(cfg) return cfg.orientation == "heading" end

--- One line describing where a backdrop's sky comes from.
function config.backdropSkyLabel(cfg)
  for _, entry in ipairs(config.BACKDROP_SKIES) do
    if entry.id == cfg.backdropSky then return entry.label .. " - " .. entry.hint end
  end
  return cfg.backdropSky
end

-- ------------------------------------------------------------------ roles ---

function config.isBase(cfg) return cfg.role == "base" end
function config.isShip(cfg) return cfg.role == "ship" end

--- Whether this role needs a modem open at all. A STATION never touches the
--- network, so nothing here can break an install that does not want one.
function config.usesNetwork(cfg)
  return cfg.role == "base" or cfg.role == "ship"
end

function config.role(cfg)
  for _, entry in ipairs(config.ROLES) do
    if entry.id == cfg.role then return entry end
  end
  return config.ROLES[1]
end

function config.roleLabel(cfg)
  local entry = config.role(cfg)
  return entry.label .. " - " .. entry.hint
end

--- How a paired base is named in the UI, falling back to its computer id.
function config.pairedLabel(cfg)
  if not cfg.pairedBaseId then return nil end
  return cfg.pairedBaseName or ("computer " .. tostring(cfg.pairedBaseId))
end

--- One line describing how the scope is oriented. `heading` is the bearing
--- currently being followed, or nil when the operator's yaw is unreadable.
function config.orientationLabel(cfg, heading)
  if not config.isUnlocked(cfg) then
    return "locked - " .. config.rotationLabel(cfg)
  end
  if not heading then return "unlocked - no heading fix" end
  return ("unlocked - %d deg%s"):format(util.round(heading) % 360,
    cfg.headingStep > 0 and (", " .. cfg.headingStep .. " deg steps") or "")
end

return config
