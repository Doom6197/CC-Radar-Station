-- Flight instruments derived from one thing: where the pilot is, sampled over
-- time.
--
-- Nothing here polls anything. Every sweep already produces a position -- read
-- from a local detector, or relayed by the main base -- and differentiating
-- that against the clock gives ground speed, climb rate and course over
-- ground for free. On a MOBILE that means a full instrument panel on a
-- computer carrying nothing but a modem.
--
-- WHAT THIS CANNOT KNOW, and why the labels say what they say:
--
--   It is the PILOT's position, not the ship's. Walking the deck reads as a
--   couple of blocks a second of drift, and stepping off the ship entirely
--   means the panel follows YOU. That is the same caveat the status page has
--   always carried; it is not new here, but it is more visible on a page
--   about motion.
--
--   There is no pitch or roll. getPlayerPos gives a yaw and nothing else, so
--   HEADING is where you are looking, and COURSE is where you are actually
--   going. On an airship being pushed sideways those differ, which is exactly
--   what makes showing both worth the row.
--
--   The sample rate is the sweep interval, so at one second a reading is an
--   average over the last few seconds rather than an instant. Speeds are
--   smoothed for that reason: an unsmoothed number computed from two fixes a
--   second apart jitters far too much to read while flying.

local util = require("radar.util")

local flight = {}
flight.__index = flight

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

-- How far back a reading is measured over. Long enough to be steady, short
-- enough to notice a change of throttle.
flight.WINDOW_SECONDS = 3

-- Fixes kept. At two sweeps a second over a three second window this is
-- comfortably more than needed, and it costs nothing.
flight.CAPACITY = 32

-- Above this, a "movement" is a teleport, a dimension change or a chunk
-- reload rather than flying, and the history is thrown away instead of
-- reporting several thousand blocks a second.
flight.TELEPORT_SPEED = 200

-- Below this, the pilot is standing still and the course is meaningless --
-- two fixes a block apart would otherwise swing the bearing wildly.
flight.MOVING_SPEED = 0.15

-- How much of a new reading is taken each time. Enough to follow a real
-- change within a second or two, not so much that it flickers.
local SMOOTHING = 0.4

-- The turn rate is a derivative of an already smoothed, already averaged
-- signal, so it is smoothed harder still. Unsmoothed it is mostly jitter.
local TURN_SMOOTHING = 0.3

function flight.new()
  local self = setmetatable({}, flight)
  self:reset()
  return self
end

function flight:reset()
  self.fixes = {}
  self.count = 0
  self.head = 0

  self.speed = nil          -- blocks per second over the ground
  self.vertical = nil       -- blocks per second, positive is climbing
  self.course = nil         -- true bearing of travel, nil when stationary
  self.turnRate = nil       -- degrees per second, positive is turning right
  -- Where the NOSE points, which only a vessel that can report its own
  -- orientation knows. nil everywhere else, and the page falls back to the
  -- pilot's facing.
  self.heading = nil
  self.moving = false

  self.courseAt = nil       -- when `course` was last set, for the turn rate
  self.lastCourse = nil

  self.position = nil       -- the most recent fix
  self.dimension = nil
  self.since = nil          -- when this leg started, for a settling hint

  -- "pilot" when everything above was worked out from where the operator is
  -- standing, "ship" when the vessel reported it itself. See applyShip.
  self.source = "pilot"
  return self
end

-- ---------------------------------------------------------------- sampling ---

--- Records where the pilot is. Called from the sweep, so it costs nothing
--- beyond what the station already does.
---@param pos table|nil { x, y, z, dimension }
---@param now number os.clock()
---@return boolean recorded
function flight:sample(pos, now)
  if type(pos) ~= "table" or not tonumber(pos.x) then return false end
  now = now or os.clock()

  -- A different world is a different journey.
  if pos.dimension and self.dimension and pos.dimension ~= self.dimension then
    self:reset()
  end
  self.dimension = pos.dimension or self.dimension

  local previous = self:latest()
  if previous then
    local elapsed = now - previous.at
    -- Two fixes at the same instant carry no information, and dividing by the
    -- gap between them would carry rather too much.
    if elapsed <= 0 then return false end

    local dx, dy, dz = pos.x - previous.x, pos.y - previous.y, pos.z - previous.z
    local jump = sqrt(dx * dx + dy * dy + dz * dz) / elapsed
    if jump > flight.TELEPORT_SPEED then
      self:reset()
      self.dimension = pos.dimension
    end
  end

  self.head = (self.head % flight.CAPACITY) + 1
  self.fixes[self.head] = { x = pos.x, y = pos.y, z = pos.z, at = now }
  if self.count < flight.CAPACITY then self.count = self.count + 1 end
  if not self.since then self.since = now end

  self.position = pos
  -- Back to inferring it. A ship that was reporting for itself and has stopped
  -- -- disassembled, or the operator has stepped onto one that is not a
  -- Sub-Level -- must not go on claiming these are the vessel's own readings.
  self.source = "pilot"
  -- And a heading nobody is reporting any more is not a heading. Dropped
  -- rather than left standing, so the page goes back to the pilot's facing
  -- instead of showing where the ship was pointing a minute ago.
  self.heading = nil
  self:update(now)
  return true
end

function flight:latest()
  if self.count == 0 then return nil end
  return self.fixes[self.head]
end

--- The oldest fix still inside the averaging window, or the oldest there is.
local function windowStart(self, now)
  local oldest = nil
  for i = 0, self.count - 1 do
    local index = ((self.head - i - 1) % flight.CAPACITY) + 1
    local fix = self.fixes[index]
    if not fix then break end
    oldest = fix
    if (now - fix.at) >= flight.WINDOW_SECONDS then break end
  end
  return oldest
end

--- Recomputes the derived readings from the fixes in the window.
function flight:update(now)
  now = now or os.clock()
  local newest = self:latest()
  if not newest or self.count < 2 then return self end

  local oldest = windowStart(self, now)
  if not oldest or oldest == newest then return self end

  local elapsed = newest.at - oldest.at
  if elapsed <= 0 then return self end

  local dx = newest.x - oldest.x
  local dy = newest.y - oldest.y
  local dz = newest.z - oldest.z

  local ground = sqrt(dx * dx + dz * dz) / elapsed
  local climb = dy / elapsed

  -- Smoothed toward the new reading rather than replaced by it.
  self.speed = self.speed and util.lerp(self.speed, ground, SMOOTHING) or ground
  self.vertical = self.vertical and util.lerp(self.vertical, climb, SMOOTHING) or climb

  self.moving = self.speed >= flight.MOVING_SPEED
  -- A course is only meaningful while actually going somewhere; the last one
  -- is kept rather than swinging to nonsense as the ship comes to a stop.
  if ground >= flight.MOVING_SPEED then
    self:setCourse(util.bearingOf(dx, dz), now)
  elseif not self.moving then
    self.course, self.turnRate = nil, nil
    self.courseAt, self.lastCourse = nil, nil
  end

  return self
end

--- Records a new course and works out how fast it is changing.
---
--- The turn rate is what stops the autopilot overshooting. Steering on the
--- error alone, against a course that is averaged over three seconds and then
--- smoothed, means the correction is still going in long after the ship is
--- pointed the right way -- so it sails past, corrects back, and hunts. The
--- rate is what lets it start easing off before the error reaches zero.
---
--- Smoothed harder than the course itself: it is a derivative of an already
--- noisy signal, and an unsmoothed one would be mostly jitter.
function flight:setCourse(course, now)
  local previous, at = self.lastCourse, self.courseAt
  self.course = course

  if previous and at then
    local elapsed = now - at
    if elapsed > 0 then
      local rate = util.angleDelta(previous, course) / elapsed
      self.turnRate = self.turnRate
        and util.lerp(self.turnRate, rate, TURN_SMOOTHING) or rate
    end
  end

  self.lastCourse, self.courseAt = course, now
  return self
end

-- ------------------------------------------------------------ the ship ---

--- Takes the readings straight from the vessel, where it can report them.
---
--- Everything above this line exists to INFER these numbers from a position
--- that arrives once a second: a course averaged over three seconds, a turn
--- rate differentiated out of that and then smoothed. CC: Sable hands them
--- over instead -- current, exact, and about the SHIP rather than about
--- whoever happens to be standing on it. See radar/sable.lua.
---
--- The fix history is deliberately left alone. Nothing here needs it while a
--- reading is arriving, and leaving it intact means that if the ship is
--- disassembled, or the operator walks onto one that is not a Sub-Level, the
--- derived path picks up where it left off rather than from nothing.
---@param reading table from sable.read()
---@return boolean applied
function flight:applyShip(reading, now)
  if type(reading) ~= "table" then return false end
  now = now or os.clock()

  self.source = "ship"
  if reading.position then self.position = reading.position end
  if reading.speed then
    self.speed = reading.speed
    self.moving = reading.speed >= flight.MOVING_SPEED
  end
  if reading.vertical then self.vertical = reading.vertical end

  if reading.course then
    -- Set rather than passed through setCourse: that DERIVES a turn rate from
    -- the change, and there is a real one here that does not need guessing at.
    self.course = reading.course
    self.lastCourse, self.courseAt = reading.course, now
  end
  if reading.yawRate then self.turnRate = reading.yawRate end
  self.heading = reading.heading

  if not self.since then self.since = now end
  return true
end

--- Whether the readings are the ship's own rather than inferred from the
--- pilot's position. Read by the page, so it can say which.
function flight:fromShip() return self.source == "ship" end

-- ---------------------------------------------------------------- readings ---

--- How far the ship is drifting from where it is pointed: the signed angle
--- between the way you are looking and the way you are travelling. On an
--- airship being pushed sideways this is the number that explains it.
---@return number|nil degrees
function flight:drift(heading)
  if not heading or not self.course or not self.moving then return nil end
  return util.angleDelta(heading, self.course)
end

--- Distance and bearing from here to a point. Everything that has a place on
--- the map goes through this -- the base, a contact, a typed-in waypoint --
--- so they all read the same way.
---@return number|nil distance
---@return number|nil bearing
---@return string|nil compass
function flight:vectorTo(x, z)
  local pos = self.position
  if not pos or not tonumber(x) or not tonumber(z) then return nil end
  local dx, dz = x - pos.x, z - pos.z
  return sqrt(dx * dx + dz * dz), util.bearingOf(dx, dz), util.directionOf(dx, dz)
end

--- Distance and bearing back to the configured base coordinates.
---@return number|nil distance
---@return number|nil bearing
---@return string|nil compass
function flight:home(cfg)
  if not cfg or not cfg.baseX then return nil end
  return self:vectorTo(cfg.baseX, cfg.baseZ)
end

--- How long to cover `distance` at the current ground speed. Nil when
--- stopped, because "never" is not a useful number to put on a panel.
---@return number|nil seconds
function flight:eta(distance)
  if not distance or not self.speed or self.speed < flight.MOVING_SPEED then
    return nil
  end
  return distance / self.speed
end

--- Vertical distance from the base's altitude, so a descent onto a pad has
--- something to aim at.
---@return number|nil blocks
function flight:altitudeAboveHome(cfg)
  local pos = self.position
  if not pos or not cfg or not cfg.baseY then return nil end
  return pos.y - cfg.baseY
end

-- --------------------------------------------------------------- printing ---

--- Blocks per second, at a width that fits a fifteen-cell screen.
function flight.formatSpeed(value)
  if type(value) ~= "number" then return "--" end
  if value >= 100 then return ("%d"):format(floor(value + 0.5)) end
  return ("%.1f"):format(value)
end

--- The same, signed, for a climb rate where the sign is the whole point.
function flight.formatVertical(value)
  if type(value) ~= "number" then return "--" end
  if abs(value) < 0.05 then return "0.0" end
  return ("%+.1f"):format(value)
end

--- "1m52", "45s", "2.1h" -- short enough for a narrow column.
function flight.formatEta(seconds)
  if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
    return "--"
  end
  if seconds < 60 then return ("%ds"):format(floor(seconds + 0.5)) end
  if seconds < 3600 then
    return ("%dm%02d"):format(floor(seconds / 60), floor(seconds % 60))
  end
  if seconds < 86400 then return ("%.1fh"):format(seconds / 3600) end
  return "--"
end

--- A bearing as three cells: "210".
function flight.formatBearing(value)
  if type(value) ~= "number" then return "---" end
  return ("%03d"):format(floor(value + 0.5) % 360)
end

--- A bearing with its compass point: "210 SW". Reading a heading off a number
--- takes a moment; reading it off a compass point does not, and both together
--- still fit a fifteen-cell row.
function flight.formatCompass(value)
  if type(value) ~= "number" then return "---" end
  local index = floor((value % 360 + 22.5) / 45) % 8 + 1
  return ("%s %s"):format(flight.formatBearing(value), util.DIR_NAMES[index])
end

return flight
