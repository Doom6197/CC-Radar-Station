-- Turning the Player Detector into a list of contacts.
--
-- getPlayersInRange() is always centred on the detector BLOCK. FIXED mode
-- changes only what distances are measured FROM, so for a stationary station
-- you normally put the detector at the base and set the base coordinates to
-- the detector's own position, and the two agree.

local config = require("radar.config")
local theme  = require("radar.theme")
local util   = require("radar.util")

local scan = {}

--- Where distances are measured from.
local function centreOf(cfg, myPos)
  if cfg.mode == "fixed" and cfg.baseX then
    return {
      x = cfg.baseX, y = cfg.baseY or 64, z = cfg.baseZ,
      dimension = cfg.baseDim,
    }
  end
  return myPos
end

--- Reads the operator's own position, if a username is configured.
function scan.myPosition(kit, cfg)
  if not cfg.myName or #cfg.myName == 0 then return nil end
  local ok, p = pcall(kit.detector.getPlayerPos, cfg.myName)
  if ok and type(p) == "table" and p.x then return p end
  return nil
end

--- Runs one sweep.
---@return table|nil myPos
---@return table contacts Sorted nearest first
---@return table|nil centre
---@return string|nil err
function scan.run(kit, cfg, ignore)
  if not kit.detector then
    return nil, {}, nil, "No Player Detector attached"
  end

  local myPos = scan.myPosition(kit, cfg)
  local centre = centreOf(cfg, myPos)
  if not centre then
    return nil, {}, nil, "No centre: set base coordinates or a username"
  end

  local ok, names = pcall(kit.detector.getPlayersInRange, config.range(cfg))
  if not ok or type(names) ~= "table" then
    -- Some servers reject very large range values outright. Retry at a radius
    -- everything accepts rather than reporting a dead detector.
    local retried, fallback = pcall(kit.detector.getPlayersInRange, 10000)
    if retried and type(fallback) == "table" then
      names = fallback
    else
      return myPos, {}, centre, "Detector error: " .. util.shorten(tostring(names), 48)
    end
  end

  local contacts = {}
  for _, entry in ipairs(names) do
    -- Older builds returned plain strings, newer ones may return tables.
    local name = type(entry) == "table" and entry.name or entry
    if name and name ~= cfg.myName and not ignore[name] then
      local gotPos, pos = pcall(kit.detector.getPlayerPos, name)
      if gotPos and type(pos) == "table" and pos.x then
        local sameDim = true
        if cfg.dimFilter and pos.dimension and centre.dimension then
          sameDim = (pos.dimension == centre.dimension)
        end
        if sameDim then
          local dx = pos.x - centre.x
          local dz = pos.z - centre.z
          local dy = pos.y - (centre.y or pos.y)
          local dist = math.sqrt(dx * dx + dz * dz)
          local zoneLabel, zoneColor, zoneTone = theme.zoneFor(dist)
          contacts[#contacts + 1] = {
            name = name,
            x = pos.x, y = pos.y, z = pos.z,
            dx = dx, dy = dy, dz = dz,
            dist    = dist,
            bearing = util.bearingOf(dx, dz),
            dir     = util.directionOf(dx, dz),
            yaw     = tonumber(pos.yaw),
            health  = tonumber(pos.health),
            maxHealth = tonumber(pos.maxHealth),
            dim     = pos.dimension,
            zone      = zoneLabel,
            zoneColor = zoneColor,
            zoneTone  = zoneTone,
          }
        end
      end
    end
  end

  table.sort(contacts, function(a, b)
    if a.dist == b.dist then return a.name < b.name end
    return a.dist < b.dist
  end)
  return myPos, contacts, centre, nil
end

--- Names currently online, for the ignore-list picker.
function scan.onlinePlayers(kit)
  if not kit.detector then return {} end
  local ok, list = pcall(kit.detector.getOnlinePlayers)
  if not ok or type(list) ~= "table" then return {} end
  local names = {}
  for _, entry in ipairs(list) do
    local name = type(entry) == "table" and entry.name or entry
    if name then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

return scan
