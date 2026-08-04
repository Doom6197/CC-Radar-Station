-- Application state and the background loops that drive it.
--
-- The UI never talks to a peripheral directly. It reads the tables here and
-- subscribes to events:
--
--   "scan"    a sweep finished; contacts/centre/scanError are new
--   "env"     the environment snapshot changed
--   "anim"    animation frame; only fired while something animated is visible
--   "config"  settings changed and were written to disk
--   "hardware" peripherals were rediscovered
--   "backdrop" the weather page's chosen picture changed
--
-- A module may emit events of its own -- the power module emits "power" -- and
-- a view subscribing to one it does not recognise simply never hears from it.
--
-- A SHIP fills the same tables and fires the same events from what a base
-- relays instead of from a detector, so no view can tell the difference.
--
-- Every loop runs as a Basalt schedule, so sleep() is legal inside them and
-- the UI stays responsive throughout. Modules add their own loops the same
-- way, from their start() -- see radar/modules.lua.
--
-- What is HERE is what more than one page needs: the sweep, the environment,
-- the heading, the link. Anything only one page cares about lives in that
-- page's module and hangs its state off this table.

local basalt      = require("basalt")
local config      = require("radar.config")
local hardware    = require("radar.hardware")
local modules     = require("radar.modules")
local scan        = require("radar.scan")
local logbook     = require("radar.logbook")
local sable       = require("radar.sable")
local alertsLib   = require("radar.alerts")
local environment = require("radar.environment")
local linkLib     = require("radar.link")
local util        = require("radar.util")

local app = {}
app.__index = app

local ANIM_FPS = 5

-- Fraction of the remaining turn the drawn heading closes each animation
-- frame. At 5 fps this settles a 180 degree spin in well under a second while
-- still reading as a turn rather than a jump.
local HEADING_EASE = 0.34

function app.new()
  -- Every module has to be registered before the settings are read, because
  -- what a setting IS -- its default, its legal range, whether the page it
  -- belongs to exists at all -- is a question only the registry can answer.
  modules.load()

  local cfg, logEntries, ignore, imported, fresh = config.load()

  local self = setmetatable({
    cfg = cfg,
    ignore = ignore,
    imported = imported,
    fresh = fresh,
    log = logbook.new(logEntries),

    kit = modules.discover(hardware.discover()),

    contacts = {},
    previous = {},        -- name -> true, from the previous sweep
    myPos = nil,
    centre = nil,
    scanError = nil,
    firstScan = true,
    lastScanAt = 0,

    heading = nil,        -- bearing the operator faces, nil when unreadable
    headingRaw = nil,     -- before snapping; what a base relays to a ship
    headingShown = nil,   -- eased toward `heading`; what actually gets drawn

    anim = 0,
    animWanted = 0,       -- number of visible views asking for frames

    listeners = {},
    running = true,
  }, app)

  self.env = environment.new()
  self.alerts = alertsLib.new(cfg, self.kit)
  self.link = linkLib.new()
  self.link:attach(self.kit, cfg)

  -- Last, so a module's attach() finds a fully built app: the kit, the
  -- settings, the alert channels and the link are all in place by here.
  modules.attach(self)
  return self
end

-- ------------------------------------------------------------------ events ---

function app:on(event, fn)
  local list = self.listeners[event]
  if not list then list = {}; self.listeners[event] = list end
  list[#list + 1] = fn
  return fn
end

function app:emit(event, ...)
  local list = self.listeners[event]
  if not list then return end
  for i = 1, #list do
    -- A broken view must not take the station down with it.
    local ok, err = pcall(list[i], ...)
    if not ok then self.viewError = tostring(err) end
  end
end

--- Views call this while visible so the animation loop knows whether anyone
--- is watching. Returns a function that releases the request.
function app:requestAnimation()
  self.animWanted = self.animWanted + 1
  local released = false
  return function()
    if released then return end
    released = true
    self.animWanted = math.max(0, self.animWanted - 1)
  end
end

-- ------------------------------------------------------------ persistence ---

function app:saveConfig()
  config.saveConfig(self.cfg)
  self:emit("config")
end

function app:saveIgnore() config.saveIgnore(self.ignore) end

-- -------------------------------------------------------------- hardware ---

function app:rescan()
  self.kit = modules.discover(hardware.discover())
  self.alerts:setKit(self.kit)
  self.link:attach(self.kit, self.cfg)
  for _, monitor in ipairs(self.kit.monitors) do
    if not self.cfg.displays[monitor.name] then
      self.cfg.displays[monitor.name] = config.displayDefaults()
    end
  end
  -- A module that claimed hardware has to be told the list has changed, or the
  -- power page would keep polling an energy detector that has been mined.
  modules.attach(self)
  self:saveConfig()
  self:emit("hardware")
end

function app:displayConfig(name)
  local entry = self.cfg.displays[name]
  if not entry then
    entry = config.displayDefaults()
    self.cfg.displays[name] = entry
  end
  return entry
end

-- ---------------------------------------------------------------- heading ---
-- With the orientation unlocked the scope turns with the operator, so the top
-- of the picture is always the way they are looking. That needs the yaw more
-- often than a sweep provides it, but the reading is a single detector call,
-- so it gets its own cheap loop rather than making every sweep faster.

--- The bearing drawn at the top of the scope right now.
function app:rotation()
  if config.isUnlocked(self.cfg) and self.headingShown then
    return self.headingShown
  end
  return self.cfg.rotation
end

--- Takes a raw bearing and snaps it to this station's own heading step.
---
--- CALL readHeading, NOT THIS. This only stores what it is given; deciding
--- WHERE a heading comes from is readHeading's job and belongs in one place.
--- The relayed sweep used to write the pilot's bearing in here directly, which
--- on a ship fought the heading loop -- one writing the vessel's nose, the
--- other the operator's facing -- and the reading flickered between them.
---@return boolean changed True when the snapped heading moved
function app:applyHeading(raw)
  local heading = raw and util.snapAngle(raw, self.cfg.headingStep) or nil

  local changed = heading ~= self.heading
  self.heading = heading
  self.headingRaw = raw

  -- Without smoothing, or with nothing running the animation loop, the drawn
  -- value has to follow immediately or the scope would never turn at all.
  if heading and (not self.cfg.headingSmooth or not self.cfg.animate
                  or self.headingShown == nil) then
    self.headingShown = heading
  end
  return changed
end

--- Re-reads whatever the tracking mode says the scope should turn with.
---@return boolean changed True when the snapped heading moved
function app:readHeading()
  -- SHIP tracking turns with the VESSEL, which knows its own orientation.
  -- Read straight from the ship rather than through the flight model, so the
  -- scope still turns with the flight page switched off.
  if config.tracksShip(self.cfg) then
    local heading = sable.heading(self.cfg.headingTrim)
    if heading then return self:applyHeading(heading) end
    -- No Sub-Level under us. Following the operator is a better answer than
    -- freezing, and the settings row says which it fell back to.
  end

  -- A mobile has no detector to ask; the pilot's yaw arrives with every
  -- relayed sweep, which is exactly what "heading up" on a moving scope needs.
  if config.isMobile(self.cfg) then
    return self:applyHeading(self.link.headingRaw)
  end
  local pos = scan.myPosition(self.kit, self.cfg)
  return self:applyHeading(pos and util.headingOf(pos.yaw) or nil)
end

--- Advances the drawn heading toward the real one.
---
--- Called from the HEADING loop as well as the animation one. It used to be
--- the animation loop's alone, and that loop only turns over while a visible
--- view is asking for frames -- so with smoothing AND animation on, and
--- nothing requesting them, the scope froze at the first bearing it ever saw
--- and never turned again. The AIRSHIP profile sets exactly that pair.
---
--- What is drawn must not depend on whether something else wanted a redraw.
---@return boolean moved
function app:easeHeading()
  if not config.isUnlocked(self.cfg) or not self.heading then return false end
  local before = self.headingShown

  if not self.cfg.headingSmooth then
    self.headingShown = self.heading
  else
    self.headingShown = util.approachAngle(
      self.headingShown or self.heading, self.heading, HEADING_EASE)
  end
  return self.headingShown ~= before
end

-- ------------------------------------------------------------------ sweep ---

--- Compares a fresh contact list against the previous one and fires alerts
--- for arrivals. On a detector error the previous set is kept, otherwise
--- everyone would re-alert the moment the detector came back.
function app:processDetections(contacts, hadError)
  if hadError then return end

  local current, arrivals = {}, {}
  for _, contact in ipairs(contacts) do
    current[contact.name] = true
    if not self.previous[contact.name] then arrivals[#arrivals + 1] = contact end
  end
  self.previous = current

  if self.firstScan then
    self.firstScan = false
    return
  end
  if #arrivals == 0 then return end

  for _, contact in ipairs(arrivals) do self.log:add(contact) end
  -- An arrival outside the alert range is logged but does not set the alarm
  -- off. It still went unread, so it still gets the chime -- otherwise the
  -- first anyone knows of it is the next time they happen to look at a screen.
  local sounded = self.alerts:trigger(arrivals)
  if not sounded then self.alerts:chime() end
  self:emit("log")
  self:emit("contact", arrivals)
end

--- Raises an alarm about something that is not a contact: a power buffer
--- running low, and whatever a dropped-in module decides is worth saying.
---
--- One call does all of it -- the sound, the flash, the redstone pulse, the
--- banner, the log entry and the unread marker -- so a module never has to
--- know which of those the operator has switched on.
---@param text string One line, as it will appear on the page and the banner
---@param source? string The module raising it
---@return boolean fired Whether the alert channels went off (they are muteable)
function app:alarm(text, source)
  -- Logged whether or not the station is muted: muting silences the alarm,
  -- it does not mean the thing did not happen.
  self.log:alarm(text, source)
  local fired = self.alerts:fire(text)
  if not fired then self.alerts:chime() end
  self:emit("log")
  return fired
end

--- Dismisses every unread entry.
---@return number cleared
function app:markAlertsRead()
  local cleared = self.log:markRead()
  if cleared > 0 then self:emit("log") end
  return cleared
end

--- How many entries have not been looked at. Read by every screen's header.
function app:unreadAlerts() return self.log:unread() end

--- Publishes a finished contact list, wherever it came from. A sweep run here
--- and a sweep relayed by a base land in exactly the same state, which is why
--- no view has to know which one it is looking at.
function app:applyScan(myPos, contacts, centre, err)
  self.scanError = err
  self.myPos = myPos
  self.centre = centre or self.centre
  -- A detector that blinks keeps the last good list rather than emptying the
  -- scope; only a lost link clears it, and does so before calling in.
  if not err then self.contacts = contacts end

  self.alerts.contacts = self.contacts
  self:processDetections(self.contacts, err ~= nil)
  self.alerts:updateRedstone()
  self.lastScanAt = os.clock()
  self:emit("scan")
end

--- On a ship there is nothing to sweep: the contacts arrive over the network.
--- This runs on the same timer purely to notice that they have stopped.
function app:checkLink()
  local problem = self.link:status(self.cfg)
  if not problem then return end
  -- Stale contacts drawn as if they were live are worse than an empty scope.
  self.contacts = {}
  self:applyScan(nil, {}, self.centre, problem)
end

function app:sweep()
  if config.isMobile(self.cfg) then return self:checkLink() end

  local myPos, contacts, centre, err = scan.run(self.kit, self.cfg, self.ignore)
  self:applyScan(myPos, contacts, centre, err)

  -- The pilot's yaw comes free with their position, so a base can relay a
  -- heading even while its own scope sits locked to a fixed bearing.
  if myPos then self.headingRaw = util.headingOf(myPos.yaw) end
  if config.isMain(self.cfg) then self.link:sendScan(self) end
end

function app:pollEnvironment(force)
  -- A ship being fed the weather leaves its own detector alone -- it probably
  -- has none, and aboard a contraption it would not answer anyway.
  if config.isMobile(self.cfg) and self.link:envFresh(self.cfg) then
    self:emit("env")
    return
  end
  self.env:poll(self.kit, self.cfg, force)
  if config.isMain(self.cfg) then self.link:sendEnv(self) end
  self:emit("env")
end

-- ------------------------------------------------------------------ loops ---

function app:start()
  basalt.schedule(function()
    while self.running do
      local ok, err = pcall(self.sweep, self)
      if not ok then self.scanError = "Sweep failed: " .. tostring(err) end
      sleep(config.scanInterval(self.cfg))
    end
  end)

  basalt.schedule(function()
    -- One immediate read so the weather page is populated on the first frame.
    pcall(self.pollEnvironment, self, true)
    while self.running do
      sleep(self.cfg.envSeconds)
      if self.cfg.env then pcall(self.pollEnvironment, self, false) end
    end
  end)

  -- The heading is only worth reading while the orientation is unlocked, so
  -- the loop idles cheaply the rest of the time rather than costing a detector
  -- call every half second for a scope that is not going to turn.
  basalt.schedule(function()
    while self.running do
      do
        local ok, changed = pcall(self.readHeading, self)
        -- Always eased here, not only when the animation loop happens to be
        -- turning over: see easeHeading. The drawn bearing moving is itself a
        -- reason to redraw, or a smoothed turn would be left half finished on
        -- screen until something else asked for one.
        local _, moved = pcall(self.easeHeading, self)
        if (ok and changed) or moved then self:emit("heading") end
        -- Polled even while the scope is LOCKED. It used to idle in that case
        -- to save a detector call, but HDG is a reading the flight page shows
        -- whether or not the picture turns -- and locking the scope should not
        -- make the number go stale.
        sleep(self.cfg.headingSeconds)
      end
    end
  end)

  basalt.schedule(function()
    while self.running do
      sleep(1 / ANIM_FPS)
      if self.cfg.animate and self.animWanted > 0 then
        self.anim = self.anim + 1 / ANIM_FPS
        self:easeHeading()
        self:emit("anim")
      end
    end
  end)

  basalt.schedule(function()
    while self.running do
      self.alerts:tick()
      sleep(0.1)
    end
  end)

  -- Inbound traffic. rednet.receive blocks, so it gets a loop to itself; with
  -- no network role it idles without ever touching the modem.
  basalt.schedule(function()
    while self.running do
      if self.link.open then
        pcall(self.link.pump, self.link, self)
      else
        sleep(1)
      end
    end
  end)

  -- A base says who it is on a fixed cadence whether or not anyone is
  -- listening, so pairing needs no handshake state at this end.
  basalt.schedule(function()
    while self.running do
      if config.isMain(self.cfg) and self.link.open then
        pcall(self.link.announce, self.link, self.cfg)
      end
      sleep(linkLib.ANNOUNCE_SECONDS)
    end
  end)

  -- Whatever the modules want running. Last, so a module loop starting up
  -- finds the station already sweeping and polling rather than half awake.
  modules.start(self)
end

--- Shuts the station down. The event goes out FIRST, while everything is still
--- attached: a module with hardware latched on -- the autopilot holding a
--- ship's thrusters open -- has to be able to let go of it.
function app:stop()
  self:emit("stop")
  self.running = false
  self.link:close()
end

-- ---------------------------------------------------------------- actions ---
-- Shared by the keyboard shortcuts and the settings view, so both paths stay
-- in step and both persist.

function app:setRangeIndex(index)
  self.cfg.rangeIndex = math.max(1, math.min(#config.RANGES, index))
  self:saveConfig()
end

function app:rangeUp()   self:setRangeIndex(self.cfg.rangeIndex + 1) end
function app:rangeDown() self:setRangeIndex(self.cfg.rangeIndex - 1) end

function app:rotate(degrees)
  self.cfg.rotation = (self.cfg.rotation + degrees) % 360
  self:saveConfig()
end

--- Locks the scope to a fixed bearing, or unlocks it to follow the operator.
---@return boolean unlocked The state it ended up in
function app:toggleOrientation()
  self.cfg.orientation = config.isUnlocked(self.cfg) and "fixed" or "heading"
  if config.isUnlocked(self.cfg) then
    -- Take a reading now rather than leaving the scope pointing at the old
    -- fixed bearing until the heading loop next comes round.
    self.headingShown = nil
    pcall(self.readHeading, self)
  end
  self:saveConfig()
  return config.isUnlocked(self.cfg)
end

-- --------------------------------------------------------------- modules ---

--- Switches a module on or off. Anything that changed as a result -- the tab
--- strip, a monitor's page rotation, the terminal's own page -- is repaired by
--- the sanitiser rather than by the caller.
---@return boolean enabled The state it ended up in
function app:toggleModule(id)
  local entry = modules.byId(id)
  if not entry or entry.core then return true end

  local off = self.cfg.modulesOff or {}
  off[id] = (not off[id]) or nil
  self.cfg.modulesOff = off
  config.sanitise(self.cfg)

  -- A module switched on after boot has never had its loops started, so a
  -- freshly enabled power page would draw a graph nothing was feeding. There
  -- is no matching stop: the loops check whether their module is still on.
  modules.startOne(self, id)

  self:saveConfig()
  self:emit("modules")
  return modules.isEnabled(self.cfg, id)
end

--- Applies a device profile over the current settings. Destructive by design:
--- the operator asked for a set of defaults, so they get the whole set rather
--- than a merge that leaves the station in a state no profile describes.
function app:setProfile(id)
  local profiles = require("radar.profiles")
  profiles.apply(self.cfg, id, self.kit)
  config.sanitise(self.cfg)
  self.link:attach(self.kit, self.cfg)
  self.previous, self.firstScan = {}, true

  -- A profile may have switched a module back on, and one that has never run
  -- before needs its loops starting.
  for _, entry in ipairs(modules.all()) do modules.startOne(self, entry.id) end

  self:saveConfig()
  self:emit("modules")
  return self.cfg.profile
end

-- ------------------------------------------------------------------ link ---

--- Switches this station between standing alone, feeding a ship and being fed
--- by a base. Clearing the arrival set stops the new role from alerting on
--- everyone who happened to be standing there already.
function app:setRole(role)
  self.cfg.role = role
  config.sanitise(self.cfg)
  self.link:attach(self.kit, self.cfg)
  self.link:forget()
  self.previous, self.firstScan = {}, true
  self.scanError = nil
  self:saveConfig()
end

function app:setStationName(name)
  if type(name) ~= "string" or #name == 0 then
    name = config.defaultStationName()
  end
  self.cfg.stationName = name:sub(1, config.MAX_STATION_NAME)
  self:saveConfig()
end

--- Locks this ship onto one base. Everything else on the protocol is ignored
--- from here on, so several base/ship pairs can share a world.
function app:pairWithBase(id, name)
  self.cfg.pairedBaseId = id and math.floor(id) or nil
  self.cfg.pairedBaseName = name
  self.link:forget()
  self.scanError = nil
  self:saveConfig()
end

function app:toggleRelayWeather()
  self.cfg.relayWeather = not self.cfg.relayWeather
  self:saveConfig()
  if self.cfg.relayWeather then self.link:sendEnv(self) end
  return self.cfg.relayWeather
end

function app:toggleAlerts()
  self.cfg.alert = not self.cfg.alert
  self:saveConfig()
end

--- Switches what the scope is centred on and turns with.
---@return string mode The one it landed on
function app:setMode(id)
  self.cfg.mode = id
  config.sanitise(self.cfg)
  -- A new centre and a new thing to turn with. Take a reading now rather than
  -- leaving the scope pointing the old way until the loop next comes round.
  self.headingShown = nil
  pcall(self.readHeading, self)
  self:saveConfig()
  return self.cfg.mode
end

--- Steps to the next mode. The T key and the settings row share this, so both
--- walk the same order.
function app:toggleMode()
  local index = 1
  for i, entry in ipairs(config.MODES) do
    if entry.id == self.cfg.mode then index = i end
  end
  return self:setMode(config.MODES[(index % #config.MODES) + 1].id)
end

function app:setBase(x, y, z, dim)
  self.cfg.baseX, self.cfg.baseY, self.cfg.baseZ = x, y, z
  self.cfg.baseDim = dim
  self:saveConfig()
end

--- Sets the base to wherever the configured player is standing.
---@return boolean ok
---@return string message
function app:setBaseFromPosition()
  local pos = scan.myPosition(self.kit, self.cfg)
  if not pos then
    return false, self.cfg.myName
      and "Could not read your position - are you in range?"
      or "Set your username first."
  end
  self:setBase(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z), pos.dimension)
  return true, string.format("Base set to %d, %d, %d",
    self.cfg.baseX, self.cfg.baseY, self.cfg.baseZ)
end

function app:ignorePlayer(name)
  if not name then return end
  self.ignore[name] = true
  self.previous[name] = nil
  self:saveIgnore()
  self:emit("ignore")
end

function app:unignorePlayer(name)
  if not name then return end
  self.ignore[name] = nil
  -- Clearing the previous entry means they alert again if still present.
  self.previous[name] = nil
  self:saveIgnore()
  self:emit("ignore")
end

function app:ignoreNearest()
  local nearest = self.contacts[1]
  if nearest then self:ignorePlayer(nearest.name) end
  return nearest and nearest.name or nil
end

function app:clearLog()
  self.log:clear()
  self:emit("log")
end

--- Nearest contact, or nil when the sky is clear.
function app:nearest() return self.contacts[1] end

function app:snapshot() return self.env.snapshot end

function app:scene() return (self.env.snapshot or {}).scene end

return app
