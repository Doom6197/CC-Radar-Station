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

--- The four parts of an orientation quaternion.
---
--- The pose prints one as "w + xi + yj + zk", so that spelling is parsed as
--- well as a plain table -- the field names a quaternion object uses are the
--- one thing about this API that was not established by measurement.
---@return number|nil w, number x, number y, number z
local function quaternion(value)
  if type(value) == "table" then
    local w = tonumber(value.w) or tonumber(value.W)
    local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    if w and x and y and z then return w, x, y, z end
  end

  local text = tostring(value)
  local w = tonumber(text:match("^%s*(%-?[^%s]+)"))
  local function part(letter)
    local sign, magnitude = text:match("([%+%-])%s*([^%s]+)" .. letter)
    local number = tonumber(magnitude)
    if not number then return nil end
    return (sign == "-") and -number or number
  end
  local x, y, z = part("i"), part("j"), part("k")
  if w and x and y and z then return w, x, y, z end
  return nil
end

sable.quaternion = quaternion

--- The compass bearing the ship's nose points along.
---
--- Worked out by ROTATING THE BOW and taking the bearing of where it ends up,
--- flattened onto the ground:
---
---   forward = q * (0, 0, -1) * q'      -- north in the ship's own frame
---   bearing = bearingOf(forward.x, forward.z)
---
--- which comes out of the rotation matrix as
---
---   x = -2(xz + wy)      z = -(1 - 2(xx + yy))
---
--- The obvious alternative -- pulling an Euler yaw out with
--- atan2(2(wy + xz), 1 - 2(yy + zz)) -- is what this replaced, and it was
--- wrong on a vessel that is not level. That expression is the yaw of a
--- particular decomposition, and it MIXES IN pitch and roll: an airship
--- rocking gently at anchor made it wander tens of degrees while the bow had
--- not moved at all. Projecting the bow does not care how the hull is tilted,
--- which is the whole point of a heading.
---
--- The sign falls out of bearingOf rather than being applied by hand, and it
--- agrees with the angular velocity's -- a rotation about +Y is a turn to the
--- left on both. A heading that disagreed with the turn rate about which way
--- is right would be worse than no heading at all.
---
--- WHAT THIS CANNOT KNOW is which way the ship was BUILT.
---
--- The quaternion is the rotation from the Sub-Level's own frame to the
--- world's, and that frame is however the blocks were laid out when the vessel
--- was assembled. Build an airship pointing east and its identity orientation
--- means "facing east"; the same maths on a ship built pointing north gives an
--- answer ninety degrees away. A real one read HDG 012 while making good 106,
--- which is exactly that.
---
--- So this returns the RAW angle and the flight module adds a per-ship trim,
--- set once by matching it to the course in straight flight. There is no
--- formula that could have got it right: the offset is a fact about the
--- shipyard, not about the physics.
---
--- The SIGN is not in question. It shares a frame with the angular velocity,
--- which was measured, and both make a rotation about +Y a turn to the left.
---@return number|nil bearing 0..360
function sable.headingFrom(orientation)
  local w, x, y, z = quaternion(orientation)
  if not w then return nil end

  local forwardX = -2 * (x * z + w * y)
  local forwardZ = -(1 - 2 * (x * x + y * y))

  -- A hull standing on its nose has no bearing to report: the bow projects
  -- onto almost nothing and the answer would be whichever way it happened to
  -- be rolled. Saying nothing beats a number that spins.
  if (forwardX * forwardX + forwardZ * forwardZ) < 1e-6 then return nil end

  return util.bearingOf(forwardX, forwardZ) % 360
end

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

-- Below this the course cannot be trusted well enough to calibrate against.
sable.TRIM_SPEED = 5

--- Where the ship's nose points, with the per-ship trim already added.
---
--- The trim is what turns a raw orientation into a compass bearing; see
--- headingFrom for why no formula could do it. SHIP tracking turns the whole
--- scope by this, so it is read here rather than through the flight model --
--- the radar has to work with the flight page switched off.
---@return number|nil bearing 0..360
function sable.heading(trim, now)
  local reading = sable.read(now)
  if not reading or not reading.heading then return nil end
  return (reading.heading + (tonumber(trim) or 0)) % 360
end

--- The trim that would make the reported heading agree with the course.
---
--- Only ever right in STRAIGHT flight: it assumes the nose is pointed where
--- the ship is going, which is the definition of no sideslip. In a turn, or
--- crabbing, it calibrates the error in -- hence the speed floor, and the
--- warning on the settings row.
---@return number|nil trim
---@return string|nil problem
function sable.trimFor(now)
  local reading = sable.read(now)
  if not reading then return nil, "No Sub-Level under this computer" end
  if not reading.heading then return nil, "The ship reports no orientation" end
  if not reading.course then return nil, "No course to match it to" end
  if (reading.speed or 0) < sable.TRIM_SPEED then
    return nil, "Too slow - fly straight at speed first"
  end
  return math.floor((reading.course - reading.heading) % 360 + 0.5) % 360
end

--- Where the ship is, or nil where there is no ship.
---
--- Separate from read() because the SWEEP wants it as well as the flight page:
--- a radar riding a vessel measures from the vessel, not from whoever happens
--- to be standing on the deck. See scan.shipCentre.
---@return table|nil { x, y, z }
function sable.position(now)
  local reading = sable.read(now)
  return reading and reading.position or nil
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
  if ok and type(pose) == "table" then
    if pose.position then
      local x, y, z = xyz(pose.position)
      if x then reading.position = { x = x, y = y, z = z } end
    end
    -- Where the ship's NOSE points, which is a different thing from where it
    -- is going and a very different thing from where the pilot is looking.
    if pose.orientation then
      reading.heading = sable.headingFrom(pose.orientation)
    end
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
