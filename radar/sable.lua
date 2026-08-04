-- Reading the ship itself, on a computer riding one.
--
-- CC: Sable gives a computer standing on a Create: Simulated Sub-Level a
-- `sublevel` global: the physics object's own position, orientation, linear
-- velocity and angular velocity. Where it exists, every instrument on the
-- flight page stops being an inference and becomes a reading.
--
-- WHAT THAT IS WORTH
--
--   Without it the turn rate is manufactured: position at the sweep rate, a
--   course averaged over three seconds, differentiated, then smoothed. That is
--   roughly four seconds of lag on the one number the autopilot's inner loop
--   runs on, and a logged flight had it reading about half the true value.
--   Every softener in radar/autopilot.lua -- the lead term, the rate cap, the
--   dither, the speed floor -- exists to survive that. Here it is exact and
--   current.
--
--   It is also the SHIP. The derived path can only ever watch the PILOT, so
--   walking the deck read as drift and stepping off meant the panel followed
--   you. Not any more, on a vessel that has this.
--
-- UNITS AND SIGN, measured rather than assumed
--
--   Linear velocity is blocks per second. Angular velocity is RADIANS PER
--   SECOND about each axis, and with +Y up the y component is the yaw --
--   NEGATIVE for a turn to the right, because it is a right-handed frame and a
--   compass is not.
--
--   Both were established by logging a real flight and regressing the reported
--   y against the yaw rate implied by the velocity vector, which is an
--   independent measurement: it came out at -53.9 deg/s per unit against
--   -57.296 for radians, the remaining 6% being the ship's sideslip, since a
--   vessel crabbing sideways yaws slightly faster than its course rotates.
--
--   Getting that sign wrong would not be subtle. The rate term would add to
--   the heading error instead of opposing it, and the autopilot would diverge
--   on its first correction.
--
-- Nothing here is required. Every function answers "no" on a computer without
-- the mod, on one that is not standing on a Sub-Level, and on the desktop test
-- harness -- and radar/flight.lua falls back to deriving it all from position,
-- exactly as it always did.

local util = require("radar.util")

local sable = {}

-- Radians per second to degrees per second, negated: +y is anticlockwise seen
-- from above, and every bearing in this program is a compass bearing.
local YAW_SCALE = -180 / math.pi

-- Readings are cached this long. The page draws far more often than the ship
-- moves, and there is no reason to ask the physics engine twice in a frame.
sable.CACHE_SECONDS = 0.2

-- Below this the velocity vector has no meaningful direction. Far lower than
-- the derived path's floor: this is a real velocity, not two positions
-- subtracted, so it does not need speed to be trustworthy -- only to exist.
sable.COURSE_SPEED = 0.05

local state = {
  at = nil,          -- when `last` was read
  last = nil,        -- the last reading handed out
  yawRate = nil,     -- held across dropouts; see below
}

--- The three components of whatever the API hands back.
---
--- The probe showed these arrive as CC vectors, but a table with x/y/z and a
--- bare "x,y,z" string are both accepted rather than insisted against.
local function xyz(value)
  if type(value) == "table" and tonumber(value.x) then
    return tonumber(value.x), tonumber(value.y) or 0, tonumber(value.z) or 0
  end
  local x, y, z = tostring(value):match("([^,]+),([^,]+),([^,]+)")
  return tonumber(x), tonumber(y), tonumber(z)
end

sable.xyz = xyz

--- The `sublevel` global, or nil where there is none.
---
--- Read through _G rather than named directly, so this file is honest about
--- the thing being optional and the test harness can put one there.
function sable.api()
  local api = rawget(_G, "sublevel")
  if type(api) ~= "table" then return nil end
  return api
end

--- Whether this computer is on a Sub-Level right now.
---
--- Both halves matter: the mod may be installed on a computer that is bolted
--- to the ground, in which case none of the readings mean anything.
function sable.available()
  local api = sable.api()
  if not api or type(api.isInPlotGrid) ~= "function" then return false end
  local ok, on = pcall(api.isInPlotGrid)
  return ok and on == true
end

--- Forgets the cache and the held turn rate, for a rescan or a fresh start.
function sable.forget()
  state.at, state.last, state.yawRate = nil, nil, nil
  return sable
end

--- Everything the flight page needs, in this program's units.
---
--- @return table|nil { position = {x,y,z}, speed, vertical, course, yawRate }
function sable.read(now)
  now = now or os.clock()
  if state.at and (now - state.at) < sable.CACHE_SECONDS then return state.last end
  if not sable.available() then
    state.at, state.last = now, nil
    return nil
  end

  local api = sable.api()
  local reading = {}

  local ok, pose = pcall(api.getLogicalPose)
  if ok and type(pose) == "table" and pose.position then
    local x, y, z = xyz(pose.position)
    if x then reading.position = { x = x, y = y, z = z } end
  end

  local gotVelocity, velocity = pcall(api.getLinearVelocity)
  if gotVelocity then
    local vx, vy, vz = xyz(velocity)
    if vx then
      reading.vertical = vy
      local ground = math.sqrt(vx * vx + vz * vz)
      reading.speed = ground
      -- The course comes straight off the velocity vector, so it is where the
      -- ship is going THIS INSTANT rather than an average of where it has
      -- been. That is the whole difference.
      if ground >= sable.COURSE_SPEED then
        reading.course = util.bearingOf(vx, vz)
      end
    end
  end

  local gotAngular, angular = pcall(api.getAngularVelocity)
  if gotAngular then
    local ax, ay, az = xyz(angular)
    if ax then
      -- An exact 0,0,0 is a DROPPED READING, not a still ship. A real flight
      -- log had two of them in 197 samples while the vessel was doing 18
      -- blocks a second, and an autopilot that believed them would decide the
      -- turn had stopped and put in a correction that was not wanted.
      if ax == 0 and ay == 0 and az == 0 then
        reading.yawRate = state.yawRate
        reading.held = state.yawRate ~= nil
      else
        reading.yawRate = ay * YAW_SCALE
        state.yawRate = reading.yawRate
      end
    end
  end

  -- A reading with nothing in it is not a reading.
  if reading.position == nil and reading.speed == nil then
    state.at, state.last = now, nil
    return nil
  end

  state.at, state.last = now, reading
  return reading
end

return sable
