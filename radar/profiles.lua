-- Device profiles: one answer to "what is this computer bolted to?"
--
-- The same station runs in three very different places, and each wants
-- different defaults rather than different code:
--
--   BASE     a fixed installation with monitors, a detector and mains power
--   POCKET   carried in hand: a 26x20 screen, no monitors, no monitors' worth
--            of server budget either
--   VEHICLE  aboard an airship or a train, where "up" is wherever the pilot is
--            looking and the ground answers nothing
--
-- A profile is a set of settings and a set of modules, applied once when the
-- operator picks it. It is NOT a mode the rest of the program checks: after it
-- has been applied, every setting it touched is an ordinary setting that can be
-- changed on the settings page like any other. That is deliberate -- a profile
-- that kept overriding you would be a worse version of just having settings.
--
-- The choice is offered on first boot rather than guessed. Hardware is a poor
-- proxy for intent: a pocket computer is unmistakable, but a base and a ship
-- carry exactly the same peripherals and differ only in what they are attached
-- to, which nothing on the network can see.

local profiles = {}

profiles.LIST = {
  {
    id = "base",
    label = "BASE STATION",
    hint = "a fixed installation with monitors",
    blurb = {
      "A radar bolted to a wall, watching one place.",
      "",
      "Monitors get their own pages, the scope holds a",
      "fixed bearing, and every module is switched on.",
    },
    cfg = {
      role         = "station",
      mode         = "fixed",
      orientation  = "fixed",
      headingStep  = 0,
      scanIndex    = 2,        -- one second
      envSeconds   = 2,
      animate      = true,
      flash        = true,
      toast        = true,
      tapCycle     = true,
    },
    off = {},
  },

  {
    id = "pocket",
    label = "POCKET",
    hint = "carried in hand, on the move",
    blurb = {
      "A radar in your pocket: a small screen, no",
      "monitors, and a server budget worth saving.",
      "",
      "Sweeps and polls slow down, the animation stops,",
      "and the scope turns with you in 45 degree steps.",
      "The power page is off -- nothing to wire it to.",
    },
    cfg = {
      role           = "station",
      mode           = "self",
      orientation    = "heading",
      headingStep    = 45,
      headingSeconds = 1,
      headingSmooth  = false,
      scanIndex      = 3,      -- two seconds
      envSeconds     = 5,
      animate        = false,
      flash          = false,
      toast          = true,
    },
    off = { power = true },
  },

  {
    id = "vehicle",
    label = "AIRSHIP / VEHICLE",
    hint = "aboard something that moves",
    blurb = {
      "A radar on a contraption. The scope follows the",
      "pilot's heading and eases into turns, so the top",
      "of the picture is always the way you are going.",
      "",
      "A ship assembled by Create: Aeronautics cannot",
      "scan for itself. With no Player Detector aboard,",
      "this also sets the SHIP role, ready to pair with",
      "a base on the ground.",
    },
    cfg = {
      mode           = "self",
      orientation    = "heading",
      headingStep    = 0,
      headingSeconds = 0.5,
      headingSmooth  = true,
      scanIndex      = 2,
      envSeconds     = 2,
      animate        = true,
      flash          = true,
      toast          = true,
    },
    off = {},
  },
}

profiles.DEFAULT = "base"

function profiles.byId(id)
  for _, entry in ipairs(profiles.LIST) do
    if entry.id == id then return entry end
  end
  return nil
end

function profiles.ids()
  local out = {}
  for i, entry in ipairs(profiles.LIST) do out[i] = entry.id end
  return out
end

function profiles.label(id)
  local entry = profiles.byId(id)
  return entry and entry.label or "Custom"
end

--- One line for the settings page and the status readout.
---@param short? boolean Drop the hint, for a screen with no room for it
function profiles.summary(cfg, short)
  local entry = profiles.byId(cfg and cfg.profile)
  if not entry then return short and "Custom" or "Custom - no profile applied" end
  if short then return entry.label end
  return entry.label .. " - " .. entry.hint
end

--- Which profile the hardware suggests. Only ever used to preselect an entry
--- in the chooser: the operator still picks, because a base and a ship look
--- identical from here.
---@return string id
function profiles.suggest(kit)
  kit = kit or {}

  -- A pocket computer has no monitors and never will: peripherals sit on its
  -- one built-in side rather than on a network.
  if type(pocket) == "table" then return "pocket" end

  -- Nothing to scan with, but something to listen with, is the shape of a
  -- screen riding on a contraption.
  if not kit.detector and kit.modem then return "vehicle" end

  if kit.monitors and #kit.monitors > 0 then return "base" end
  return profiles.DEFAULT
end

--- Applies a profile's settings and module set to a config table.
---
--- `kit` is optional and only consulted where the right answer genuinely
--- depends on what is attached -- a vehicle with no Player Detector has to be
--- a SHIP, because there is nothing aboard for it to be anything else with.
---@return table cfg
function profiles.apply(cfg, id, kit)
  local entry = profiles.byId(id)
  if not entry then return cfg end

  for key, value in pairs(entry.cfg) do cfg[key] = value end

  cfg.modulesOff = {}
  for module, off in pairs(entry.off) do
    if off then cfg.modulesOff[module] = true end
  end

  -- SELF tracking and an unlocked scope both read the operator's own position,
  -- which needs a username. Without one they would silently draw nothing, so
  -- fall back rather than leave a station that looks broken.
  if cfg.mode == "self" and not cfg.myName then cfg.mode = "fixed" end
  if cfg.orientation == "heading" and not cfg.myName then cfg.orientation = "fixed" end

  if id == "vehicle" then
    local hasDetector = kit and kit.detector ~= nil
    cfg.role = hasDetector and "station" or "ship"
  end

  cfg.profile = id
  return cfg
end

return profiles
