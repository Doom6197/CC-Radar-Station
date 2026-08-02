-- Energy monitoring: what is flowing, what is stored, and what it did lately.
--
-- Two quite different kinds of peripheral answer questions about power, and
-- the useful picture needs both:
--
--   a METER sits inline in a cable and reports a transfer RATE. The Advanced
--   Peripherals Energy Detector is one, and it also carries a settable limit,
--   so it doubles as a throttle. A meter knows nothing about storage.
--
--   a STORE is a battery wrapped directly -- an induction matrix, an energy
--   cell, a flux point. It reports STORED and CAPACITY, which no meter can,
--   and some of them report their own last input and output as well.
--
-- Everything here is matched on METHOD NAME rather than on peripheral type,
-- exactly as radar/hardware.lua matches its detectors, because the mods that
-- expose energy all spell it slightly differently and none of them are worth
-- naming in code that has to run on a pack that may not have them installed.
-- A block answering getEnergy() and getMaxEnergy() is a battery, whatever mod
-- it came from and whatever this file was written before.
--
-- Nothing here touches the UI. The page reads these tables; the settings page
-- writes the roles and thresholds; the alert path is handed a fraction.

local util = require("radar.util")

local power = {}
power.__index = power

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- Ticks per second, for turning a change in stored energy into a rate. The
-- mods all quote rates per TICK, so a readout in FE/t has to match.
local TICKS_PER_SECOND = 20

-- How far the buffer has to climb back above the alarm threshold before the
-- alarm re-arms. Without it a buffer sitting exactly on the line alarms on
-- every single poll.
power.ALARM_HYSTERESIS = 5

-- ---------------------------------------------------------------- probing ---

-- Probed in order; the first method that exists wins. Ordered most specific
-- first, so a peripheral offering several spellings is read the way its own
-- mod documents rather than through a generic alias.
local STORED_METHODS = {
  "getEnergy", "getEnergyStored", "getStoredEnergy", "getEnergyStorage",
}
local CAPACITY_METHODS = {
  "getEnergyCapacity", "getMaxEnergy", "getMaxEnergyStored",
  "getEnergyMaxStorage", "getCapacity",
}
local RATE_METHODS = {
  "getTransferRate", "getEnergyTransfer", "getThroughput",
}
local INPUT_METHODS = {
  "getLastInput", "getInput", "getInputRate", "getEnergyInput",
}
local OUTPUT_METHODS = {
  "getLastOutput", "getOutput", "getOutputRate", "getEnergyOutput",
}
local LIMIT_GET = { "getTransferRateLimit" }
local LIMIT_SET = { "setTransferRateLimit" }

--- First method on `p` from `names`, or nil, plus the name it was found under.
local function pick(p, names)
  for _, name in ipairs(names) do
    if type(p[name]) == "function" then return p[name], name end
  end
  return nil
end

-- ------------------------------------------------------------------ units ---
-- Mods do not agree on what a number means. Most quote Forge Energy; Mekanism
-- quotes JOULES, and its API keeps doing so whatever the client is set to
-- display -- so a Basic Energy Cube holding 1.6 MFE answers getMaxEnergy()
-- with 4,000,000, and reporting that as FE overstates it by exactly 2.5x.
--
-- Everything is therefore read raw and scaled on the way into the totals, per
-- device, so one grid can mix a Mekanism induction matrix with an Energy
-- Detector and still add up.

power.JOULES_PER_FE = 2.5

power.UNITS = {
  { id = "fe", label = "FE / RF", factor = 1,
    hint = "the number as reported" },
  { id = "j",  label = "Mekanism Joules", factor = 1 / power.JOULES_PER_FE,
    hint = "2.5 J = 1 FE" },
}

function power.unit(id)
  for _, entry in ipairs(power.UNITS) do
    if entry.id == id then return entry end
  end
  return power.UNITS[1]
end

-- Methods only Mekanism's ComputerCraft integration exposes. `getMaxEnergy` on
-- its own is the weakest of the three, so it is only trusted when the device
-- offers no Forge-style capacity call at all.
local MEKANISM_METHODS = {
  "getEnergyFilledPercentage", "getEnergyNeeded", "getTotalEnergy",
  "getMaxEnergy",
}

--- Which unit a device probably reports in. Only ever a starting point: it is
--- shown on the device and can be overridden, because guessing wrong by 2.5x
--- is exactly the kind of error that looks plausible until you check it.
---@return string id
function power.guessUnit(p, capacityMethod)
  if type(p) ~= "table" then return "fe" end
  -- A Forge-style capacity call means a Forge-style number.
  if capacityMethod == "getEnergyCapacity"
     or capacityMethod == "getMaxEnergyStored"
     or capacityMethod == "getEnergyMaxStorage" then
    return "fe"
  end
  for _, name in ipairs(MEKANISM_METHODS) do
    if type(p[name]) == "function" then return "j" end
  end
  return "fe"
end

--- The unit a device is being read in, and the factor that turns its readings
--- into FE.
function power.unitOf(cfg, source)
  local chosen = ((cfg.power or {}).units or {})[source.key or source.name]
  for _, entry in ipairs(power.UNITS) do
    if entry.id == chosen then return entry end
  end
  return power.unit(source.guessedUnit or "fe")
end

--- Calls a probed method and returns a number, or nil if it threw or answered
--- with something that is not one. Every one of these is a server-thread call
--- that a half-loaded chunk can refuse.
local function readNumber(fn)
  if not fn then return nil end
  local ok, value = pcall(fn)
  if not ok then return nil end
  value = tonumber(value)
  if not value or value ~= value then return nil end
  return value
end

--- Whether a peripheral looks like anything this module can use.
function power.looksLikeEnergy(p)
  if type(p) ~= "table" then return false end
  if pick(p, RATE_METHODS) then return true end
  return pick(p, STORED_METHODS) ~= nil and pick(p, CAPACITY_METHODS) ~= nil
end

--- Builds a source descriptor from a wrapped peripheral, or nil.
function power.describe(name, p, ptype)
  if type(p) ~= "table" then return nil end

  local rate     = pick(p, RATE_METHODS)
  local stored   = pick(p, STORED_METHODS)
  local capacity, capacityMethod = pick(p, CAPACITY_METHODS)
  local isStore  = stored ~= nil and capacity ~= nil

  if not rate and not isStore then return nil end

  return {
    name = name,
    key  = name,          -- what a role is stored against; see roleOf
    dev  = p,
    ptype = ptype,
    meter = rate ~= nil,
    store = isStore,

    -- Which unit this device probably talks in, until told otherwise.
    guessedUnit = power.guessUnit(p, capacityMethod),
    capacityMethod = capacityMethod,

    _rate     = rate,
    _stored   = isStore and stored or nil,
    _capacity = isStore and capacity or nil,
    _input    = pick(p, INPUT_METHODS),
    _output   = pick(p, OUTPUT_METHODS),
    _limitGet = pick(p, LIMIT_GET),
    _limitSet = pick(p, LIMIT_SET),

    -- Last readings. RAW is what the peripheral said; the unscaled fields are
    -- the same numbers in FE, recomputed from raw on every poll. Keeping the
    -- two apart is what stops a unit conversion compounding each time round.
    rawRate = nil, rawStored = nil, rawCapacity = nil,
    rawInput = nil, rawOutput = nil,

    rate = nil, stored = nil, capacity = nil,
    input = nil, output = nil, limit = nil,
    fault = nil,
  }
end

-- --------------------------------------------------------------- history ---
-- A ring of three parallel arrays rather than an array of sample tables: at
-- one sample a second over fifteen minutes that is 900 entries, and 900 small
-- tables is a lot of garbage for a computer with a modest memory budget.

local History = {}
History.__index = History

local function newHistory(capacity)
  return setmetatable({
    cap = max(2, floor(capacity or 300)),
    n = 0, head = 0,
    ins = {}, outs = {}, pct = {},
    _cache = nil,
  }, History)
end

function History:push(input, output, percent)
  self.head = (self.head % self.cap) + 1
  self.ins[self.head]  = input
  self.outs[self.head] = output
  self.pct[self.head]  = percent
  if self.n < self.cap then self.n = self.n + 1 end
  self._cache = nil
end

function History:resize(capacity)
  capacity = max(2, floor(capacity or self.cap))
  if capacity == self.cap then return self end
  -- Keep the most recent samples that still fit; anything older belongs to a
  -- window the operator has just said they are not interested in.
  local ins, outs, pct = self:series()
  local keep = min(#ins, capacity)
  local first = #ins - keep + 1

  self.cap, self.n, self.head = capacity, 0, 0
  self.ins, self.outs, self.pct, self._cache = {}, {}, {}, nil
  for i = first, #ins do self:push(ins[i], outs[i], pct[i]) end
  return self
end

function History:clear()
  self.n, self.head = 0, 0
  self.ins, self.outs, self.pct, self._cache = {}, {}, {}, nil
  return self
end

--- Oldest first, as three plain arrays the chart can walk. Memoised, because
--- a page with three series on it would otherwise rebuild the whole ring three
--- times on every single frame.
function History:series()
  if self._cache then
    return self._cache[1], self._cache[2], self._cache[3]
  end
  local ins, outs, pct = {}, {}, {}
  local start = (self.n < self.cap) and 1 or (self.head % self.cap) + 1
  for i = 0, self.n - 1 do
    local index = ((start + i - 1) % self.cap) + 1
    ins[i + 1]  = self.ins[index]
    outs[i + 1] = self.outs[index]
    pct[i + 1]  = self.pct[index]
  end
  self._cache = { ins, outs, pct }
  return ins, outs, pct
end

power.newHistory = newHistory

-- ------------------------------------------------------------------ model ---

-- How long a power client may go quiet before its readings are dropped. Long
-- enough to ride out a slow tick, short enough that a client whose chunk has
-- unloaded stops being counted as supply that is not actually there.
power.CLIENT_STALE = 15

function power.new()
  return setmetatable({
    sources = {},          -- energy peripherals wired to THIS computer
    clients = {},          -- computer id -> { id, name, at, interval, sources }

    available = false,     -- anything at all attached or reporting
    hasRate = false,       -- a real rate, rather than one inferred from storage
    hasStore = false,
    relayed = false,       -- these totals arrived whole from the main base

    input = 0, output = 0, net = 0,
    stored = nil, capacity = nil, percent = nil,

    history = newHistory(300),
    lastAt = nil,
    lastStored = nil,

    low = false,           -- the buffer is under the alarm threshold
    lowSince = nil,
    error = nil,
  }, power)
end

--- Rebuilds the local source list from the hardware kit. Clients are left
--- alone: they are not this computer's hardware, and a rescan here says
--- nothing about whether they are still broadcasting.
function power:attach(kit, cfg)
  local sources = {}
  for _, entry in ipairs(kit.energy or {}) do
    sources[#sources + 1] = entry
  end
  self.sources = sources
  self.available = #sources > 0 or next(self.clients) ~= nil
  if cfg then self:applyWindow(cfg) end
  return self
end

-- ---------------------------------------------------------------- clients ---
-- A power client is a computer wired to meters or batteries somewhere else,
-- broadcasting what it reads. Several can report at once; they are merged by
-- computer id, so one going quiet drops out on its own.

--- Takes one broadcast from a client and files its readings.
---
--- Nothing is trusted beyond its shape: a client is another computer on an
--- open network, and a malformed payload must not be able to put a nil into
--- the middle of a total.
---@return boolean accepted
function power:applyClient(id, message, now)
  if type(id) ~= "number" or type(message) ~= "table" then return false end
  if type(message.s) ~= "table" then return false end

  local name = type(message.n) == "string" and message.n:sub(1, 24)
    or ("Computer " .. id)

  local sources = {}
  for _, entry in ipairs(message.s) do
    if type(entry) == "table" and type(entry.n) == "string" then
      local stored = tonumber(entry.s)
      local capacity = tonumber(entry.c)
      local isStore = stored ~= nil and capacity ~= nil and capacity > 0
      sources[#sources + 1] = {
        name   = entry.n,
        -- Keyed by the computer that reported it, so two clients with a
        -- peripheral of the same name keep their own roles and units.
        key    = id .. ":" .. entry.n,
        remote = true,
        client = name,
        clientId = id,
        meter  = entry.m == 1 or tonumber(entry.r) ~= nil,
        store  = isStore,

        -- Raw, exactly as the client read it. The unit conversion happens on
        -- the base along with everything else, so it is one decision in one
        -- place rather than one per client.
        rawRate   = tonumber(entry.r),
        rawStored = isStore and stored or nil,
        rawCapacity = isStore and capacity or nil,
        rawInput  = tonumber(entry.i),
        rawOutput = tonumber(entry.o),
        limit  = tonumber(entry.l),

        -- What the client guessed from the methods the peripheral offered.
        guessedUnit = (entry.u == "j") and "j" or "fe",
      }
    end
  end

  self.clients[id] = {
    id = id,
    name = name,
    at = now or os.clock(),
    interval = tonumber(message.i),
    sources = sources,
  }
  self.available = true
  return true
end

--- Forgets clients that have stopped reporting.
---@return boolean dropped Whether anything went
function power:forgetStale(now)
  now = now or os.clock()
  local dropped = false
  for id, client in pairs(self.clients) do
    local limit = math.max(power.CLIENT_STALE, 3 * (client.interval or 2))
    if (now - client.at) > limit then
      self.clients[id] = nil
      dropped = true
    end
  end
  return dropped
end

--- Every client currently reporting, newest name order, for the settings page.
function power:clientList()
  local list = {}
  for _, client in pairs(self.clients) do list[#list + 1] = client end
  table.sort(list, function(a, b)
    if a.name == b.name then return a.id < b.id end
    return a.name < b.name
  end)
  return list
end

--- Local sources and every client's, as one list. This is what the totals,
--- the settings page and the device picker all walk, so a meter three rooms
--- away is treated exactly like one on the side of this computer.
function power:allSources()
  local out = {}
  for _, source in ipairs(self.sources) do out[#out + 1] = source end
  for _, client in ipairs(self:clientList()) do
    for _, source in ipairs(client.sources) do out[#out + 1] = source end
  end
  return out
end

--- Resizes the history to match the configured window and sample rate.
function power:applyWindow(cfg)
  local settings = cfg.power or {}
  local window = tonumber(settings.windowSeconds) or 300
  local every  = tonumber(settings.sampleSeconds) or 1
  self.history:resize(floor(window / max(0.5, every)) + 1)
  return self
end

--- What role a source plays. Meters are inbound by default: one detector on
--- the main bus is measuring supply, which is the common case.
function power.roleOf(cfg, source)
  local roles = (cfg.power or {}).roles or {}
  local role = roles[source.key or source.name]
  if role == "in" or role == "out" or role == "off" then return role end
  return source.meter and "in" or "off"
end

-- ---------------------------------------------------------------- polling ---

--- Reads every source once and recomputes the totals.
---@param cfg table Settings
---@param now? number os.clock(), injectable so the maths can be tested
function power:poll(cfg, now)
  now = now or os.clock()

  local settings = cfg.power or {}
  local input, output = 0, 0
  local stored, capacity = nil, nil
  local sawRate, sawStore = false, false
  local faults = 0

  -- A client that has stopped reporting must stop counting first, or a
  -- reactor whose chunk has unloaded goes on being counted as supply.
  self:forgetStale(now)

  -- Local peripherals are read now; a client's were read on the client and
  -- arrived over the network. From here down the two are the same thing.
  for _, source in ipairs(self.sources) do
    source.fault = nil

    if source.meter then
      source.rawRate = readNumber(source._rate)
      if not source.rawRate then source.fault = "no rate" end
      source.limit = readNumber(source._limitGet)
    end

    if source.store then
      source.rawStored = readNumber(source._stored)
      source.rawCapacity = readNumber(source._capacity)
      if not (source.rawStored and source.rawCapacity and source.rawCapacity > 0)
         and not source.fault then
        source.fault = "no reading"
      end
      source.rawInput = readNumber(source._input)
      source.rawOutput = readNumber(source._output)
    end
  end

  for _, source in ipairs(self:allSources()) do
    if source.fault then faults = faults + 1 end

    -- Everything is scaled into FE here, once, from the raw reading -- so a
    -- Mekanism battery quoting Joules adds up against an Energy Detector
    -- quoting FE instead of overstating itself by two and a half times.
    local unit = power.unitOf(cfg, source)
    local factor = unit.factor
    source.unit = unit.id

    source.rate = source.rawRate and (source.rawRate * factor) or nil
    source.stored = source.rawStored and (source.rawStored * factor) or nil
    source.capacity = source.rawCapacity and (source.rawCapacity * factor) or nil
    source.input = source.rawInput and (source.rawInput * factor) or nil
    source.output = source.rawOutput and (source.rawOutput * factor) or nil

    if source.meter and source.rate then
      sawRate = true
      local role = power.roleOf(cfg, source)
      if role == "in" then input = input + abs(source.rate)
      elseif role == "out" then output = output + abs(source.rate) end
    end

    if source.store and source.stored and source.capacity and source.capacity > 0 then
      sawStore = true
      stored = (stored or 0) + source.stored
      capacity = (capacity or 0) + source.capacity
    end

    -- A battery that reports its own throughput is better than anything
    -- inferred, so it contributes whatever role the meters did not.
    if source.input or source.output then
      sawRate = true
      input = input + abs(source.input or 0)
      output = output + abs(source.output or 0)
    end
  end

  self.hasRate  = sawRate
  self.hasStore = sawStore
  self.stored   = stored
  self.capacity = capacity
  self.percent  = (stored and capacity and capacity > 0)
    and util.clamp(stored / capacity * 100, 0, 100) or nil

  -- With no meter anywhere, the change in stored energy IS the net rate. It is
  -- coarser than a detector -- it cannot separate supply from demand, only the
  -- balance of the two -- but it is the difference between a useful page and
  -- an empty one on a base whose only energy peripheral is its battery.
  if not sawRate and stored then
    local elapsed = self.lastAt and (now - self.lastAt) or 0
    if self.lastStored and elapsed > 0.05 then
      local perTick = (stored - self.lastStored) / (elapsed * TICKS_PER_SECOND)
      if perTick >= 0 then input, output = perTick, 0
      else input, output = 0, -perTick end
    end
  end

  self.input, self.output = input, output
  self.net = input - output
  self.lastAt, self.lastStored = now, stored
  self.relayed = false

  self.available = #self.sources > 0 or next(self.clients) ~= nil

  self.error = nil
  if not self.available then
    self.error = "No energy peripheral and no power client"
  elseif faults > 0 and not sawRate and not sawStore then
    self.error = "Energy peripherals are not answering"
  end

  self:sample(settings)
  return self
end

-- ----------------------------------------------------------------- relayed ---
-- A MOBILE has nothing to read and no client of its own; the main base sends
-- it the finished totals. They land in exactly the fields a local poll would
-- have filled, so the page cannot tell which it is drawing.

--- Applies totals relayed by the main base.
---@return boolean accepted
function power:applyRelay(message, now)
  if type(message) ~= "table" then return false end
  local input = tonumber(message.i)
  local output = tonumber(message.o)
  if not input or not output then return false end

  self.input, self.output = input, output
  self.net = input - output
  self.stored = tonumber(message.s)
  self.capacity = tonumber(message.c)
  self.percent = (self.stored and self.capacity and self.capacity > 0)
    and util.clamp(self.stored / self.capacity * 100, 0, 100) or nil

  self.hasRate = message.r == 1
  self.hasStore = self.percent ~= nil
  self.deviceCount = tonumber(message.d) or 0
  self.available = true
  self.relayed = true
  self.relayAt = now or os.clock()
  self.relayInterval = tonumber(message.n)
  self.error = nil

  self:sample()
  return true
end

--- What a main base puts on the wire. Only the totals: a mobile has no use
--- for which of forty peripherals contributed what, and the whole point of
--- the client mesh is that the main base has already done that work.
function power:relayPayload()
  return {
    i = self.input, o = self.output,
    s = self.stored, c = self.capacity,
    r = self.hasRate and 1 or nil,
    d = #self:allSources(),
  }
end

--- Whether relayed totals are recent enough to keep drawing, which is what
--- tells a mobile not to bother polling hardware it does not have.
function power:relayFresh(now)
  if not self.relayAt then return false end
  local limit = math.max(8, 3 * (self.relayInterval or 2))
  return ((now or os.clock()) - self.relayAt) <= limit
end

--- Pushes the current reading into the rolling history.
function power:sample()
  self.history:push(self.input, self.output, self.percent)
  return self
end

-- ----------------------------------------------------------------- alarms ---

--- Whether the buffer has just crossed below the alarm threshold.
---
--- Returns true exactly once per crossing, so the caller can fire the sound,
--- flash and redstone without a rearming rule of its own.
---@return boolean crossed
function power:checkAlarm(cfg, now)
  local settings = cfg.power or {}
  local percent = self.percent

  if not settings.alarm or not percent then
    self.low, self.lowSince = false, nil
    return false
  end

  local threshold = tonumber(settings.lowPercent) or 20
  if self.low then
    if percent >= threshold + power.ALARM_HYSTERESIS then
      self.low, self.lowSince = false, nil
    end
    return false
  end

  if percent <= threshold then
    self.low = true
    self.lowSince = now or os.clock()
    return true
  end
  return false
end

--- Buffer fullness as 0..1, for the analog redstone output. Nil when there is
--- no buffer to report, so the redstone line can tell "empty" from "unknown"
--- and hold rather than dropping a fuel gate open.
function power:fraction()
  if not self.percent then return nil end
  return self.percent / 100
end

-- ------------------------------------------------------------- the limit ---

--- Writes an Energy Detector's transfer limit. This is the one thing in the
--- station that changes the world rather than reporting on it, so it is a
--- deliberate call from a settings row and never happens on a poll.
---@return boolean ok
---@return string message
function power:setLimit(source, value)
  if not source or not source._limitSet then
    return false, "That device has no settable limit"
  end
  value = tonumber(value)
  if not value or value < 0 then return false, "Not a valid limit" end
  local ok, err = pcall(source._limitSet, floor(value))
  if not ok then return false, "Refused: " .. tostring(err) end
  source.limit = readNumber(source._limitGet)
  return true, ("Limit set to %s/t"):format(power.format(value))
end

function power:sourceByName(name)
  for _, source in ipairs(self.sources) do
    if source.name == name then return source end
  end
  return nil
end

--- Any source, local or on a client, by the key its role is stored against.
function power:sourceByKey(key)
  for _, source in ipairs(self:allSources()) do
    if source.key == key then return source end
  end
  return nil
end

-- --------------------------------------------------------------- printing ---

--- Compact energy figure: 940, 12.3k, 4.56M, 1.2G.
--- Energy numbers span ten orders of magnitude on a modded server, so a raw
--- figure is unreadable and a fixed unit is wrong somewhere.
function power.format(value)
  if type(value) ~= "number" or value ~= value then return "-" end
  local sign = value < 0 and "-" or ""
  local n = abs(value)
  if n < 1000 then
    return sign .. tostring(floor(n + 0.5))
  elseif n < 1e6 then
    return ("%s%.1fk"):format(sign, n / 1e3)
  elseif n < 1e9 then
    return ("%s%.2fM"):format(sign, n / 1e6)
  elseif n < 1e12 then
    return ("%s%.2fG"):format(sign, n / 1e9)
  end
  return ("%s%.2fT"):format(sign, n / 1e12)
end

--- The same, signed even when positive, for a net figure where the sign is
--- the whole point.
function power.formatSigned(value)
  if type(value) ~= "number" then return "-" end
  if value > 0 then return "+" .. power.format(value) end
  return power.format(value)
end

--- "5 minutes", "90 seconds" -- for the graph window and the time to empty.
function power.duration(seconds)
  if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then return "-" end
  if seconds < 90 then return ("%ds"):format(floor(seconds + 0.5)) end
  if seconds < 5400 then return ("%.0fm"):format(seconds / 60) end
  if seconds < 86400 then return ("%.1fh"):format(seconds / 3600) end
  return ("%.1fd"):format(seconds / 86400)
end

--- How long until the buffer empties at the current net rate, or fills. Nil
--- when it is not going anywhere, which is the healthy steady state.
---@return number|nil seconds
---@return string direction "empty" or "full"
function power:timeToLimit()
  if not self.stored or not self.capacity or self.capacity <= 0 then return nil end
  local perSecond = self.net * TICKS_PER_SECOND
  if abs(perSecond) < 1e-6 then return nil end

  -- A buffer already at the limit is not "full in 0s"; it is full, and the
  -- surplus is going nowhere. Same at the bottom.
  local remaining = (perSecond < 0) and self.stored or (self.capacity - self.stored)
  if remaining <= 0 then return nil end

  return remaining / abs(perSecond), (perSecond < 0) and "empty" or "full"
end

--- One word for what the buffer is doing, or nil when there is no buffer.
--- Separate from timeToLimit so a bank sitting at either end reads as a state
--- rather than as a countdown that never finishes.
---@return string|nil
function power:bufferState()
  if not self.percent then return nil end
  if self.percent >= 99.5 then return "full" end
  if self.percent <= 0.5 then return "empty" end
  return nil
end

power.TICKS_PER_SECOND = TICKS_PER_SECOND

return power
