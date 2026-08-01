-- Application state and the background loops that drive it.
--
-- The UI never talks to a peripheral directly. It reads the tables here and
-- subscribes to four events:
--
--   "scan"    a sweep finished; contacts/centre/scanError are new
--   "env"     the environment snapshot changed
--   "anim"    animation frame; only fired while something animated is visible
--   "config"  settings changed and were written to disk
--
-- Every loop runs as a Basalt schedule, so sleep() is legal inside them and
-- the UI stays responsive throughout.

local basalt      = require("basalt")
local config      = require("radar.config")
local hardware    = require("radar.hardware")
local scan        = require("radar.scan")
local logbook     = require("radar.logbook")
local alertsLib   = require("radar.alerts")
local environment = require("radar.environment")

local app = {}
app.__index = app

local ANIM_FPS = 5

function app.new()
  local cfg, logEntries, ignore, imported = config.load()

  local self = setmetatable({
    cfg = cfg,
    ignore = ignore,
    imported = imported,
    log = logbook.new(logEntries),

    kit = hardware.discover(),

    contacts = {},
    previous = {},        -- name -> true, from the previous sweep
    myPos = nil,
    centre = nil,
    scanError = nil,
    firstScan = true,
    lastScanAt = 0,

    anim = 0,
    animWanted = 0,       -- number of visible views asking for frames

    listeners = {},
    running = true,
  }, app)

  self.env = environment.new()
  self.alerts = alertsLib.new(cfg, self.kit)
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
  self.kit = hardware.discover()
  self.alerts:setKit(self.kit)
  for _, monitor in ipairs(self.kit.monitors) do
    if not self.cfg.displays[monitor.name] then
      self.cfg.displays[monitor.name] = { page = "radar", scale = 0.5 }
    end
  end
  self:saveConfig()
  self:emit("hardware")
end

function app:displayConfig(name)
  local entry = self.cfg.displays[name]
  if not entry then
    entry = { page = "radar", scale = 0.5 }
    self.cfg.displays[name] = entry
  end
  return entry
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
  self.alerts:trigger(arrivals)
  self:emit("contact", arrivals)
end

function app:sweep()
  local myPos, contacts, centre, err = scan.run(self.kit, self.cfg, self.ignore)
  self.scanError = err
  self.myPos = myPos
  self.centre = centre or self.centre
  if not err then self.contacts = contacts end

  self.alerts.contacts = self.contacts
  self:processDetections(self.contacts, err ~= nil)
  self.alerts:updateRedstone()
  self.lastScanAt = os.clock()
  self:emit("scan")
end

function app:pollEnvironment(force)
  self.env:poll(self.kit, self.cfg, force)
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

  basalt.schedule(function()
    while self.running do
      sleep(1 / ANIM_FPS)
      if self.cfg.animate and self.animWanted > 0 then
        self.anim = self.anim + 1 / ANIM_FPS
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
end

function app:stop()
  self.running = false
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

function app:toggleAlerts()
  self.cfg.alert = not self.cfg.alert
  self:saveConfig()
end

function app:toggleMode()
  self.cfg.mode = (self.cfg.mode == "fixed") and "self" or "fixed"
  self:saveConfig()
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
