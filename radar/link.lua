-- The network: the MAIN BASE's sweep, relayed over rednet to every MOBILE.
--
-- Create: Aeronautics assembles a ship into a contraption, and the blocks
-- riding on it stop answering anything that depends on a real world block
-- position: getPlayersInRange() comes back empty while the ship is flying. A
-- pocket computer has the same problem for a different reason -- there is
-- nowhere to bolt a detector to it. getPlayerPos(name) is an ENTITY lookup,
-- so a computer on the ground can still read a player's position wherever
-- they have got to. The MAIN BASE therefore does all the detecting, and every
-- MOBILE only draws.
--
-- Two extension points let a module use the same modem without this file
-- knowing what the traffic means: onProtocol() claims a rednet protocol of its
-- own (power clients broadcasting readings), and onRelay() adds a payload type
-- to what the main base already sends its mobiles (those readings, merged).
--
-- Nothing derived travels. A contact goes over the wire as a bare position,
-- and radar.scan rebuilds the distance, bearing and band at the far end -- so
-- there is one implementation of that maths, not two that can drift apart.

local config      = require("radar.config")
local environment = require("radar.environment")
local scan        = require("radar.scan")
local util        = require("radar.util")

local link = {}
link.__index = link

-- Payloads and announcements ride on separate protocols so a mobile hunting
-- for stations can listen for beacons without wading through contact traffic.
link.PROTOCOL = "radar_link"
link.HELLO    = "radar_link_hello"

-- Protocols a module has claimed: protocol -> handler(link, app, id, message).
-- This is what lets the power module put a second kind of traffic on the same
-- modem without link.lua knowing anything about energy -- see
-- radar/modules/power.lua and powerclient.lua.
link.handlers = {}

--- Claims a rednet protocol for a module.
---@param protocol string
---@param handler function(link, app, id, message) -> boolean accepted
function link.onProtocol(protocol, handler)
  link.handlers[protocol] = handler
end

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

  -- Where the main base itself stands. A mobile has no way of knowing that
  -- otherwise -- it was left showing whatever coordinates happened to be in
  -- its own settings file, which on a fresh install is 0, 64, 0 -- and it is
  -- what "home" means on the flight page.
  local home = nil
  if app.cfg.baseX then
    home = { x = app.cfg.baseX, y = app.cfg.baseY, z = app.cfg.baseZ,
             d = app.cfg.baseDim }
  end

  return pcall(rednet.broadcast, {
    t = "s",
    c = packPos(app.centre),
    p = packPos(app.myPos),
    -- WHOSE position `p` is. A station leaves the player it is watching out of
    -- its own contact list, so that person reaches a mobile only through this
    -- field -- and a mobile watching somebody else has to know that `p` is not
    -- them. Added in v8.6; a mobile talking to an older base falls back to
    -- assuming it is the same person, which is what it always did.
    n = app.cfg.myName,
    g = app.headingRaw,
    e = app.scanError,
    i = config.scanInterval(app.cfg),
    h = home,
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

--- Takes the main base's own coordinates off a relayed sweep.
---
--- Written into the ordinary base settings rather than kept somewhere
--- separate, so everything that already reads them -- the status page, the
--- flight page's way home -- needs no special case for being a mobile. Only
--- written when they actually change, or a save would run every sweep.
---@return boolean changed
function link:applyHome(app, message)
  if not app.cfg.baseFollow then return false end
  local home = unpackPos(message.h)
  if not home then return false end

  local cfg = app.cfg
  if cfg.baseX == home.x and cfg.baseY == home.y and cfg.baseZ == home.z
     and cfg.baseDim == home.dimension then
    return false
  end

  cfg.baseX, cfg.baseY, cfg.baseZ = home.x, home.y, home.z
  cfg.baseDim = home.dimension
  app:saveConfig()
  return true
end

--- The position and yaw of one named player, taken out of a relayed sweep.
---
--- A station leaves the player it is watching out of its own contact list, so
--- that person arrives as `p`/`g` rather than as an entry in `l`. Which of the
--- two to read therefore depends on whether this mobile and the main base are
--- watching the same person.
---@return table|nil pos { x, y, z, dimension }
---@return number|nil heading
function link.pilotFrom(message, name)
  if type(name) ~= "string" or #name == 0 then return nil end

  if message.n == name then
    local pos = unpackPos(message.p)
    if pos then return pos, tonumber(message.g) end
  end

  for _, entry in ipairs(type(message.l) == "table" and message.l or {}) do
    if entry.n == name and tonumber(entry.x) then
      return { x = entry.x, y = entry.y, z = entry.z, dimension = entry.d },
        entry.w and util.headingOf(entry.w) or nil
    end
  end

  -- A base from before v8.6 does not say whose position it is sending. It is
  -- the player IT is watching, very often the same person, and assuming so is
  -- exactly what this did unconditionally before.
  if message.n == nil then return unpackPos(message.p), tonumber(message.g) end
  return nil
end

--- Where a MOBILE measures distances from.
---
--- The main base worked out a centre from ITS OWN settings, and until v8.6
--- every mobile simply used it. That is right for a mobile watching the base
--- and WRONG for one set to SELF: a pocket computer told to watch YOU was
--- reporting everyone's distance from the base, so a player standing next to
--- you read as six kilometres away.
---
--- SELF with no fix is reported rather than quietly falling back to the base.
--- Being silently measured from the wrong place is the bug this replaced.
---@return table|nil centre
---@return string|nil problem
function link:centreFor(app, message, pilot)
  local cfg = app.cfg

  if cfg.mode == "self" then
    -- A mobile riding a Sub-Level measures from the SHIP. The pilot's fix is
    -- still what arrives over the network -- it is what the base can see --
    -- but on a vessel that can say where it is, where somebody happens to be
    -- standing on the deck is not the centre of anything.
    local ship = scan.shipCentre(cfg, pilot)
    if ship then return ship end
    if pilot then return pilot end
    if not cfg.myName then
      return nil, "SELF tracking needs your username - Settings / Tracking"
    end
    return nil, "Cannot find " .. cfg.myName .. " - out of the base's range?"
  end

  -- FIXED: this station's own base coordinates, which baseFollow keeps in step
  -- with the main base unless the operator has turned it off.
  if cfg.baseX then
    return {
      x = cfg.baseX, y = cfg.baseY or 64, z = cfg.baseZ, dimension = cfg.baseDim,
    }
  end
  return unpackPos(message.c)
end

function link:applyScan(app, message)
  self.lastAt = os.clock()
  self.interval = tonumber(message.i)

  -- Before the centre, so a mobile following its base measures from where the
  -- base says it is now rather than from where it was last sweep.
  self:applyHome(app, message)

  local pilot, pilotHeading = link.pilotFrom(message, app.cfg.myName)
  local centre, problem = self:centreFor(app, message, pilot)

  -- The pilot's own yaw, not the base operator's. On a mobile watching
  -- somebody else those are two different people looking two different ways.
  self.headingRaw = pilotHeading or tonumber(message.g)

  local myPos = pilot or unpackPos(message.p)

  if not centre then
    -- Cleared rather than left standing. applyScan keeps the previous list
    -- through an error, because a detector that blinks should not empty the
    -- scope -- but this is not a blink. Every one of those contacts was
    -- measured from a centre we have just decided is the wrong one, and
    -- stale distances drawn as if they were live are worse than none.
    app.contacts = {}
    app:applyScan(myPos, {}, nil, problem)
    if app:applyHeading(self.headingRaw) then app:emit("heading") end
    return true
  end

  local contacts = {}
  for _, entry in ipairs(type(message.l) == "table" and message.l or {}) do
    -- Whoever this station is watching is not one of its own contacts. The
    -- base drops the player IT watches; this drops the one WE watch, which on
    -- a shared world is not always the same person.
    if entry.n ~= app.cfg.myName then
      local contact = unpackContact(centre, entry)
      if contact then
        -- Re-filtered against OUR centre: a contact in the base's dimension is
        -- not necessarily in ours once we are measuring from somewhere else.
        local sameDim = true
        if app.cfg.dimFilter and contact.dim and centre.dimension then
          sameDim = (contact.dim == centre.dimension)
        end
        if sameDim then contacts[#contacts + 1] = contact end
      end
    end
  end
  scan.sort(contacts)

  app:applyScan(myPos, contacts, centre,
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

  -- A module's own protocol is entirely its business: who it accepts traffic
  -- from, and what it does with it, is decided in the module rather than here.
  -- Power clients broadcast to whoever is listening, which is a different
  -- trust model from the paired base/mobile link below.
  local handler = link.handlers[protocol]
  if handler then
    local ok, accepted = pcall(handler, self, app, id, message)
    return ok and accepted == true
  end

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

  -- Everything else is only of interest to a MOBILE, and only from the one
  -- main base it was paired with -- so two crews on one world never cross
  -- wires.
  if not app or not config.isMobile(app.cfg) then return false end
  if not app.cfg.pairedBaseId or id ~= app.cfg.pairedBaseId then return false end

  if message.t == "s" then return self:applyScan(app, message) end
  if message.t == "e" then return self:applyEnv(app, message) end

  -- A relayed payload a module owns. Same pairing rule as the sweep: it came
  -- from the main base this mobile is listening to.
  local relay = link.relays[message.t]
  if relay then
    local ok, accepted = pcall(relay, self, app, message)
    return ok and accepted == true
  end
  return false
end

-- What a MAIN BASE relays onward to its mobiles, beyond the sweep and the
-- weather: payload type -> handler(link, app, message). Registered by the
-- module that owns the payload, so a mobile draws a page it has no hardware
-- for at all.
link.relays = {}

---@param kind string A one or two letter payload type
---@param handler function(link, app, message) -> boolean accepted
function link.onRelay(kind, handler)
  link.relays[kind] = handler
end

--- Broadcasts a module's payload to the mobiles, on the main link protocol.
---@return boolean sent
function link:relay(kind, payload)
  if not self.open then return false end
  payload.t = kind
  return (pcall(rednet.broadcast, payload, link.PROTOCOL))
end

--- Waits briefly for one message and applies it. Blocking, so it belongs in a
--- schedule of its own.
function link:pump(app, timeout)
  if not self.open then return false end
  local id, message, protocol = rednet.receive(nil, timeout or link.RECEIVE_TIMEOUT)
  if not id then return false end
  if protocol ~= link.PROTOCOL and protocol ~= link.HELLO
     and not link.handlers[protocol] then
    return false
  end
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

--- Why a MOBILE has nothing to draw, or nil when the link is healthy. Reported
--- through app.scanError, so every page says "link lost" in the same place it
--- already says "detector fault".
---@return string|nil problem
function link:status(cfg)
  if not config.isMobile(cfg) then return nil end
  if not self.open then return (self.error or "No modem") .. " - a MOBILE needs one" end
  if not cfg.pairedBaseId then return "No main base paired - Settings / Link" end

  local label = config.pairedLabel(cfg)
  if not self.lastAt then return "Waiting for " .. label end
  if (os.clock() - self.lastAt) > self:staleAfter(cfg) then
    return "Link lost - nothing from " .. label
  end
  return nil
end

--- Whether a relayed environment snapshot is recent enough to keep drawing,
--- which is what tells a mobile not to bother with a local detector.
function link:envFresh(cfg)
  if not self.envAt then return false end
  local limit = math.max(6, 2 * (self.envInterval or cfg.envSeconds) + 2)
  return (os.clock() - self.envAt) <= limit
end

--- One line for the status page.
---@return string text
---@return boolean healthy
function link:summary(cfg)
  if config.isMain(cfg) then
    if not self.open then
      return (self.error or "no modem") .. " - not broadcasting", false
    end
    return ("MAIN BASE \"%s\"%s"):format(cfg.stationName,
      cfg.relayWeather and "  +weather" or ""), true
  end

  if config.isMobile(cfg) then
    local problem = self:status(cfg)
    if problem then return problem, false end
    return "MOBILE - linked to " .. config.pairedLabel(cfg), true
  end

  return "stand-alone", true
end

return link
