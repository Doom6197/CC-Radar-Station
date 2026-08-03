-- The autopilot's control law: differential thrust, steered by where the ship
-- has actually been going.
--
-- WHAT IT DELIBERATELY DOES NOT KNOW
--
--   It never sees a heading. `step()` takes no yaw, no facing and no
--   orientation of any kind -- only a COURSE, which radar/flight.lua derives
--   from the ship's position changing over time. That is the whole design:
--   the computer can read which way the PILOT is looking, and on a ship that
--   is not which way the SHIP is going. Someone turning to look over the rail
--   would otherwise steer the vessel.
--
--   The cost is that a stationary ship has no course at all, so the autopilot
--   opens with a PROBE: both sides equally, straight ahead, until it is moving
--   fast enough for a course to exist. Then it steers. If nothing moves after
--   a few seconds of that, the thrusters are not wired to the inputs it was
--   given, and it says so rather than pushing forever.
--
--   There is no altitude control. The ship holds whatever height it is at.
--
-- HOW IT STEERS
--
--   Two thruster groups, left and right. More thrust on the LEFT yaws the nose
--   to the RIGHT, so the error -- the signed angle from the course being made
--   to the bearing wanted -- is added to the left and taken off the right.
--
--   step() works in a dimensionless 0..1 throttle. What actually reaches the
--   thrusters is a REDSTONE LEVEL, 0 to 15, through level() below -- so the
--   control law never has to think in sixteenths, and the one place the
--   quantisation happens is one function with its own tests.
--
--   Everything is proportional, with three softeners that matter on a slow
--   control loop. A DEADBAND, because a fix a second apart cannot resolve five
--   degrees and chasing it just twitches the ship. A TURN BRAKE, because a
--   vessel at full ahead in the wrong direction is going the wrong way faster.
--   And a SLEW LIMIT, so the outputs walk to their new values instead of
--   slamming, which a heavy contraption cannot follow anyway.
--
-- No peripheral is touched in here. This file decides; radar/modules/flight.lua
-- reads the position, writes the outputs and owns the settings.

local util = require("radar.util")

local autopilot = {}

local abs, floor = math.abs, math.floor

-- How long the ship may be pushed with no measurable movement before the
-- autopilot decides the inputs are not connected to anything.
autopilot.PROBE_SECONDS = 8

-- A fix older than this means the position feed has stopped -- a lost link, a
-- base that unloaded, a username that stopped resolving. The throttles go to
-- zero rather than holding the last command indefinitely.
autopilot.STALE_SECONDS = 5

-- Errors smaller than this are not steered for.
autopilot.DEADBAND_DEGREES = 5

-- Fraction of cruise given up at full deflection, so a hard turn is also a
-- slow one.
autopilot.TURN_BRAKE = 0.6

-- Most any output may move in one step of the control loop.
autopilot.SLEW = 0.25

-- Throttle floor on the approach, so it still arrives rather than creeping.
autopilot.APPROACH_FLOOR = 0.25

--- Everything a phase means, in the order the operator meets them.
autopilot.PHASES = {
  off     = "off",             -- not engaged
  nodest  = "no destination",
  lost    = "target lost",
  nofix   = "no position fix",
  toofar  = "out of range",
  probe   = "finding course",
  steer   = "steering",
  arrived = "arrived",
  stalled = "no movement",
}

--- Phases in which the autopilot has given up rather than merely paused, and
--- is worth raising the alarm about.
autopilot.FAULTS = { stalled = true, nofix = true, lost = true, toofar = true }

-- How far it will fly before shutting itself off, in blocks. A contact that
-- logs out and back in on the far side of the world, or a waypoint typed with
-- one digit too many, otherwise means a ship that leaves and does not come
-- back. `false` is no limit at all, which is a choice rather than a default.
autopilot.RANGES = { 250, 500, 1000, 2500, 5000, false }

function autopilot.phaseLabel(phase)
  return autopilot.PHASES[phase] or tostring(phase)
end

-- Redstone carries sixteen levels and no more, so a 0..1 throttle lands on one
-- of them. That is the resolution the thrusters actually have.
autopilot.MAX_LEVEL = 15

--- A 0..1 throttle as a redstone signal strength.
---
--- Anything above zero comes out as at least 1. Rounding a real command down
--- to "off" would make a thruster that is meant to be idling indistinguishable
--- from one that has been cut, and only one of those is a decision.
---@return number level 0..15
function autopilot.level(throttle)
  throttle = tonumber(throttle) or 0
  if throttle <= 0 then return 0 end
  local level = floor(util.clamp(throttle, 0, 1) * autopilot.MAX_LEVEL + 0.5)
  return math.max(1, math.min(autopilot.MAX_LEVEL, level))
end

--- Walks a value toward a target by at most `limit`.
local function slew(from, to, limit)
  local delta = to - (from or 0)
  if delta > limit then delta = limit elseif delta < -limit then delta = -limit end
  return util.clamp((from or 0) + delta, 0, 1)
end

autopilot.slew = slew

--- One control decision.
---
--- Note what is NOT in the input table: any heading, yaw or facing. `course`
--- is where the ship has been going, measured from its own position.
---
---@param s table {
---   engaged  boolean
---   distance number|nil  blocks to the destination
---   bearing  number|nil  true bearing to it
---   course   number|nil  true bearing the ship is actually making
---   moving   boolean     whether the course means anything yet
---   lost     boolean     the destination is a contact that has gone
---   sinceFix number|nil  seconds since the last position fix
---   probing  number      seconds spent pushing with no course yet
---   previous table|nil   { left, right } last commanded, for the slew limit
---   cfg      table       { cruise, turnFull, arrive, slowWithin }
--- }
---@return table { left, right, phase, message, error, fault }
function autopilot.step(s)
  s = s or {}
  local cfg = s.cfg or {}
  local cruise     = util.clamp(tonumber(cfg.cruise) or 0.6, 0.05, 1)
  local arrive     = math.max(1, tonumber(cfg.arrive) or 25)
  local turnFull   = math.max(10, tonumber(cfg.turnFull) or 60)
  local slowWithin = math.max(arrive, tonumber(cfg.slowWithin) or 120)
  -- false, nil or 0 all mean no limit.
  local range      = tonumber(cfg.range)
  if range and range <= 0 then range = nil end

  local previous = s.previous or {}

  --- Cutting the throttle is never slewed. Everything that reaches here is a
  --- reason to stop, and a ship easing gently out of an emergency is not what
  --- anybody wants.
  local function stop(phase)
    return {
      left = 0, right = 0, phase = phase,
      message = autopilot.phaseLabel(phase),
      fault = autopilot.FAULTS[phase] == true,
    }
  end

  if not s.engaged then return stop("off") end
  if s.lost then return stop("lost") end
  if not s.distance or not s.bearing then return stop("nodest") end
  if s.sinceFix and s.sinceFix > autopilot.STALE_SECONDS then return stop("nofix") end
  -- Checked every step, not only on engaging: a contact that logs out and back
  -- in on the far side of the world moves the destination, not the ship.
  if range and s.distance > range then return stop("toofar") end
  if s.distance <= arrive then return stop("arrived") end

  -- No course yet. The only honest way to learn which way the ship points is
  -- to move it, so push both sides equally and watch.
  if not s.course or not s.moving then
    if (tonumber(s.probing) or 0) >= autopilot.PROBE_SECONDS then
      return stop("stalled")
    end
    local level = slew(previous.left, cruise, autopilot.SLEW)
    return {
      left = level, right = level, phase = "probe",
      message = autopilot.phaseLabel("probe"), fault = false,
    }
  end

  local err = util.angleDelta(s.course, s.bearing)   -- positive: target is right
  local steer = (abs(err) <= autopilot.DEADBAND_DEGREES) and 0
    or util.clamp(err / turnFull, -1, 1)

  -- Ease off near the destination, and while turning hard.
  local approach = util.clamp(s.distance / slowWithin, autopilot.APPROACH_FLOOR, 1)
  local reach = cruise * approach
  local base = reach * (1 - autopilot.TURN_BRAKE * abs(steer))

  return {
    left  = slew(previous.left,  util.clamp(base + steer * reach, 0, 1), autopilot.SLEW),
    right = slew(previous.right, util.clamp(base - steer * reach, 0, 1), autopilot.SLEW),
    phase = "steer",
    message = ("%+d deg"):format(floor(err + (err >= 0 and 0.5 or -0.5))),
    error = err,
    fault = false,
  }
end

return autopilot
