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

function view.attach(app)
  app.flight = app.flight or flightLib.new()

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
end

view.events = { "scan" }

-- ------------------------------------------------------------------- page ---

--- The readings, in the order they matter while flying. Each is
--- { label, value, colour } and nil entries are skipped, so a panel with no
--- home set simply has fewer rows rather than a gap.
local function readings(app, wide)
  local model = app.flight
  local cfg = app.cfg
  local out = {}

  --- `key` names a row the operator can press. Only the destination row has
  --- one: pressing it swaps between HOME and the waypoint.
  local function push(label, value, colour, key)
    out[#out + 1] = { label = label, value = value,
                      colour = colour or theme.text, key = key }
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
    --- Two presses on this page: the destination -- either the row or the
    --- button beside the footer -- swaps between HOME and the waypoint, and
    --- MARK drops the waypoint where you are.
    touch = function(x, y)
      for _, hit in ipairs(hits) do
        if y == hit.y and x >= hit.x1 and x <= hit.x2 then
          if hit.key == "mark" then return markWaypoint() end
          if hit.key == "dest" then return swapDestination() end
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
      ctx.root:toast("Waypoint set", "success")
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
end

view.readings = readings

return view
