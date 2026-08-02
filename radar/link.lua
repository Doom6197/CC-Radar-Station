-- The base/ship link: one station's sweep, relayed over rednet to another.
--
-- Create: Aeronautics assembles a ship into a contraption, and the blocks
-- riding on it stop answering anything that depends on a real world block
-- position: getPlayersInRange() comes back empty while the ship is flying.
-- getPlayerPos(name) is an ENTITY lookup, so a station bolted to the ground
-- can still read the pilot's position wherever they have got to. A BASE
-- therefore does all the detecting, and a SHIP only draws.
--
-- Nothing derived travels. A contact goes over the wire as a bare position,
-- and radar.scan rebuilds the distance, bearing and band at the far end -- so
-- there is one implementation of that maths, not two that can drift apart.

local config      = require("radar.config")
local environment = require("radar.environment")
local scan        = require("radar.scan")

local link = {}
link.__index = link

-- Payloads and announcements ride on separate protocols so a ship hunting for
-- stations can listen for beacons without wading through contact traffic.
link.PROTOCOL = "radar_link"
link.HELLO    = "radar_link_hello"

link.ANNOUNCE_SECONDS = 5
link.RECEIVE_TIMEOUT  = 1

-- How long a ship listens when the operator asks it to find base stations.
link.SCAN_SECONDS = 4

-- A station heard longer ago than this has probably been turned off, so it
-- drops out of the picker rather than offering a base that is not there.
link.SEEN_SECONDS = 30

function link.new()
  return setmetatable({
    open = false,
    modemName = nil,
    error = nil,

    seen = {},          -- computer id -> { id, name, at }

    lastAt = nil,       -- when the paired base last spoke
    interval = nil,     -- its sweep interval, which sets the staleness limit
    envAt = nil,
    envInterval = nil,
    headingRaw = nil,   -- the pilot's yaw as a bearing, before local snapping
  }, link)
end

-- ------------------------------------------------------------------ modem ---

function link:close()
  if self.open and self.modemName and rednet then
    pcall(rednet.close, self.modemName)
  end
  self.open, self.modemName = false, nil
end

--- Opens rednet on the best modem the kit found, or closes it again for a
--- role that wants nothing to do with the network.
---@return boolean open
function link:attach(kit, cfg)
  if not config.usesNetwork(cfg) then
    self:close()
    self.error = nil
    return false
  end
  if not rednet then
    self:close()
    self.error = "No rednet API on this computer"
    return false
  end

  local modem = kit.modem
  if not modem then
    self:close()
    self.error = "No modem attached"
    return false
  end
  if self.open and self.modemName == modem.name then
    self.error = nil
    return true
  end

  self:close()
  local ok, err = pcall(rednet.open, modem.name)
  if not ok then
    self.error = "Modem error: " .. tostring(err)
    return false
  end
  self.open, self.modemName, self.error = true, modem.name, nil
  return true
end

--- Forgets everything heard from the previous base, so a freshly paired one
--- starts from "waiting" rather than inheriting someone else's staleness.
function link:forget()
  self.lastAt, self.interval = nil, nil
  self.envAt, self.envInterval = nil, nil
  self.headingRaw = nil
end

-- ------------------------------------------------------------- the wire ---

local function packPos(p)
  if not p then return nil end
  return { x = p.x, y = p.y, z = p.z, d = p.dimension }
end

local function unpackPos(p)
  if type(p) ~= "table" or not tonumber(p.x) then return nil end
  return { x = p.x, y = p.y, z = p.z, dimension = p.d }
end

--- A contact stripped back to what cannot be recomputed at the far end.
local function packContact(c)
  return {
    n = c.name, x = c.x, y = c.y, z = c.z,
    w = c.yaw, h = c.health, m = c.maxHealth, d = c.dim,
  }
end

local function unpackContact(centre, entry)
  if type(entry) ~= "table" or type(entry.n) ~= "string" then return nil end
  return scan.contactFrom(centre, entry.n, {
    x = entry.x, y = entry.y, z = entry.z, yaw = entry.w,
    health = entry.h, maxHealth = entry.m, dimension = entry.d,
  })
end

-- -------------------------------------------------------------- sending ---

--- Says who this base is. Sent whether or not anyone is listening, which is
--- what keeps the pairing side of this free of handshake state.
function link:announce(cfg)
  if not self.open then return false end
  return pcall(rednet.broadcast, { t = "h", n = cfg.stationName }, link.HELLO)
end

--- Relays a finished sweep.
function link:sendScan(app)
  if not self.open then return false end

  local list = {}
  for i, contact in ipairs(app.contacts) do list[i] = packContact(contact) end

  return pcall(rednet.broadcast, {
    t = "s",
    c = packPos(app.centre),
    p = packPos(app.myPos),
    g = app.headingRaw,
    e = app.scanError,
    i = config.scanInterval(app.cfg),
    l = list,
  }, link.PROTOCOL)
end

--- Relays the environment readings, when the operator has asked for it.
function link:sendEnv(app)
  if not self.open or not app.cfg.relayWeather then return false end
  local readings = app.env.readings
  if not readings then return false end
  return pcall(rednet.broadcast, {
    t = "e", r = readings, i = app.cfg.envSeconds,
  }, link.PROTOCOL)
end

-- ------------------------------------------------------------ receiving ---

function link:applyScan(app, message)
  local centre = unpackPos(message.c)

  local contacts = {}
  if centre and type(message.l) == "table" then
    for _, entry in ipairs(message.l) do
      local contact = unpackContact(centre, entry)
      if contact then contacts[#contacts + 1] = contact end
    end
  end
  scan.sort(contacts)

  self.lastAt = os.clock()
  self.interval = tonumber(message.i)
  self.headingRaw = tonumber(message.g)

  app:applyScan(unpackPos(message.p), contacts, centre,
    type(message.e) == "string" and message.e or nil)
  if app:applyHeading(self.headingRaw) then app:emit("heading") end
  return true
end

function link:applyEnv(app, message)
  local snapshot = environment.fromReadings(message.r, app.cfg)
  if not snapshot.available then return false end
  self.envAt = os.clock()
  self.envInterval = tonumber(message.i)
  app.env.snapshot = snapshot
  app:emit("env")
  return true
end

--- Applies one received message. Split from the loop below so the whole
--- receiving path can be driven without a real network.
---@return boolean accepted
function link:handle(app, id, message, protocol)
  if type(id) ~= "number" or type(message) ~= "table" then return false end

  -- Beacons are collected whatever this station's role is: that list is what
  -- the "scan for base stations" picker offers.
  if message.t == "h" then
    local name = type(message.n) == "string" and message.n or ("Computer " .. id)
    self.seen[id] = { id = id, name = name, at = os.clock() }
    -- A base that has since been renamed should not keep showing its old name.
    if app and app.cfg.pairedBaseId == id and app.cfg.pairedBaseName ~= name then
      app.cfg.pairedBaseName = name
    end
    return true
  end

  -- Everything else is only of interest to a ship, and only from the one base
  -- it was paired with -- so two crews on one world never cross wires.
  if not app or not config.isShip(app.cfg) then return false end
  if not app.cfg.pairedBaseId or id ~= app.cfg.pairedBaseId then return false end

  if message.t == "s" then return self:applyScan(app, message) end
  if message.t == "e" then return self:applyEnv(app, message) end
  return false
end

--- Waits briefly for one message and applies it. Blocking, so it belongs in a
--- schedule of its own.
function link:pump(app, timeout)
  if not self.open then return false end
  local id, message, protocol = rednet.receive(nil, timeout or link.RECEIVE_TIMEOUT)
  if not id then return false end
  if protocol ~= link.PROTOCOL and protocol ~= link.HELLO then return false end
  return self:handle(app, id, message, protocol)
end

-- --------------------------------------------------------------- pairing ---

--- Base stations heard recently, nearest thing to hand for the picker.
---@return table list { { id = , name = } , ... } sorted by name
function link:knownBases()
  local now, list = os.clock(), {}
  for id, entry in pairs(self.seen) do
    if (now - entry.at) <= link.SEEN_SECONDS then
      list[#list + 1] = { id = id, name = entry.name }
    end
  end
  table.sort(list, function(a, b)
    if a.name == b.name then return a.id < b.id end
    return a.name < b.name
  end)
  return list
end

-- ---------------------------------------------------------------- health ---

--- Two sweeps of silence means the link is down rather than merely quiet. The
--- base broadcasts its own interval, so a slow base is not called dead.
function link:staleAfter(cfg)
  return math.max(3, 2 * (self.interval or config.scanInterval(cfg)))
end

--- Why a ship has nothing to draw, or nil when the link is healthy. Reported
--- through app.scanError, so every page says "link lost" in the same place it
--- already says "detector fault".
---@return string|nil problem
function link:status(cfg)
  if not config.isShip(cfg) then return nil end
  if not self.open then return (self.error or "No modem") .. " - the ship link needs one" end
  if not cfg.pairedBaseId then return "No base station paired - Settings / Link" end

  local label = config.pairedLabel(cfg)
  if not self.lastAt then return "Waiting for " .. label end
  if (os.clock() - self.lastAt) > self:staleAfter(cfg) then
    return "Link lost - nothing from " .. label
  end
  return nil
end

--- Whether a relayed environment snapshot is recent enough to keep drawing,
--- which is what tells a ship not to bother with a local detector.
function link:envFresh(cfg)
  if not self.envAt then return false end
  local limit = math.max(6, 2 * (self.envInterval or cfg.envSeconds) + 2)
  return (os.clock() - self.envAt) <= limit
end

--- One line for the status page.
---@return string text
---@return boolean healthy
function link:summary(cfg)
  if config.isBase(cfg) then
    if not self.open then
      return (self.error or "no modem") .. " - not broadcasting", false
    end
    return ("BASE \"%s\"%s"):format(cfg.stationName,
      cfg.relayWeather and "  +weather" or ""), true
  end

  if config.isShip(cfg) then
    local problem = self:status(cfg)
    if problem then return problem, false end
    return "SHIP - linked to " .. config.pairedLabel(cfg), true
  end

  return "stand-alone", true
end

return link
