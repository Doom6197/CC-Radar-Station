-- Device profiles: one answer to "what is this computer bolted to?"
--
-- The same station runs in three very different places, and each wants
-- different defaults rather than different code:
--
--   BASE     the MAIN BASE: a fixed, chunk-loaded installation with the
--            detectors, the monitors and mains power
--   POCKET   carried in hand: a 26x20 screen, no monitors, no monitors' worth
--            of server budget either
--   VEHICLE  aboard an airship or a train, where "up" is wherever the pilot is
--            looking and the ground answers nothing
--
-- The last two are MOBILE: a modem and a screen, drawing what the main base
-- sends them. Which role a profile lands on depends on whether there is a
-- modem to talk over -- see apply() at the bottom.
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
    label = "MAIN BASE",
    hint = "the master: detectors, monitors, chunk loaded",
    blurb = {
      "The master computer. It holds the detectors, the",
      "monitors and the power meters, and feeds everything",
      "else over the network.",
      "",
      "Keep it chunk loaded, or it goes quiet the moment",
      "you walk away from it.",
    },
    cfg = {
      mode         = "base",
      orientation  = "fixed",
      headingStep  = 0,
      scanIndex    = 2,        -- one second
      envSeconds   = 2,
      animate      = true,
      flash        = true,
      toast        = true,
      tapCycle     = true,
    },
    off = { flight = true },
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
      "",
      "With a modem it runs as MOBILE and draws what the",
      "main base sends it -- including the power page,",
      "which it has nothing of its own to wire to.",
      "",
      "It measures from YOU, so it needs a username the",
      "main base can see.",
    },
    cfg = {
      mode           = "player",
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
      "A radar on a contraption. The scope centres on the",
      "ship and turns with it, so the top of the picture",
      "is always the way the bow is pointing.",
      "",
      "That needs CC: Sable and a Create: Simulated",
      "Sub-Level. Without one it falls back to tracking",
      "the PILOT, which needs a username the main base",
      "can see.",
      "",
      "A ship cannot scan for itself, so with a modem",
      "this runs as MOBILE, ready to pair with the main",
      "base on the ground.",
    },
    cfg = {
      mode           = "ship",
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
--- in the chooser: the operator still picks, because a main base and a vehicle
--- carry identical peripherals and look identical from here.
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
--- The ROLE is not listed in a profile's own settings: it is decided here,
--- from whether there is a modem to talk over. A profile describes where the
--- computer is, and the role describes what it can therefore do about it.
---@return table cfg
function profiles.apply(cfg, id, kit)
  local entry = profiles.byId(id)
  if not entry then return cfg end

  for key, value in pairs(entry.cfg) do cfg[key] = value end

  cfg.modulesOff = {}
  for module, off in pairs(entry.off) do
    if off then cfg.modulesOff[module] = true end
  end

  -- Each tracking mode needs something to track. SHIP needs a Sub-Level
  -- under the computer, PLAYER needs a username for the detector to look up.
  -- Without them the scope would silently draw nothing, so fall back rather
  -- than leave a station that looks broken.
  if cfg.mode == "ship" and not require("radar.sable").available() then
    cfg.mode = "player"
  end
  if cfg.mode == "player" and not cfg.myName then cfg.mode = "base" end
  if cfg.orientation == "heading" and not cfg.myName then cfg.orientation = "fixed" end

  -- The role is the one thing a profile cannot decide on its own, because it
  -- depends on whether there is a modem to talk over. Without one, every
  -- profile is a station that stands alone -- there is no network for it to
  -- be part of, and a role claiming otherwise would just report a fault.
  local hasModem = kit and kit.modem ~= nil
  if not hasModem then
    cfg.role = "standalone"
  elseif id == "base" then
    cfg.role = "main"
  else
    cfg.role = "mobile"
  end

  cfg.profile = id
  return cfg
end

return profiles
