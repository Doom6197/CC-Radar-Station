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
  flightHome = true,   -- draw the bearing and ETA back to the base
}

function view.sanitise(cfg)
  cfg.flightHome = cfg.flightHome ~= false
end

function view.attach(app)
  app.flight = app.flight or flightLib.new()

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

  local function push(label, value, colour)
    out[#out + 1] = { label = label, value = value, colour = colour or theme.text }
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
  push("HDG", app.heading and flightLib.formatBearing(app.heading) or "---",
    app.heading and theme.accent or theme.dim)
  push("CRS", model.course and flightLib.formatBearing(model.course) or "---",
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
    local distance, _, compass = model:home(cfg)
    if distance then
      push("HOME", util.distanceLabel(distance), theme.text)
      push("BRG", compass or "--", theme.accent)
      local eta = model:eta(distance)
      push("ETA", flightLib.formatEta(eta), eta and theme.text or theme.dim)
    else
      push("HOME", "not set", theme.dim)
    end
  end

  return out
end

function view.build(container, app)
  local canvas = container:addCanvas({
    x = 1, y = 1,
    width = function(s) return s.parent.width end,
    height = function(s) return s.parent.height end,
    background = theme.bg,
  })

  canvas.draw = function(self, buf)
    local w, h = self.width, self.height
    buf:fill(1, 1, w, h, " ", theme.text, theme.bg)

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
      buf:blit(2, h, util.shorten(note, w - 2), theme.line, theme.bg)
    end
  end

  return { refresh = function() canvas:markRenderDirty() end }
end

-- ---------------------------------------------------------------- settings ---

function view.settings(ctx)
  local app = ctx.app

  ctx.heading("FLIGHT")

  ctx.row("Way home", function() return ctx.onOff(app.cfg.flightHome) end, function()
    app.cfg.flightHome = not app.cfg.flightHome
    app:saveConfig()
  end, ctx.onOffColor(function() return app.cfg.flightHome end))

  ctx.note("Distance, bearing and ETA back to the base coordinates "
    .. "under TRACKING.")

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
