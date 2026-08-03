-- FLIGHT module: speed, climb, heading, course and the way home.
--
-- Built for a 1x1 monitor first. That is fifteen cells across and nine rows of
-- content, which is exactly enough for eight readings and no decoration -- so
-- this page has no heading of its own (the header carries it), no separator
-- rule, and labels of three or four characters.
--
-- Everything comes from the pilot's position sampled over time; see
-- radar/flight.lua for what that can and cannot know. Nothing here polls a
-- peripheral: the sweep already produces a fix, and this listens for it.

local autopilot = require("radar.autopilot")
local config    = require("radar.config")
local flightLib = require("radar.flight")
local theme     = require("radar.theme")
local ui        = require("radar.ui")
local util      = require("radar.util")

local view = {
  id = "flight",
  title = "FLIGHT",
  short = "FLT",
  order = 25,          -- next to the scope, which is what it belongs with
  summary = "speed, climb, course and the way home",
}

local floor, max = math.floor, math.max

view.defaults = {
  -- On a fixed base this is a page about nothing: the readings would all be
  -- zero. It is switched on by the profiles that move -- see radar/profiles.
  flightHome = true,   -- draw the bearing and ETA to the destination

  -- Where you are going. "home" is the base coordinates, "custom" is the
  -- waypoint below, and anything else is "contact:<name>" -- a moving target,
  -- re-read from the contact list on every draw.
  flightTarget = "home",
  flightX = nil, flightY = nil, flightZ = nil,

  -- Which sides of the redstone relay the thruster groups are wired to, and
  -- how hard to fly. Whether the autopilot is ENGAGED is deliberately not
  -- here: see view.attach.
  autopilot = {
    relay = nil,          -- which relay, by peripheral name; nil = the first
    left  = nil,          -- relay side carrying the left thruster group
    right = nil,          -- and the right
    cruise     = 0.6,     -- throttle in level flight, 0..1
    turnRate   = 8,       -- degrees a second it is allowed to come round at
    turnPower  = 0.55,    -- most thrust difference it will use, 0..1
    lead       = 4,       -- seconds it aims to close the heading error in
    arrive     = 25,      -- blocks from the destination it stops at
    slowWithin = 120,     -- blocks out that it starts easing off
    range      = 1000,    -- blocks; further than this it shuts itself off
    record     = false,   -- write a telemetry row per pass, for tuning
  },
}

function view.sanitise(cfg)
  cfg.flightHome = cfg.flightHome ~= false

  local target = cfg.flightTarget
  if type(target) ~= "string" or #target == 0 then
    cfg.flightTarget = "home"
  elseif target ~= "home" and target ~= "custom"
     and not target:match("^contact:.") then
    cfg.flightTarget = "home"
  end

  for _, axis in ipairs({ "flightX", "flightY", "flightZ" }) do
    local value = tonumber(cfg[axis])
    cfg[axis] = value and floor(value) or nil
  end
  -- A waypoint needs two of the three to be a place at all; the height is
  -- optional, since a bearing does not use it.
  if not (cfg.flightX and cfg.flightZ) and cfg.flightTarget == "custom" then
    cfg.flightTarget = "home"
  end

  local auto = cfg.autopilot
  if type(auto) ~= "table" then
    auto = require("radar.modules").copy(view.defaults.autopilot)
    cfg.autopilot = auto
  end
  auto.cruise     = util.clamp(tonumber(auto.cruise) or 0.6, 0.05, 1)
  auto.turnRate   = util.clamp(tonumber(auto.turnRate) or 8, 1, 45)
  auto.turnPower  = util.clamp(tonumber(auto.turnPower) or 0.55, 0.05, 1)
  auto.lead       = util.clamp(tonumber(auto.lead) or 4, 0.5, 12)
  -- Gone in v8.12, replaced by the two above. Dropped rather than left in the
  -- file, where it would read like a setting that still did something.
  auto.turnFull   = nil
  auto.record     = auto.record == true
  auto.arrive     = util.clamp(floor(tonumber(auto.arrive) or 25), 1, 2000)
  auto.slowWithin = util.clamp(floor(tonumber(auto.slowWithin) or 120),
    auto.arrive, 4000)

  -- false is a deliberate "no limit"; anything unrecognisable becomes the
  -- default rather than silently removing the limit.
  if auto.range ~= false then
    local range = tonumber(auto.range)
    auto.range = (range and range > 0) and floor(range) or 1000
    -- A shut-off range inside the arrive radius is a contradiction: it would
    -- refuse to fly anywhere it was not already close enough to have stopped.
    if auto.range < auto.arrive then auto.range = auto.arrive end
  end

  -- A relay side is a name, and so is the relay's own peripheral name. Which
  -- names are legal is the network's business -- both are asked at pick time
  -- -- so this only rejects what cannot be one.
  for _, key in ipairs({ "relay", "left", "right" }) do
    local name = auto[key]
    if type(name) ~= "string" or #name == 0 then auto[key] = nil end
  end
end

-- ------------------------------------------------------------ destination ---

--- Where the panel is pointing, resolved fresh every draw so a contact target
--- follows the contact rather than freezing where it was chosen.
---@return table|nil { label, x, z, y, moving, lost }
function view.destination(app)
  local cfg = app.cfg
  local target = cfg.flightTarget or "home"

  if target == "home" then
    if not cfg.baseX then return nil end
    return { label = "HOME", x = cfg.baseX, y = cfg.baseY, z = cfg.baseZ }
  end

  if target == "custom" then
    if not (cfg.flightX and cfg.flightZ) then return nil end
    return { label = "WPT", x = cfg.flightX, y = cfg.flightY, z = cfg.flightZ }
  end

  local name = target:match("^contact:(.+)$")
  if not name then return nil end

  for _, contact in ipairs(app.contacts) do
    if contact.name == name then
      return {
        label = util.shorten(name, 7), x = contact.x, y = contact.y,
        z = contact.z, moving = true,
      }
    end
  end
  -- Chosen, but not on the current sweep: out of range, logged off, or in
  -- another dimension. Saying so beats silently falling back to home.
  return { label = util.shorten(name, 7), lost = true }
end

--- Points the panel at something. The one way in, so the settings picker, the
--- contact list and the tap-for-home button all take the same route and all
--- persist.
---@param target string "home", "custom", or "contact:<name>"
---@return boolean changed
function view.setTarget(app, target)
  if type(target) ~= "string" or app.cfg.flightTarget == target then return false end
  app.cfg.flightTarget = target
  view.sanitise(app.cfg)
  app:saveConfig()
  return true
end

--- Whether there is a waypoint to fly to at all. The height is optional: a
--- bearing does not use it.
function view.hasWaypoint(cfg)
  return cfg.flightX ~= nil and cfg.flightZ ~= nil
end

--- The next destination in the press-to-change cycle.
---
--- HOME and the waypoint only. A contact is picked deliberately, off the
--- contact list, and putting it in the cycle would mean pressing twice to get
--- past somebody who happens to be the current target -- so a contact drops
--- straight back to HOME instead.
---@return string target Which may be the current one, when there is nowhere else
function view.nextTarget(cfg)
  if (cfg.flightTarget or "home") ~= "home" then return "home" end
  return view.hasWaypoint(cfg) and "custom" or "home"
end

--- What the press-to-change button says, or nil when there is nowhere to go.
function view.swapLabel(cfg)
  local target = view.nextTarget(cfg)
  if target == (cfg.flightTarget or "home") then return nil end
  return target == "home" and "[ HOME ]" or "[ WPT ]"
end

--- A label for the destination row, for the settings page.
function view.destinationLabel(app)
  local target = app.cfg.flightTarget or "home"
  if target == "home" then
    return app.cfg.baseX and "HOME - the base coordinates" or "HOME - not set yet"
  end
  if target == "custom" then
    if not (app.cfg.flightX and app.cfg.flightZ) then return "a waypoint - not set" end
    return ("waypoint %d, %d"):format(app.cfg.flightX, app.cfg.flightZ)
  end
  local name = target:match("^contact:(.+)$")
  return name and ("contact - " .. name) or target
end

-- -------------------------------------------------------------- autopilot ---
-- The thrusters are driven by REDSTONE, 0 to 15. The chain is:
--
--   computer --wired modem--> Redstone Relay --side--> Create Redstone Link
--                                                        --wireless--> thrusters
--
-- so the relay is a NETWORK peripheral rather than something bolted to the
-- computer. Two of its sides carry a redstone link each, one per thruster
-- group, and the link puts the same signal strength out at the far end.
--
-- The relay rather than the computer's own sides, deliberately. The computer
-- has one redstone output and the alert system already owns it -- see
-- Settings / Alerts / Redstone output -- and two subsystems fighting over one
-- line would be a fault nobody could see from either page.
--
-- A wired network can carry more than one relay, so which one is a setting:
-- discover() collects every relay it can see and the operator picks. Taking
-- whichever answered first would mean an autopilot that quietly moved to a
-- different device when somebody added a lamp controller to the network.
--
-- Nothing here names the peripheral type. It is claimed by the methods it
-- answers to, exactly as every other device is -- which is also what makes a
-- relay on the far side of a wired modem indistinguishable from one on a side
-- of the computer, since hardware.discover walks both.

-- What a real CC:Tweaked Redstone Relay actually answers to:
--
--   getAnalogInput   getAnalogOutput   getAnalogueInput  getAnalogueOutput
--   getBundledInput  getBundledOutput  getInput          getOutput
--   setAnalogOutput  setAnalogueOutput setBundledOutput  setOutput
--   testBundledInput
--
-- Note what is NOT in that list: getSides(). The redstone GLOBAL has one and
-- the relay peripheral does not, and requiring it here is why the first
-- version of this found nothing at all on a network with a relay sitting
-- right on it. The sides are the six every block has, so they are a constant
-- rather than a question.
local SET_METHODS = { "setAnalogOutput", "setAnalogueOutput" }

-- One more method, so "can be told to put out a redstone level" is not the
-- whole test. Anything with both is a redstone output device with sides,
-- which is all this needs it to be.
local CONFIRM_METHODS = {
  "setOutput", "getInput", "getAnalogInput", "getAnalogueInput",
  "getAnalogOutput", "getAnalogueOutput",
}

local DEFAULT_SIDES = { "top", "bottom", "left", "right", "front", "back" }

local function methodOf(dev, names)
  if type(dev) ~= "table" then return nil end
  for _, name in ipairs(names) do
    if type(dev[name]) == "function" then return name end
  end
  return nil
end

--- Whether a peripheral can be driven as a thruster relay.
function view.looksLikeRelay(dev)
  return methodOf(dev, SET_METHODS) ~= nil
     and methodOf(dev, CONFIRM_METHODS) ~= nil
end

--- Collects every relay on the network, in name order.
---
--- `kit.relay` is whichever one the settings name, falling back to the first.
--- discover() cannot read the settings -- it is handed a kit, not an app -- so
--- the choice is applied in view.chooseRelay below, which attach() calls.
function view.discover(kit)
  kit.relays = {}
  for _, entry in ipairs(kit.peripherals or {}) do
    if view.looksLikeRelay(entry.dev) then
      kit.relays[#kit.relays + 1] = {
        name = entry.name, dev = entry.dev, type = entry.type,
        set = methodOf(entry.dev, SET_METHODS),
      }
    end
  end
  kit.relay = kit.relays[1]
  return kit
end

--- Points kit.relay at the relay the settings name.
---
--- A name that is no longer on the network -- the modem pulled, the block
--- mined, the ship reassembled -- falls back to whatever IS there rather than
--- leaving the autopilot with nothing, and the settings page says which.
---@return table|nil relay
function view.chooseRelay(app)
  local kit = app.kit
  local wanted = app.cfg.autopilot.relay
  kit.relay = kit.relays and kit.relays[1] or nil
  if not wanted then return kit.relay end
  for _, relay in ipairs(kit.relays or {}) do
    if relay.name == wanted then
      kit.relay = relay
      return relay
    end
  end
  return kit.relay
end

--- Whether the relay in use is the one that was asked for. False while a named
--- relay is missing and something else has been substituted.
function view.relayIsChosen(app)
  local wanted = app.cfg.autopilot.relay
  if not wanted then return true end
  return app.kit.relay ~= nil and app.kit.relay.name == wanted
end

--- The sides of the relay a thruster group can be wired to.
---
--- A relay does not list its own sides, so these are the six every block has.
--- A device that DOES offer a list is believed, since a future one might.
function view.sides(app)
  local relay = app.kit.relay
  if not relay then return {} end
  if type(relay.dev.getSides) == "function" then
    local ok, sides = pcall(relay.dev.getSides)
    if ok and type(sides) == "table" and #sides > 0 then return sides end
  end
  return DEFAULT_SIDES
end

--- Writes both throttles as redstone levels.
---
--- Every call goes through here, so there is one place that talks to the
--- hardware and one place that records what was commanded.
---@param left number 0..1 throttle
---@param right number 0..1 throttle
---@return boolean ok
---@return string|nil problem
function view.writeOutputs(app, left, right)
  local relay = app.kit.relay
  local auto = app.cfg.autopilot
  local state = app.autopilot

  -- The rounding error is carried between passes, so the average level over a
  -- few of them is the throttle asked for. Sixteen levels is too coarse to
  -- hold a heading with otherwise -- see autopilot.level.
  local leftLevel, rightLevel, carryLeft, carryRight
  leftLevel,  carryLeft  = autopilot.level(left,  state and state.carryLeft)
  rightLevel, carryRight = autopilot.level(right, state and state.carryRight)

  if state then
    state.left, state.right = left, right
    state.leftLevel, state.rightLevel = leftLevel, rightLevel
    state.carryLeft, state.carryRight = carryLeft, carryRight
  end

  if not relay then return false, "no redstone relay attached" end
  if auto.left == nil or auto.right == nil then return false, "sides not set" end

  local set = relay.dev[relay.set]
  local okLeft  = pcall(set, auto.left, leftLevel)
  local okRight = pcall(set, auto.right, rightLevel)
  if okLeft and okRight then return true end
  return false, "the relay refused the write"
end

--- Why the autopilot cannot be engaged right now, or nil when it can.
function view.autopilotProblem(app)
  if not app.kit.relay then return "No redstone relay attached" end
  local auto = app.cfg.autopilot
  if auto.left == nil or auto.right == nil then
    return "Set the left and right relay sides first"
  end
  if auto.left == auto.right then
    return "Left and right are on the same side"
  end
  if not view.destination(app) then return "No destination set" end
  return nil
end

--- Whether the page shows an autopilot row at all. A base or a pocket computer
--- with no relay anywhere near it gets the page it always had.
function view.autopilotAvailable(app)
  return app.kit.relay ~= nil
    or app.cfg.autopilot.left ~= nil
    or app.cfg.autopilot.right ~= nil
end

--- Engages or disengages.
---
--- Engagement is NOT persisted. A ship that reloads its chunk, or a computer
--- that reboots mid-flight, comes back with the thrusters off -- restoring
--- "was flying somewhere" from a settings file is not a thing that should
--- happen without a person present.
---@return boolean engaged
---@return string message
function view.setAutopilot(app, on)
  local state = app.autopilot

  if not on then
    state.engaged = false
    state.phase, state.message = "off", autopilot.phaseLabel("off")
    state.error, state.faulted = nil, nil
    view.writeOutputs(app, 0, 0)
    return false, "Autopilot off"
  end

  local problem = view.autopilotProblem(app)
  if problem then return false, problem end

  state.engaged = true
  state.phase, state.message = "probe", autopilot.phaseLabel("probe")
  state.probing, state.faulted = 0, nil
  state.left, state.right = 0, 0
  state.carryLeft, state.carryRight = 0, 0
  state.recorded = nil            -- each engagement records its own file
  return true, "Autopilot engaged"
end

function view.toggleAutopilot(app)
  return view.setAutopilot(app, not app.autopilot.engaged)
end

-- ------------------------------------------------------------- telemetry ---
-- One line per control pass, so how the ship actually behaved can be read
-- back as numbers rather than guessed at from watching it. An overshoot
-- because the lead is too short, one because the turn response is too sharp,
-- and one because the reported course lags harder than expected all look
-- identical from the outside and want three different fixes.

view.RECORD_FILE = "radar_flight.csv"

-- Written at two rows a second, so this is about seventeen minutes. Bounded
-- on purpose: a recorder left on by accident must not quietly eat the disk.
view.RECORD_LIMIT = 2000

view.RECORD_COLUMNS = {
  "t", "phase", "dist", "bearing", "course", "err", "rate", "want",
  "steer", "left", "right", "lvlL", "lvlR", "speed",
}

--- A number for the file: fixed precision, or empty when there is none.
local function csv(value, decimals)
  if type(value) ~= "number" or value ~= value then return "" end
  return ("%." .. (decimals or 1) .. "f"):format(value)
end

--- Appends one row, starting a fresh file at the beginning of each recording.
---
--- Each engagement gets its own file rather than appending forever: "fly one
--- turn and send me the file" is the whole point of it, and a file holding
--- six runs needs picking apart before it can answer anything.
---@return boolean written
function view.record(app, now, result, distance, bearing)
  local state = app.autopilot
  if not app.cfg.autopilot.record then
    state.recorded = nil                  -- next time recording starts, it starts
    return false
  end
  if (state.recorded or 0) >= view.RECORD_LIMIT then return false end

  local model = app.flight
  local fresh = state.recorded == nil

  local ok, handle = pcall(fs.open, view.RECORD_FILE, fresh and "w" or "a")
  if not ok or not handle then return false end

  if fresh then handle.write(table.concat(view.RECORD_COLUMNS, ",") .. "\n") end
  handle.write(table.concat({
    csv(now, 2),
    tostring(result.phase),
    csv(distance),
    csv(bearing),
    csv(model.course),
    csv(result.error),
    csv(result.turnRate, 2),
    csv(result.wanted, 2),
    csv(result.steer, 3),
    csv(result.left, 3),
    csv(result.right, 3),
    csv(state.leftLevel, 0),
    csv(state.rightLevel, 0),
    csv(model.speed, 2),
  }, ",") .. "\n")
  handle.close()

  state.recorded = (state.recorded or 0) + 1
  return true
end

--- One pass of the control loop: read the destination, decide, write.
---@param now number os.clock()
---@param elapsed number seconds since the previous pass
---@return table result The autopilot's decision
function view.control(app, now, elapsed)
  local state = app.autopilot
  local model = app.flight
  local destination = view.destination(app)

  local distance, bearing
  if destination and not destination.lost then
    distance, bearing = model:vectorTo(destination.x, destination.z)
  end

  local result = autopilot.step({
    engaged  = state.engaged,
    lost     = (destination and destination.lost) or false,
    distance = distance,
    bearing  = bearing,
    -- The course the ship is MAKING. Deliberately not app.heading: that is
    -- where the pilot is looking, and looking over the rail must not steer.
    course   = model.course,
    speed    = model.speed,
    steering = state.phase == "steer",
    -- How fast it is coming round. Without this the correction is still
    -- going in long after the nose is pointed the right way, and the ship
    -- swings through the heading instead of settling on it.
    turnRate = model.turnRate,
    moving   = model.moving,
    sinceFix = (app.lastScanAt > 0) and (now - app.lastScanAt) or nil,
    probing  = state.probing,
    previous = { left = state.left, right = state.right },
    cfg      = app.cfg.autopilot,
  })

  state.probing = (result.phase == "probe")
    and (state.probing + (elapsed or 0)) or 0

  state.phase, state.message, state.error = result.phase, result.message, result.error
  view.writeOutputs(app, result.left, result.right)

  -- After the write, so the levels recorded are the ones that went out.
  view.record(app, now, result, distance, bearing)

  -- A fault is a give-up, not a pause: say so once, on the alert log and every
  -- channel the operator has switched on, and stop flying.
  if result.fault and state.engaged and state.faulted ~= result.phase then
    state.faulted = result.phase
    state.engaged = false
    app:alarm("Autopilot off - " .. autopilot.phaseLabel(result.phase), "flight")
  elseif not result.fault then
    state.faulted = nil
  end

  app:emit("autopilot")
  return result
end

view.events = { "scan", "autopilot" }

--- The control loop. Faster than the sweep on purpose: the decision is only
--- as fresh as the last fix, but the slew limiter needs steps to walk through,
--- and the staleness check has to notice a dead position feed between sweeps.
function view.start(app)
  local basalt = require("basalt")
  local interval = 0.5
  basalt.schedule(function()
    while app.running do
      sleep(interval)
      if app.autopilot.engaged
         and require("radar.modules").isEnabled(app.cfg, "flight") then
        local ok, err = pcall(view.control, app, os.clock(), interval)
        if not ok then app.autopilot.message = tostring(err) end
      end
    end
  end)
end

function view.attach(app)
  app.flight = app.flight or flightLib.new()

  -- Engagement lives here rather than in the settings file, so it can never be
  -- restored by a restart.
  app.autopilot = app.autopilot or {
    engaged = false,
    phase   = "off",
    message = autopilot.phaseLabel("off"),
    left = 0, right = 0,
    carryLeft = 0, carryRight = 0,
    probing = 0,
    error = nil,
    faulted = nil,
  }

  -- attach() runs again after every rescan, which is exactly when the chosen
  -- relay has to be found again on the network.
  view.chooseRelay(app)

  -- The hardware may have just been rescanned out from under a flying ship.
  if app.autopilot.engaged and not app.kit.relay then
    view.setAutopilot(app, false)
  end

  -- Hung off the app so another page can aim the panel without requiring this
  -- module: the contact list checks for it and leaves its taps alone when the
  -- flight page is not installed at all.
  app.setFlightTarget = function(target) return view.setTarget(app, target) end

  -- attach() runs again on a rescan, and a second listener would sample every
  -- fix twice.
  if app.flightWired then return end
  app.flightWired = true

  local modules = require("radar.modules")
  app:on("scan", function()
    -- Free in server-call terms -- the fix has already been read -- but a
    -- station with the page switched off has no use for the history, and a
    -- fixed base would fill it with the operator walking around.
    if app.myPos and modules.isEnabled(app.cfg, "flight") then
      app.flight:sample(app.myPos, os.clock())
    end
  end)

  -- Whatever else is going on, a station shutting down leaves the thrusters
  -- off. A ship still under power with nothing left running to steer it is
  -- the one outcome worth writing code to prevent.
  app:on("stop", function()
    app.autopilot.engaged = false
    pcall(view.writeOutputs, app, 0, 0)
  end)
end

-- ------------------------------------------------------------------- page ---

-- Six cells is what the value column has on a fifteen-cell screen, so the
-- phases get short names there rather than being cut mid-word.
local PHASE_SHORT = {
  off = "off", nodest = "no dest", lost = "lost", nofix = "no fix",
  toofar = "far", probe = "find", steer = "on", arrived = "there",
  stalled = "STALL",
}

--- What the A/P row reads. While steering it shows the course error, because
--- that is the number that says whether it is working.
function view.autopilotLabel(app)
  local state = app.autopilot
  if not state or not state.engaged then
    return view.autopilotProblem(app) and "--" or "off"
  end
  if state.phase == "steer" and state.error then
    return ("%+d"):format(util.round(state.error))
  end
  return PHASE_SHORT[state.phase] or state.phase
end

function view.autopilotColour(app)
  local state = app.autopilot
  if not state or not state.engaged then return theme.dim end
  if autopilot.FAULTS[state.phase] then return theme.alarm end
  if state.phase == "steer" then return theme.good end
  return theme.accent
end

--- The readings, in the order they matter while flying. Each is
--- { label, value, colour } and nil entries are skipped, so a panel with no
--- home set simply has fewer rows rather than a gap.
local function readings(app, wide)
  local model = app.flight
  local cfg = app.cfg
  local out = {}

  --- `key` names a row the operator can press: the destination row swaps
  --- between HOME and the waypoint, and the A/P row engages the autopilot.
  local function push(label, value, colour, key)
    out[#out + 1] = { label = label, value = value,
                      colour = colour or theme.text, key = key }
  end

  -- FIRST, when there is a relay for it. Fifteen cells gives nine rows
  -- and this panel fills every one of them, so a row that is also the ONLY
  -- switch for the autopilot cannot be last -- it would be the one clipped.
  if view.autopilotAvailable(app) then
    local state = app.autopilot or {}
    push("A/P", view.autopilotLabel(app), view.autopilotColour(app), "auto")
    if wide and state.engaged then
      -- The redstone levels actually on the relay, which is the number to
      -- look at when the ship is not doing what the panel says it should.
      push("THR", ("%d / %d"):format(state.leftLevel or 0, state.rightLevel or 0),
        (state.leftLevel or 0) + (state.rightLevel or 0) > 0
          and theme.accent or theme.dim)
    end
  end

  local speed = model.speed
  push("SPD", flightLib.formatSpeed(speed),
    (speed and model.moving) and theme.good or theme.dim)

  local climb = model.vertical
  push("VS", flightLib.formatVertical(climb),
    (climb and math.abs(climb) >= 0.05)
      and (climb > 0 and theme.good or theme.warn)
      or theme.dim)

  -- Where you are looking, and where you are actually going. On an airship
  -- being pushed sideways these differ, which is the point of showing both.
  -- Both carry their compass point: reading a heading off a number takes a
  -- moment, and off "SW" it does not.
  push("HDG", app.heading and flightLib.formatCompass(app.heading) or "---",
    app.heading and theme.accent or theme.dim)
  push("CRS", model.course and flightLib.formatCompass(model.course) or "---",
    model.moving and theme.accent or theme.dim)

  local drift = model:drift(app.heading)
  if wide and drift then
    push("DFT", ("%+d"):format(util.round(drift)),
      math.abs(drift) > 20 and theme.warn or theme.dim)
  end

  local pos = model.position
  push("ALT", pos and tostring(floor(pos.y)) or "--",
    pos and theme.text or theme.dim)

  if cfg.flightHome then
    local destination = view.destination(app)
    if not destination then
      push("DEST", "not set", theme.dim, "dest")
    elseif destination.lost then
      -- A contact that has gone off the sweep. Its name stays on the panel so
      -- it is obvious what is being waited for.
      push(destination.label, "lost", theme.warn, "dest")
    else
      local distance, _, compass = model:vectorTo(destination.x, destination.z)
      if distance then
        push(destination.label, util.distanceLabel(distance),
          destination.moving and theme.warn or theme.text, "dest")
        push("BRG", compass or "--", theme.accent)
        local eta = model:eta(distance)
        push("ETA", flightLib.formatEta(eta), eta and theme.text or theme.dim)
      else
        push(destination.label, "--", theme.dim, "dest")
      end
    end
  end

  return out
end

function view.build(container, app, root)
  -- Where the pressable rows ended up, rebuilt on every draw. Recording them
  -- as the page is laid out is the only honest way to know what a tap at a
  -- given cell is pointing at: the rows move with the screen size, whether
  -- there is a destination at all, and which column the layout put it in.
  local hits = {}

  local canvas = container:addCanvas({
    x = 1, y = 1,
    width = function(s) return s.parent.width end,
    height = function(s) return s.parent.height end,
    background = theme.bg,
  })

  canvas.draw = function(self, buf)
    local w, h = self.width, self.height
    buf:fill(1, 1, w, h, " ", theme.text, theme.bg)
    hits = {}

    local tiny = ui.isTiny(w)
    local model = app.flight
    local rows = readings(app, not tiny)

    local y = 1
    if not tiny then
      buf:blit(2, y, "FLIGHT", theme.accent, theme.bg)
      if app.scanError then
        local text = util.shorten(app.scanError, max(1, w - 10))
        buf:blit(max(1, w - #text), y, text, theme.alarm, theme.bg)
      end
      y = y + 1
      if h >= 3 then
        buf:fill(1, y, w, 1, "-", theme.line, theme.bg)
        y = y + 1
      end
    end

    -- With nothing to differentiate yet, say so rather than drawing a panel
    -- of dashes that looks like a fault.
    if not model.position then
      local lines = tiny
        and { "No fix.", "", "Set your", "username", "in", "Settings." }
        or { "No position fix.", "",
             "Flight readings come from your own position,",
             "so this needs your username set -- and, on a",
             "MOBILE, a main base relaying it." }
      for _, line in ipairs(lines) do
        if y > h then break end
        if #line > 0 then
          buf:blit(tiny and 1 or 2, y, util.shorten(line, w - 1), theme.dim, theme.bg)
        end
        y = y + 1
      end
      return
    end

    if tiny then
      -- Label hard left, value hard right: on fifteen cells every column of
      -- padding is a character of the number that would have been cut.
      for _, row in ipairs(rows) do
        if y > h then break end
        buf:blit(1, y, row.label, theme.dim, theme.bg)
        local value = util.shorten(row.value, max(1, w - 5))
        buf:blit(max(1, w - #value), y, value, row.colour, theme.bg)
        if row.key then hits[#hits + 1] = { x1 = 1, x2 = w, y = y, key = row.key } end
        y = y + 1
      end
      return
    end

    -- Two columns where there is room for them.
    local twoColumn = w >= 34
    local colW = twoColumn and floor((w - 3) / 2) or (w - 2)
    local perColumn = twoColumn and math.ceil(#rows / 2) or #rows

    for index, row in ipairs(rows) do
      local column = twoColumn and floor((index - 1) / perColumn) or 0
      local line = y + ((index - 1) % perColumn)
      if line <= h then
        local x = 2 + column * (colW + 1)
        buf:blit(x, line, util.fit(row.label, 5), theme.dim, theme.bg)
        buf:blit(x + 5, line, util.shorten(row.value, colW - 6), row.colour, theme.bg)
        if row.key then
          hits[#hits + 1] = { x1 = x, x2 = x + colW - 1, y = line, key = row.key }
        end
      end
    end

    y = y + perColumn

    -- Position and dimension, which are context rather than instruments.
    local pos = model.position
    if y <= h and w >= 26 then
      buf:blit(2, y, ("%d, %d, %d"):format(floor(pos.x), floor(pos.y), floor(pos.z)),
        theme.dim, theme.bg)
      y = y + 1
    end

    if y <= h and h >= 6 then
      local note = model.moving and "under way" or "stopped"
      if config.isMobile(app.cfg) then note = note .. "   relayed" end

      -- Buttons along the bottom row, laid out from the right.
      --
      -- A 1x1 gets NEITHER. Eight cells of button is half that screen, and the
      -- destination row up above is already pressable there -- which is the
      -- one of these two that has to work without a wall of monitors.
      local buttons = {}
      if not tiny then
        local swap = view.swapLabel(app.cfg)
        if swap then buttons[#buttons + 1] = { label = swap, key = "dest" } end
        buttons[#buttons + 1] = { label = "[ MARK ]", key = "mark" }
      end

      -- Dropped leftmost-first until what is left fits beside the note, rather
      -- than drawn over the top of it.
      local function roomFor(list)
        local total = 0
        for _, entry in ipairs(list) do total = total + #entry.label + 1 end
        return 2 + #note + total
      end
      while #buttons > 0 and roomFor(buttons) > w do table.remove(buttons, 1) end

      local edge = w + 1
      for index = #buttons, 1, -1 do
        local button = buttons[index]
        edge = edge - #button.label
        buf:blit(edge, h, button.label, theme.accent, theme.bg)
        hits[#hits + 1] = {
          x1 = edge, x2 = edge + #button.label - 1, y = h, key = button.key,
        }
        edge = edge - 1
      end

      buf:blit(2, h, util.shorten(note, max(1, edge - 2)), theme.line, theme.bg)
    end
  end

  --- Engages or disengages the autopilot from the page itself, which on a 1x1
  --- monitor is the only way in: there is no keyboard and no settings page on
  --- a screen that size.
  local function toggleAuto()
    local engaged, message = view.setAutopilot(app, not app.autopilot.engaged)
    if root then
      root:toast(message, engaged and "success"
        or (view.autopilotProblem(app) and "error" or "info"))
    end
    canvas:markRenderDirty()
    return true
  end

  --- Puts the panel on the next destination in the cycle: HOME and the
  --- waypoint, and nothing else.
  local function swapDestination()
    local cfg = app.cfg
    local target = view.nextTarget(cfg)
    if target == (cfg.flightTarget or "home") then
      if root then root:toast("No waypoint set - press MARK first", "info") end
      return true
    end
    view.setTarget(app, target)
    if root then
      root:toast(target == "home" and "Destination: HOME"
        or ("Destination: waypoint %d, %d"):format(cfg.flightX, cfg.flightZ),
        "success")
    end
    canvas:markRenderDirty()
    return true
  end

  --- Drops the waypoint where the pilot is standing, and flies to it. Setting
  --- it as the destination as well is what makes this readable on a monitor,
  --- which has no banner to tell you it worked: the panel changes to WPT in
  --- front of you. Typed-in coordinates are still under Settings / Flight.
  local function markWaypoint()
    local pos = app.flight and app.flight.position
    if not pos then
      if root then root:toast("No position fix to mark", "warning") end
      return true
    end
    local cfg = app.cfg
    cfg.flightX, cfg.flightY, cfg.flightZ = floor(pos.x), floor(pos.y), floor(pos.z)
    cfg.flightTarget = "custom"
    app:saveConfig()
    if root then
      root:toast(("Waypoint %d, %d, %d"):format(cfg.flightX, cfg.flightY, cfg.flightZ),
        "success")
    end
    canvas:markRenderDirty()
    return true
  end

  return {
    refresh = function() canvas:markRenderDirty() end,
    --- Three presses on this page. The destination -- either the row or the
    --- button beside the footer -- swaps between HOME and the waypoint, MARK
    --- drops the waypoint where you are, and the A/P row engages the
    --- autopilot. The last one is the reason the A/P row is drawn first: on a
    --- 1x1 monitor it is the only switch there is.
    touch = function(x, y)
      for _, hit in ipairs(hits) do
        if y == hit.y and x >= hit.x1 and x <= hit.x2 then
          if hit.key == "mark" then return markWaypoint() end
          if hit.key == "dest" then return swapDestination() end
          if hit.key == "auto" then return toggleAuto() end
        end
      end
      return false
    end,
  }
end

-- ---------------------------------------------------------------- settings ---

function view.settings(ctx)
  local app = ctx.app
  local cfg = app.cfg

  ctx.heading("FLIGHT")

  ctx.row("Destination", function() return view.destinationLabel(app) end, function()
    local entries = {
      { label = ctx.withHint("HOME", "the base coordinates"), value = "home" },
    }

    -- Every contact currently on the sweep, so picking one is a matter of
    -- recognising the name rather than typing coordinates.
    for _, contact in ipairs(app.contacts) do
      entries[#entries + 1] = {
        label = ("%s   %s %s"):format(util.shorten(contact.name, 14),
          util.distanceLabel(contact.dist), contact.dir),
        value = "contact:" .. contact.name,
      }
    end

    entries[#entries + 1] = {
      label = ctx.withHint("Waypoint", "the coordinates below"), value = "custom",
    }

    ctx.openPicker("FLY TO", entries, cfg.flightTarget, function(value)
      cfg.flightTarget = value
      app:saveConfig()
      if value == "custom" and not (cfg.flightX and cfg.flightZ) then
        ctx.root:toast("Set the waypoint coordinates below", "info")
      end
      ctx.rebuild()
    end)
  end, function()
    local destination = view.destination(app)
    if not destination then return theme.warn end
    if destination.lost then return theme.warn end
    return destination.moving and theme.accent or theme.text
  end)

  ctx.note("HOME, anyone on the contact list, or a waypoint. A contact is "
    .. "followed as it moves.")
  ctx.note("On the page itself, pressing the destination swaps between HOME "
    .. "and the waypoint, and MARK drops the waypoint where you are.")

  -- The waypoint boxes only exist while a waypoint is what is selected;
  -- three empty inputs on a page about flying would be clutter otherwise.
  if cfg.flightTarget == "custom" then
    ctx.coords("Waypoint XYZ", { "flightX", "flightY", "flightZ" }, function()
      app:saveConfig()
      -- What it says has to match what the Destination row above now reads. A
      -- waypoint needs an X and a Z to be a place at all; the height is
      -- optional, since a bearing does not use it.
      if cfg.flightX and cfg.flightZ then
        ctx.root:toast(("Waypoint %d, %d"):format(cfg.flightX, cfg.flightZ),
          "success")
      else
        ctx.root:toast("A waypoint needs an X and a Z", "warning")
      end
      ctx.refreshRows()
    end)
  end

  ctx.row("Show the way", function() return ctx.onOff(cfg.flightHome) end, function()
    cfg.flightHome = not cfg.flightHome
    app:saveConfig()
  end, ctx.onOffColor(function() return cfg.flightHome end))

  ctx.note("Distance, bearing and ETA to the destination.")

  ctx.row("Reading", function()
    local model = app.flight
    if not model or not model.position then return "no fix" end
    return ("%s b/s   %s alt"):format(
      flightLib.formatSpeed(model.speed),
      model.position and tostring(math.floor(model.position.y)) or "--")
  end, function()
    app.flight:reset()
    ctx.root:toast("Flight history cleared", "info")
  end, function()
    return (app.flight and app.flight.moving) and theme.good or theme.dim
  end)

  ctx.note("Worked out from your own position as it changes, so it needs "
    .. "your username set. Press to clear the history.")
  ctx.note("It is the PILOT's position, not the ship's: walk off and the "
    .. "readings follow you.")
  ctx.spacer()

  view.autopilotSettings(ctx)
end

-- --------------------------------------------------------------- autopilot ---

function view.autopilotSettings(ctx)
  local app, root = ctx.app, ctx.root
  local auto = app.cfg.autopilot

  ctx.heading("AUTOPILOT")

  ctx.row("Autopilot", function()
    local state = app.autopilot
    if state.engaged then
      return ("ON - %s"):format(autopilot.phaseLabel(state.phase))
    end
    return view.autopilotProblem(app) or "off"
  end, function()
    local _, message = view.toggleAutopilot(app)
    root:toast(message, app.autopilot.engaged and "success" or "info")
  end, function()
    if not app.autopilot.engaged then
      return view.autopilotProblem(app) and theme.warn or theme.dim
    end
    return autopilot.FAULTS[app.autopilot.phase] and theme.alarm or theme.good
  end)

  ctx.note("Flies to the destination above using the left and right thruster "
    .. "groups. It steers by the course it is MAKING, never by which way you "
    .. "are looking - so it moves off first to find out which way the ship "
    .. "points. It does not touch altitude and it does not avoid anything.", true)

  ctx.row("Relay", function()
    local relay = app.kit.relay
    -- The peripheral count, because "not found" on its own cannot tell the
    -- difference between a modem that is seeing nothing and a modem that is
    -- seeing plenty of things that are not relays.
    if not relay then
      local seen = #(app.kit.peripherals or {})
      return ("not found - %d peripheral%s seen"):format(seen,
        seen == 1 and "" or "s")
    end
    if not view.relayIsChosen(app) then
      return ("%s   (%s is gone)"):format(util.shorten(relay.name, 14),
        util.shorten(auto.relay, 14))
    end
    local found = #(app.kit.relays or {})
    if found > 1 then
      return ("%s   1 of %d"):format(util.shorten(relay.name, 16), found)
    end
    return util.shorten(relay.name, 20)
  end, function()
    -- A wired network can carry several. Offering the list beats taking
    -- whichever answered first and quietly moving to a different device the
    -- day somebody adds another one.
    local relays = app.kit.relays or {}
    if #relays == 0 then
      app:rescan()
      root:toast(app.kit.relay and ("Relay: " .. app.kit.relay.name)
        or "No redstone relay found",
        app.kit.relay and "success" or "warning")
      return
    end
    local entries = {}
    for _, relay in ipairs(relays) do
      entries[#entries + 1] = {
        label = ctx.withHint(relay.name, relay.type),
        value = relay.name,
      }
    end
    entries[#entries + 1] = {
      label = ctx.withHint("-- rescan --", "look for relays again"),
      value = false,
    }
    ctx.openPicker("REDSTONE RELAY", entries, auto.relay, function(value)
      if value == false then
        app:rescan()
        root:toast(("%d relay(s) found"):format(#(app.kit.relays or {})), "info")
      else
        auto.relay = value
        app:saveConfig()
        view.chooseRelay(app)
        root:toast("Relay: " .. value, "success")
      end
      ctx.refreshRows()
    end)
  end, function()
    if not app.kit.relay then return theme.warn end
    return view.relayIsChosen(app) and theme.good or theme.warn
  end)

  ctx.note("A CC:Tweaked Redstone Relay, usually on a wired modem next to the "
    .. "computer. Two of its sides carry a Create Redstone Link each, and the "
    .. "link puts the same 0-15 signal out at the thrusters.", true)
  ctx.note("Not the computer's own sides: the alert output already owns those, "
    .. "and two things driving one line is a fault you cannot see from either "
    .. "page.", true)
  ctx.note("The side the wired modem is on cannot carry a link, so do not "
    .. "pick it below.")

  --- One group's side picker. The two are identical bar the key, so they are
  --- built rather than written twice and left to drift apart.
  local function sidePicker(key, label)
    ctx.row(label, function()
      local side = auto[key]
      if side == nil then return "not set" end
      if auto.left == auto.right then return side .. "  (same as the other)" end
      return side
    end, function()
      local sides = view.sides(app)
      if #sides == 0 then
        root:toast("No redstone relay attached", "warning")
        return
      end
      local entries = {}
      for _, side in ipairs(sides) do
        local taken = (key == "left" and auto.right or auto.left) == side
        entries[#entries + 1] = {
          label = taken and (side .. "   (the other group)") or side,
          value = side,
        }
      end
      entries[#entries + 1] = { label = "-- not set --", value = false }
      ctx.openPicker(label:upper(), entries, auto[key], function(value)
        auto[key] = (value ~= false) and value or nil
        app:saveConfig()
        ctx.refreshRows()
      end)
    end, function()
      if auto[key] == nil then return theme.warn end
      return auto.left == auto.right and theme.alarm or theme.text
    end)
  end

  sidePicker("left", "Left thrusters")
  sidePicker("right", "Right thrusters")

  ctx.action("Swap left and right", function()
    auto.left, auto.right = auto.right, auto.left
    app:saveConfig()
    root:toast("Swapped", "info")
  end)

  ctx.note("If it turns the wrong way, they are the wrong way round. More "
    .. "thrust on the LEFT swings the nose to the RIGHT.", true)

  ctx.row("Cruise", function() return ("%d%%"):format(util.round(auto.cruise * 100)) end,
    function()
      ctx.openPicker("CRUISE THROTTLE",
        ctx.entriesOf({ 0.2, 0.3, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0 },
          function(v) return ("%d%%"):format(util.round(v * 100)) end,
          function(v) return v end),
        auto.cruise,
        function(value)
          auto.cruise = value
          app:saveConfig()
          ctx.refreshRows()
        end)
    end)

  ctx.row("Turn rate", function()
    return ("%g deg/s"):format(auto.turnRate)
  end, function()
    ctx.openPicker("TURN RATE",
      ctx.entriesOf({ 4, 6, 8, 12, 20, 30 }, function(v)
        local name = (v <= 4 and "Stately") or (v <= 6 and "Slow")
          or (v <= 8 and "Normal") or (v <= 12 and "Brisk")
          or (v <= 20 and "Fast") or "Violent"
        return ctx.withHint(name, ("%d degrees a second"):format(v))
      end, function(v) return v end),
      auto.turnRate,
      function(value)
        auto.turnRate = value
        app:saveConfig()
        ctx.refreshRows()
      end)
  end)

  ctx.note("How fast it is ALLOWED to come round. This is the setting that "
    .. "stops a ship overshooting: a vessel yawing faster than the once-a-"
    .. "second position fix can see cannot be steered at all, only bounced "
    .. "between extremes. Turn it down until the ship stops hunting.", true)

  ctx.row("Turn power", function()
    return ("%d%%"):format(util.round(auto.turnPower * 100))
  end, function()
    ctx.openPicker("TURN POWER",
      ctx.entriesOf({ 0.2, 0.35, 0.55, 0.75, 1.0 }, function(v)
        return ("%d%% thrust difference"):format(util.round(v * 100))
      end, function(v) return v end),
      auto.turnPower,
      function(value)
        auto.turnPower = value
        app:saveConfig()
        ctx.refreshRows()
      end)
  end)

  ctx.note("The most difference it will put between the two sides to hold "
    .. "that rate. Separate from Cruise on purpose - they used to be the same "
    .. "knob, so turning the throttle up turned the steering gain up with it.")

  ctx.row("Turn in", function() return ("%g seconds"):format(auto.lead) end,
    function()
      ctx.openPicker("TURN IN",
        ctx.entriesOf({ 2, 3, 4, 6, 8, 12 }, function(v)
          return ctx.withHint(("%d seconds"):format(v),
            ("asks for err/%d deg per second"):format(v))
        end, function(v) return v end),
        auto.lead,
        function(value)
          auto.lead = value
          app:saveConfig()
          ctx.refreshRows()
        end)
    end)

  ctx.note("How long it aims to take to null the heading error. Bigger is a "
    .. "wider, gentler turn that starts easing off sooner.")

  ctx.row("Arrive within", function() return auto.arrive .. " blocks" end, function()
    ctx.openPicker("ARRIVE WITHIN",
      ctx.entriesOf({ 5, 10, 25, 50, 100, 250, 500, 1000 },
        function(v) return v .. " blocks" end, function(v) return v end),
      auto.arrive,
      function(value)
        auto.arrive = value
        -- The two below it are both floored by this one, so raising it drags
        -- them up rather than leaving a range that contradicts it.
        if auto.slowWithin < value then auto.slowWithin = value end
        if auto.range ~= false and auto.range < value then auto.range = value end
        app:saveConfig()
        ctx.refreshRows()
      end)
  end)

  ctx.row("Ease off within", function() return auto.slowWithin .. " blocks" end,
    function()
      ctx.openPicker("EASE OFF WITHIN",
        ctx.entriesOf({ 50, 120, 250, 500, 1000, 2000 },
          function(v) return v .. " blocks" end, function(v) return v end),
        auto.slowWithin,
        function(value)
          auto.slowWithin = math.max(value, auto.arrive)
          app:saveConfig()
          ctx.refreshRows()
        end)
    end)

  ctx.note("It throttles back on the approach so it stops near the "
    .. "destination rather than sailing past it.")

  ctx.row("Shut off beyond", function()
    if auto.range == false then return "no limit" end
    return auto.range .. " blocks"
  end, function()
    ctx.openPicker("SHUT OFF BEYOND",
      ctx.entriesOf(autopilot.RANGES, function(v)
        if v == false then return ctx.withHint("No limit", "it will fly anywhere") end
        return v .. " blocks"
      end, function(v) return v end),
      auto.range,
      function(value)
        auto.range = value
        app:saveConfig()
        ctx.refreshRows()
      end)
  end, function() return auto.range == false and theme.warn or theme.text end)

  ctx.note("Cuts the thrusters if the destination is further off than this, "
    .. "checked every pass and not only when engaging - a contact who logs "
    .. "back in on the far side of the world moves the destination, not the "
    .. "ship.", true)

  --- A one-second nudge on one side, for checking the wiring without
  --- engaging. It restores whatever was commanded before, which while
  --- disengaged is nothing.
  local function nudge(side, label)
    ctx.action("Test " .. label, function()
      if not app.kit.relay then
        root:toast("No redstone relay attached", "error")
        return
      end
      if app.autopilot.engaged then
        root:toast("Switch the autopilot off first", "warning")
        return
      end
      local basalt = require("basalt")
      root:toast(("Pulsing %s at %d for 1s"):format(label,
        autopilot.level(auto.cruise)), "info")
      basalt.schedule(function()
        view.writeOutputs(app, side == "left" and auto.cruise or 0,
          side == "right" and auto.cruise or 0)
        sleep(1)
        view.writeOutputs(app, 0, 0)
      end)
    end)
  end

  nudge("left", "left thrusters")
  nudge("right", "right thrusters")

  ctx.note("The ship will move. Use them in clear air.", true)
  ctx.spacer()

  -- telemetry ------------------------------------------------------------
  ctx.heading("TELEMETRY")

  ctx.row("Record", function()
    if not auto.record then return "off" end
    local rows = app.autopilot.recorded
    if not rows then return "ON - waiting to fly" end
    if rows >= view.RECORD_LIMIT then
      return ("ON - full at %d rows"):format(rows)
    end
    return ("ON - %d rows"):format(rows)
  end, function()
    auto.record = not auto.record
    app.autopilot.recorded = nil
    app:saveConfig()
    root:toast(auto.record and ("Recording to " .. view.RECORD_FILE)
      or "Recording off", "info")
  end, ctx.onOffColor(function() return auto.record end))

  ctx.note("Writes one line per control pass to " .. view.RECORD_FILE
    .. " while the autopilot is flying: the course, the error, the turn rate "
    .. "and both thruster levels. Each engagement starts a new file.", true)
  ctx.note("An overshoot from too little damping and one from too sharp a "
    .. "turn response look identical from the cockpit and want opposite "
    .. "fixes. This is how you tell them apart.")
  ctx.note(("It stops at %d rows, so it cannot fill the disk if it is left "
    .. "on."):format(view.RECORD_LIMIT))

  ctx.action("Clear the recording", function()
    pcall(fs.delete, view.RECORD_FILE)
    app.autopilot.recorded = nil
    root:toast("Cleared " .. view.RECORD_FILE, "info")
  end)
  ctx.spacer()
end

view.readings = readings

return view
