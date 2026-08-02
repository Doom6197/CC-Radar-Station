-- Sound, redstone and screen-flash alerts.
--
-- Sound repeats and redstone pulses are paced by tick(), which the app calls
-- roughly ten times a second. That keeps pulse lengths honest regardless of
-- how slow the scan interval is set.
--
-- Nothing in here knows what an alert is ABOUT. A contact arriving fires the
-- same three channels a power buffer running low does, so a module wanting to
-- raise the alarm calls fire() and gets the operator's sound, their flash
-- setting and their redstone side without reimplementing any of it. The same
-- goes for the analog output: a module registers a level provider and its
-- redstone mode drives the one output line the computer has.

local config = require("radar.config")

local alerts = {}
alerts.__index = alerts

function alerts.new(cfg, kit)
  return setmetatable({
    cfg = cfg,
    kit = kit,
    sound = { left = 0, nextAt = 0 },
    rs = { pulseUntil = 0, last = -1 },
    contacts = {},        -- live set, for hold/analog redstone
    providers = {},       -- redstone mode id -> function() -> 0..1 or nil
    onFlash = nil,        -- set by the UI
  }, alerts)
end

function alerts:setKit(kit) self.kit = kit end

-- ------------------------------------------------------------------ sound ---

--- Plays the configured sound on every speaker on the network.
---@return boolean played
function alerts:play()
  local s = config.sound(self.cfg)
  local played = false
  for _, speaker in ipairs(self.kit.speakers) do
    local ok = pcall(speaker.playSound, s.id, self.cfg.sound.volume, self.cfg.sound.pitch)
    played = played or ok
  end
  return played
end

function alerts:queue()
  if not self.cfg.sound.enabled or #self.kit.speakers == 0 then return end
  self.sound.left = self.cfg.sound.repeats
  self.sound.nextAt = 0            -- fire on the next tick
end

-- --------------------------------------------------------------- redstone ---

function alerts.sides()
  local ok, sides = pcall(redstone.getSides)
  if ok and type(sides) == "table" and #sides > 0 then return sides end
  return { "top", "bottom", "left", "right", "front", "back" }
end

function alerts:setLevel(level)
  level = math.max(0, math.min(15, math.floor(level or 0)))
  if self.cfg.rs.invert then level = 15 - level end
  if level == self.rs.last then return end
  self.rs.last = level
  pcall(redstone.setAnalogOutput, self.cfg.rs.side, level)
end

function alerts:level() return math.max(self.rs.last, 0) end

--- Forces the next update to write the line, after a settings change.
function alerts:invalidate() self.rs.last = -1 end

function alerts:pulse()
  if not self.cfg.rs.enabled or self.cfg.rs.mode ~= "pulse" then return end
  self.rs.pulseUntil = os.clock() + (self.cfg.rs.pulse or 1)
end

--- Registers a level source for a redstone mode a module has added.
---
--- The provider returns a fraction from 0 to 1, or nil when it has nothing to
--- say -- which is not the same as zero. A power module with no battery
--- attached returns nil, and the line HOLDS its last level rather than
--- dropping, because a fuel gate that opens the moment a peripheral is
--- unloaded is worse than one that does not move.
---@param mode string A config.RS_MODES id
---@param provider function() -> number|nil
function alerts:provideLevel(mode, provider)
  self.providers[mode] = provider
  return self
end

--- Recomputes the output level from whatever the current mode reads.
function alerts:updateRedstone()
  if not self.cfg.rs.enabled then return self:setLevel(0) end

  local mode = self.cfg.rs.mode

  -- A module's mode wins, so a contact-shaped mode name can never be shadowed.
  local provider = self.providers[mode]
  if provider then
    local ok, fraction = pcall(provider)
    if not ok or type(fraction) ~= "number" then return end
    -- 1 at empty rather than 0, so "the provider is reading and it is nearly
    -- nothing" stays distinguishable from "the output is off".
    return self:setLevel(math.max(1, math.floor(15 * math.max(0, math.min(1, fraction)) + 0.5)))
  end

  local trigger = config.RANGES[self.cfg.rs.rangeIndex].value
  local nearest = nil
  for _, contact in ipairs(self.contacts) do
    if contact.dist <= trigger then nearest = contact break end
  end

  if mode == "pulse" then
    self:setLevel(os.clock() < self.rs.pulseUntil and 15 or 0)
  elseif mode == "hold" then
    self:setLevel(nearest and 15 or 0)
  else
    if nearest then
      -- 15 at the centre, 1 at the trigger radius.
      self:setLevel(math.max(1, math.floor(15 * (1 - nearest.dist / trigger) + 0.5)))
    else
      self:setLevel(0)
    end
  end
end

--- Drops the line, whatever the mode, so nothing is left latched on exit.
function alerts:shutdown()
  pcall(redstone.setAnalogOutput, self.cfg.rs.side, 0)
end

-- ------------------------------------------------------------------- tick ---

--- Called about ten times a second.
function alerts:tick()
  local now = os.clock()
  if self.sound.left > 0 and now >= self.sound.nextAt then
    self:play()
    self.sound.left = self.sound.left - 1
    self.sound.nextAt = now + 0.35
  end
  if self.cfg.rs.enabled and self.cfg.rs.mode == "pulse" then
    self:updateRedstone()
  end
end

-- ------------------------------------------------------------------- fire ---

--- Fires every enabled alert channel, whatever the reason. The master mute
--- covers this too: an operator who has muted the station has muted all of it.
---@param reason? string Passed through to the flash handler for the banner
---@return boolean fired
function alerts:fire(reason)
  if not self.cfg.alert then return false end
  self:pulse()
  self:queue()
  if self.onFlash then self.onFlash(nil, reason) end
  return true
end

--- Fires every enabled alert channel for a set of newly arrived contacts.
function alerts:trigger(newContacts)
  if not self.cfg.alert then return false end

  local inRange = false
  local limit = config.alertRange(self.cfg)
  for _, contact in ipairs(newContacts) do
    if contact.dist <= limit then inRange = true break end
  end
  if not inRange then return false end

  self:pulse()
  self:queue()
  if self.onFlash then self.onFlash(newContacts) end
  return true
end

return alerts
