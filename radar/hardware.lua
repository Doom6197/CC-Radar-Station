-- Peripheral discovery.
--
-- Everything is looked up by capability rather than by peripheral type name,
-- so a Player Detector works whether it is bolted to the side of the computer,
-- built into a pocket computer or turtle, or sitting somewhere on a wired
-- modem network.

local hardware = {}

local SIDES = { "back", "front", "top", "bottom", "left", "right" }

local function looksLikePlayerDetector(p)
  return type(p) == "table"
     and type(p.getPlayersInRange) == "function"
     and type(p.getPlayerPos) == "function"
end

local function looksLikeEnvironmentDetector(p)
  return type(p) == "table"
     and type(p.getTime) == "function"
     and type(p.getBiome) == "function"
end

local function looksLikeModem(p)
  return type(p) == "table"
     and type(p.transmit) == "function"
     and type(p.isWireless) == "function"
end

hardware.looksLikePlayerDetector = looksLikePlayerDetector
hardware.looksLikeEnvironmentDetector = looksLikeEnvironmentDetector
hardware.looksLikeModem = looksLikeModem

--- Scans every side and every network name.
---@return table kit { detector, detectorName, env, envName, speakers, monitors, modems, modem }
function hardware.discover()
  local kit = {
    detector = nil, detectorName = nil,
    env = nil, envName = nil,
    speakers = {},
    monitors = {},          -- { { name = , dev = , scale = } , ... }
    modems = {},            -- { { name = , dev = , wireless = } , ... }
    modem = nil, modemName = nil,
  }

  local seenModem = {}

  local function consider(name, p)
    if not p then return end
    if looksLikeModem(p) then
      -- A modem answers on both its side and its network name; the rednet API
      -- only wants one of them.
      if not seenModem[name] then
        seenModem[name] = true
        local ok, wireless = pcall(p.isWireless)
        kit.modems[#kit.modems + 1] =
          { name = name, dev = p, wireless = (ok and wireless) == true }
      end
    elseif not kit.detector and looksLikePlayerDetector(p) then
      kit.detector, kit.detectorName = p, name
    elseif not kit.env and looksLikeEnvironmentDetector(p) then
      kit.env, kit.envName = p, name
    end
  end

  -- Built-in peripherals on a turtle or pocket computer sit on a fixed side
  -- and are not returned by peripheral.getNames().
  for _, side in ipairs(SIDES) do
    if peripheral.isPresent(side) then
      consider(side, peripheral.wrap(side))
    end
  end

  for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    if ptype == "monitor" then
      kit.monitors[#kit.monitors + 1] = { name = name, dev = peripheral.wrap(name) }
    elseif ptype == "speaker" then
      kit.speakers[#kit.speakers + 1] = peripheral.wrap(name)
    else
      consider(name, peripheral.wrap(name))
    end
  end

  -- Stable ordering, so "monitor 1" stays monitor 1 across rescans and the
  -- per-monitor page settings keep pointing at the same screen.
  table.sort(kit.monitors, function(a, b) return a.name < b.name end)

  -- A wireless or ender modem is what a flying ship needs, so it wins over a
  -- wired one even if the wired one was found first.
  table.sort(kit.modems, function(a, b)
    if a.wireless ~= b.wireless then return a.wireless end
    return a.name < b.name
  end)
  kit.modem = kit.modems[1]
  kit.modemName = kit.modem and kit.modem.name or nil
  return kit
end

--- Applies a text scale, ignoring monitors that vanished mid-call.
function hardware.setScale(monitor, scale)
  local ok = pcall(monitor.dev.setTextScale, scale)
  if ok then monitor.scale = scale end
  return ok
end

--- Blanks a monitor and leaves a parting message on it.
function hardware.release(monitor, message)
  pcall(function()
    monitor.dev.setBackgroundColor(colors.black)
    monitor.dev.setTextColor(colors.white)
    monitor.dev.clear()
    monitor.dev.setCursorPos(1, 1)
    if message then monitor.dev.write(message) end
  end)
end

return hardware
