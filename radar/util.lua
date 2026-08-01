-- Small shared helpers. No Basalt or peripheral dependencies, so this module
-- stays loadable even when the rest of the station cannot start.

local util = {}

-- math.atan2 exists in Lua 5.1 (Cobalt) but was removed in 5.3+, where
-- math.atan takes two arguments instead. Support both.
function util.atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  return math.atan(y, x)
end

function util.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function util.round(v) return math.floor(v + 0.5) end

function util.lerp(a, b, t) return a + (b - a) * t end

--- Maps v from [inLo, inHi] onto [outLo, outHi], clamped to the output range.
function util.remap(v, inLo, inHi, outLo, outHi)
  if inHi == inLo then return outLo end
  local t = (v - inLo) / (inHi - inLo)
  return util.clamp(outLo + (outHi - outLo) * t, math.min(outLo, outHi), math.max(outLo, outHi))
end

util.DIR_NAMES = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

--- True compass bearing (0-360, 0 = north) of a world-space offset.
function util.bearingOf(dx, dz)
  local angle = math.deg(util.atan2(dx, -dz))
  if angle < 0 then angle = angle + 360 end
  return angle
end

--- Eight-point compass name of a world-space offset.
function util.directionOf(dx, dz)
  local idx = math.floor((util.bearingOf(dx, dz) + 22.5) / 45) % 8 + 1
  return util.DIR_NAMES[idx]
end

-- Rotation only turns the PICTURE, so a monitor can hang on any wall with
-- "up" matching the direction you face. Distances and the N/NE/E labels stay
-- true compass bearings throughout.

--- Rotates a world-space (dx, dz) offset into screen space, where `rotation`
--- is the true bearing that should appear at the top of the display.
function util.rotateXZ(dx, dz, rotation)
  if rotation == 0 then return dx, dz end
  local a = math.rad(rotation)
  local c, s = math.cos(a), math.sin(a)
  return dx * c + dz * s, dz * c - dx * s
end

--- Unit screen offset for a true compass bearing. Screen y grows downward,
--- hence the negated cosine.
function util.bearingToScreen(bearing, rotation)
  local a = math.rad(bearing - rotation)
  return math.sin(a), -math.cos(a)
end

-- Minecraft entity yaw is not a compass bearing: yaw 0 faces SOUTH and yaw
-- grows westward. Turning it half a circle lands on the true bearing the
-- player is looking along, which is what "heading up" needs at the top of the
-- scope.

--- True compass bearing a Minecraft yaw is facing, or nil when there is no yaw.
function util.headingOf(yaw)
  yaw = tonumber(yaw)
  if not yaw then return nil end
  return (yaw + 180) % 360
end

--- Shortest signed turn from bearing a to bearing b, in degrees [-180, 180).
function util.angleDelta(a, b)
  return (b - a + 180) % 360 - 180
end

--- Moves `from` a fraction `t` of the way toward `to`, always the short way
--- round, so easing across north does not spin the whole compass.
function util.approachAngle(from, to, t)
  return (from + util.angleDelta(from, to) * t) % 360
end

--- Snaps a bearing to the nearest multiple of `step`. A step of 0 (or nil)
--- leaves it untouched, which is what "smooth" rotation wants.
function util.snapAngle(deg, step)
  deg = deg % 360
  if not step or step <= 0 then return deg end
  return (math.floor(deg / step + 0.5) * step) % 360
end

function util.shorten(value, n)
  return string.sub(tostring(value), 1, n)
end

--- Pads or truncates so the result is exactly n cells wide.
function util.fit(value, n, alignRight)
  local s = string.sub(tostring(value), 1, n)
  local padding = string.rep(" ", n - #s)
  if alignRight then return padding .. s end
  return s .. padding
end

--- Compact distance label: 940m below a kilometre, 1.4k above it.
function util.distanceLabel(d)
  if d < 1000 then return util.round(d) .. "m" end
  return string.format("%.1fk", d / 1000)
end

--- Deterministic 0..1 noise. Used for stars and cloud placement so the scene
--- is stable between redraws instead of shimmering randomly.
function util.hash01(a, b)
  local n = (a or 0) * 12.9898 + (b or 0) * 78.233
  local s = math.sin(n) * 43758.5453
  return s - math.floor(s)
end

--- Splits a string into lines of at most width characters, on word breaks.
function util.wrap(text, width)
  local lines, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if #line == 0 then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if #line > 0 then lines[#lines + 1] = line end
  if #lines == 0 then lines[1] = "" end
  return lines
end

--- "minecraft:snowy_taiga" -> "Snowy Taiga"
function util.prettyId(id)
  local name = tostring(id or "?"):gsub("^.*:", ""):gsub("_", " ")
  return (name:gsub("(%a)([%w]*)", function(head, tail) return head:upper() .. tail end))
end

return util
