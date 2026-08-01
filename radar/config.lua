-- Settings, detection log and ignore list: load, sanitise, save.
--
-- Files live next to the program. Settings from Radar Station v3 (and from
-- the older pocket version it grew out of) are imported on first run, so an
-- existing station keeps its base coordinates, ignore list and history.

local util = require("radar.util")

local config = {}

config.VERSION = "4.0"

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

function config.defaults()
  return {
    version = config.VERSION,

    myName = nil,
    mode   = "fixed",                    -- "fixed" measures from baseX/Y/Z
    baseX = nil, baseY = nil, baseZ = nil, baseDim = nil,

    rangeIndex      = config.MAX_RANGE_INDEX,
    alertRangeIndex = config.MAX_RANGE_INDEX,
    scanIndex       = 2,                 -- SCAN_INTERVALS[2] = 1 second
    rotation        = 0,                 -- true bearing shown at the top

    alert     = true,                    -- master alert switch
    flash     = true,                    -- flash every screen red
    toast     = true,                    -- pop a banner on the terminal
    dimFilter = true,                    -- hide players in other dimensions

    env        = true,                   -- poll the environment detector
    envSeconds = 2,                      -- how often, in seconds
    animate    = true,                   -- animate the sky and radar sweep

    terminalPage = "status",

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

    displays = {},                       -- [peripheralName] = {page=, scale=}
  }
end

-- -------------------------------------------------------------- sanitising ---

local clamp = util.clamp

local function indexOfId(list, id)
  for i, entry in ipairs(list) do
    if entry.id == id or entry == id then return i end
  end
  return nil
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

  if not config.isPage(cfg.terminalPage) then cfg.terminalPage = "status" end

  if type(cfg.displays) ~= "table" then cfg.displays = {} end
  for name, entry in pairs(cfg.displays) do
    if type(entry) ~= "table" then
      cfg.displays[name] = { page = "radar", scale = 0.5 }
    else
      if not config.isPage(entry.page) then entry.page = "radar" end
      entry.scale = clamp(tonumber(entry.scale) or 0.5, 0.5, 5)
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

function config.rotationLabel(cfg)
  local names = {
    [0] = "N up", [45] = "NE up", [90] = "E up", [135] = "SE up",
    [180] = "S up", [225] = "SW up", [270] = "W up", [315] = "NW up",
  }
  local name = names[cfg.rotation]
  return cfg.rotation .. (name and (" deg, " .. name) or " deg")
end

return config
