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
--   It commands a TURN RATE, not a deflection. Two loops:
--
--     outer   the heading error picks a turn rate to ask for -- err/lead
--             degrees a second -- capped at `turnRate`
--     inner   the gap between that and the rate the ship is ACTUALLY making
--             sets the thrust difference
--
--   Steering the thrust difference straight off the error does not work here,
--   and two versions of this proved it. A real airship logged at 26 deg/s of
--   yaw while moving 5 blocks a second -- a ten-block turn radius -- against a
--   position fix that arrives once a second and a course averaged over three.
--   Nothing that commands deflection can control a vehicle that turns that
--   much faster than it can be measured: it spent 60% of a flight at full
--   one-sided thrust, swinging 150 degrees past every turn.
--
--   Capping the RATE fixes that at the root. The ship comes round at a speed
--   the loop can see, the inner loop backs off as the rate builds, and full
--   deflection becomes something that happens for a second at the start of a
--   turn rather than the normal state of affairs.
--
--   The thrust difference is also capped by `turnPower`, and INDEPENDENTLY of
--   cruise. It used to be scaled by it, so turning the cruise throttle up
--   turned the steering gain up with it -- two unrelated things on one knob.
--
--   Around that, three softeners. A DEADBAND, because a fix a second apart
--   cannot resolve five degrees and chasing it just twitches the ship. A TURN
--   BRAKE, because a vessel at full ahead in the wrong direction is going the
--   wrong way faster. And a SLEW LIMIT, so the outputs walk to their new
--   values instead of slamming, which a heavy contraption cannot follow.
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

-- How far the ship has to actually be moving before its course means
-- anything. radar/flight.lua will report one from 0.15 blocks a second, which
-- is enough to know a ship is not parked and nowhere near enough to know which
-- way it points: at 0.19 b/s a real flight logged a course of 90, then 45,
-- then 341 in two seconds, and the autopilot believed all three. Below this it
-- keeps probing rather than steering on noise.
autopilot.COURSE_SPEED = 1.0

-- Once steering, it takes a bigger drop to give up -- otherwise a hard turn,
-- which slows the ship on purpose, would bounce it in and out of the probe.
autopilot.COURSE_SPEED_LOW = 0.5

-- Degrees per second of rate error for full thrust difference. Fixed rather
-- than exposed: the inner loop is self-adjusting -- a sluggish ship saturates
-- it and gets everything `turnPower` allows, an agile one never does -- and a
-- third steering knob would be a third thing to get wrong.
autopilot.RATE_FULL = 12

-- Fraction of cruise given up at full deflection, so a hard turn is also a
-- slow one. Raised from 0.6 in v8.10: a ship that keeps its speed up through a
-- turn covers ground in the wrong direction while it comes round, and arrives
-- on the new heading further from where it wanted to be than when it started.
autopilot.TURN_BRAKE = 0.8

-- Seconds the outer loop aims to close the heading error in: it asks for
-- err/lead degrees a second, capped at the ship's turn rate limit. Bigger is
-- a gentler, wider turn. Overridable per station.
autopilot.LEAD_SECONDS = 4

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
---   speed    number|nil  blocks a second, for whether the course is trusted
---   steering boolean     whether the last pass was steering, for hysteresis
---   sinceFix number|nil  seconds since the last position fix
---   probing  number      seconds spent pushing with no course yet
---   previous table|nil   { left, right } last commanded, for the slew limit
---   cfg      table       { cruise, lead, turnRate, turnPower, arrive,
---                          slowWithin, range }
--- }
---@return table { left, right, phase, message, error, fault }
function autopilot.step(s)
  s = s or {}
  local cfg = s.cfg or {}
  local cruise     = util.clamp(tonumber(cfg.cruise) or 0.6, 0.05, 1)
  local arrive     = math.max(1, tonumber(cfg.arrive) or 25)
  local slowWithin = math.max(arrive, tonumber(cfg.slowWithin) or 120)
  local turnRate   = math.max(1, tonumber(cfg.turnRate) or 8)
  local turnPower  = util.clamp(tonumber(cfg.turnPower) or 0.55, 0.05, 1)
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

  -- No course worth trusting yet. The only honest way to learn which way the
  -- ship points is to move it, so push both sides equally and watch.
  --
  -- The SPEED threshold matters as much as having a course at all: below about
  -- a block a second the position deltas are noise, and a course computed from
  -- noise is a heading the autopilot will chase into a wall. Hysteresis, so a
  -- hard turn slowing the ship does not bounce it in and out of the probe.
  local speed = tonumber(s.speed) or 0
  local floorSpeed = (s.steering == true)
    and autopilot.COURSE_SPEED_LOW or autopilot.COURSE_SPEED
  if not s.course or not s.moving or speed < floorSpeed then
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
  local rate = tonumber(s.turnRate) or 0

  -- OUTER LOOP: what turn rate would close the error in `lead` seconds, capped
  -- at what this ship is allowed to do. The cap is the whole fix: a vessel
  -- that yaws at 26 deg/s cannot be steered by anything watching it once a
  -- second, so it is not allowed to yaw at 26 deg/s.
  local lead = tonumber(cfg.lead) or autopilot.LEAD_SECONDS
  if lead <= 0 then lead = 0.5 end
  local wanted = (abs(err) <= autopilot.DEADBAND_DEGREES) and 0
    or util.clamp(err / lead, -turnRate, turnRate)

  -- INNER LOOP: the thrust difference comes from the gap between the rate
  -- asked for and the rate being made. As the turn builds this closes on its
  -- own and the command backs off -- and if the ship is coming round faster
  -- than asked, it goes negative and pushes the other way, without waiting for
  -- the heading error to change sign.
  local steer = util.clamp((wanted - rate) / autopilot.RATE_FULL, -1, 1)

  -- Ease off near the destination, and while turning hard.
  local approach = util.clamp(s.distance / slowWithin, autopilot.APPROACH_FLOOR, 1)
  local base = cruise * approach * (1 - autopilot.TURN_BRAKE * abs(steer))

  -- The difference is capped on its own account and NOT scaled by cruise, so
  -- the throttle and the steering gain are two separate settings.
  local difference = steer * turnPower

  return {
    left  = slew(previous.left,  util.clamp(base + difference, 0, 1), autopilot.SLEW),
    right = slew(previous.right, util.clamp(base - difference, 0, 1), autopilot.SLEW),
    phase = "steer",
    message = ("%+d deg"):format(floor(err + (err >= 0 and 0.5 or -0.5))),
    error = err,
    turnRate = rate,
    -- The rate asked for, and the deflection that came of it. Reported so the
    -- telemetry shows both halves of the cascade rather than only the output.
    wanted = wanted,
    steer = steer,
    fault = false,
  }
end

return autopilot
