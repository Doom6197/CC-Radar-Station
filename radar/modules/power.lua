-- POWER module: what the grid is doing, and what it did in the last few
-- minutes.
--
-- The Advanced Peripherals Energy Detector sits inline in a cable and reports
-- a transfer rate, so one of them on the main bus is a live FE/t readout for
-- nothing. What it cannot tell you is how much is BANKED, which is usually the
-- number you actually want at three in the morning when the reactor has
-- stopped -- so anything wrappable that reports stored and capacity is read
-- too, and the page shows both. See radar/power.lua for how a battery is
-- recognised without naming a single mod.
--
-- The graph is a real line chart rather than a row of block characters:
-- radar/pixel.lua already addresses 2x3 sub-pixels per cell, so a 40x8 panel
-- gives 80x24 plot points. radar/chart.lua does the plotting.
--
-- Two things reuse machinery that was already here rather than growing their
-- own. The low-buffer alarm calls alerts:fire(), so it goes out on whichever
-- of sound, screen flash and redstone pulse the operator has switched on. And
-- the redstone output gains a BUFFER mode, which maps 1-15 to how full the
-- bank is exactly as ANALOG maps 1-15 to how close a contact is -- enough to
-- drive a fuel gate or start a backup generator.

local config   = require("radar.config")
local chart    = require("radar.chart")
local pixel    = require("radar.pixel")
local powerLib = require("radar.power")
local theme    = require("radar.theme")
local util     = require("radar.util")

local view = {
  id = "power",
  title = "POWER",
  short = "PWR",
  order = 50,
  summary = "energy in, out and stored, with a rolling graph",
}

local floor, max, min = math.floor, math.max, math.min

-- Palette indices for the plot surface.
local BG, PANEL, LINE, IN, OUT, BANK, ALARM, DIM = 1, 2, 3, 4, 5, 6, 7, 8

local PALETTE = {
  theme.tones.bg,
  theme.tones.panel,
  theme.tones.line,
  theme.tones.good,      -- energy coming in
  theme.tones.warn,      -- energy going out
  theme.tones.accent,    -- the buffer
  theme.tones.alarm,
  theme.tones.dim,
}

-- ------------------------------------------------------------------ config ---

view.WINDOWS = { 60, 120, 300, 600, 900 }
view.SAMPLES = { 1, 2, 5 }

-- Only a label. Mekanism quotes joules, most other mods quote FE, and nothing
-- here converts between them -- it reports what the peripheral said, under
-- whatever name the operator recognises.
view.UNITS = { "FE", "RF", "J", "E" }

view.ROLES = {
  { id = "in",  label = "INPUT",  hint = "counts towards supply" },
  { id = "out", label = "OUTPUT", hint = "counts towards demand" },
  { id = "off", label = "ignore", hint = "read, but left out of the totals" },
}

view.defaults = {
  power = {
    enabled       = true,
    unit          = "FE",
    windowSeconds = 300,      -- five minutes of graph
    sampleSeconds = 1,
    alarm         = true,
    lowPercent    = 20,
    roles         = {},       -- peripheral name -> "in" | "out" | "off"
  },
}

local function snapTo(list, value, fallback)
  value = tonumber(value)
  if not value then return fallback end
  local best, gap = fallback, math.huge
  for _, entry in ipairs(list) do
    local d = math.abs(entry - value)
    if d < gap then best, gap = entry, d end
  end
  return best
end

function view.sanitise(cfg)
  local p = cfg.power
  if type(p) ~= "table" then
    -- A copy, never the descriptor's own table: handing that out would make
    -- the first setting the operator changed become the new default.
    cfg.power = require("radar.modules").copy(view.defaults.power)
    p = cfg.power
  end

  p.enabled = p.enabled ~= false
  p.alarm   = p.alarm ~= false
  p.windowSeconds = snapTo(view.WINDOWS, p.windowSeconds, 300)
  p.sampleSeconds = snapTo(view.SAMPLES, p.sampleSeconds, 1)
  p.lowPercent = util.clamp(floor(tonumber(p.lowPercent) or 20), 1, 90)

  local unit = false
  for _, name in ipairs(view.UNITS) do
    if p.unit == name then unit = true end
  end
  if not unit then p.unit = "FE" end

  local roles = {}
  if type(p.roles) == "table" then
    for name, role in pairs(p.roles) do
      if type(name) == "string"
         and (role == "in" or role == "out" or role == "off") then
        roles[name] = role
      end
    end
  end
  p.roles = roles
end

-- Registered at load time rather than in attach(), so the mode exists before
-- config.sanitise ever validates cfg.rs.mode against the list. A settings file
-- naming it therefore survives a restart.
config.addRedstoneMode({
  id = "buffer",
  label = "Buffer",
  hint = "strength 1-15 by how full the power buffer is",
})

-- --------------------------------------------------------------- hardware ---

--- Claims every energy peripheral off the kit. Matched on method name, so a
--- battery from a mod written after this file still lands here.
function view.discover(kit)
  local found = {}
  for _, entry in ipairs(kit.peripherals or {}) do
    local source = powerLib.describe(entry.name, entry.dev, entry.type)
    if source then found[#found + 1] = source end
  end
  kit.energy = found
  return kit
end

function view.attach(app)
  app.power = app.power or powerLib.new()
  app.power:attach(app.kit, app.cfg)

  -- The buffer redstone mode reads through here, so the one output line the
  -- computer has can be driven by the power page instead of the contact list.
  app.alerts:provideLevel("buffer", function() return app.power:fraction() end)
end

function view.start(app)
  local basalt = require("basalt")
  local modules = require("radar.modules")
  basalt.schedule(function()
    while app.running do
      -- The loop outlives the module being switched off, so it checks rather
      -- than assuming: there is no way to cancel a Basalt schedule, and a
      -- disabled page must stop costing server-thread calls.
      if app.cfg.power.enabled and modules.isEnabled(app.cfg, "power") then
        local ok, err = pcall(function()
          app.power:poll(app.cfg)

          if app.power:checkAlarm(app.cfg) then
            app.alerts:fire(("Power low - buffer at %d%%"):format(
              util.round(app.power.percent or 0)))
          end

          -- The contact sweep already refreshes the line on its own cadence,
          -- but a buffer draining between sweeps has to move it too.
          if app.cfg.rs.enabled and app.cfg.rs.mode == "buffer" then
            app.alerts:updateRedstone()
          end

          app:emit("power")
        end)
        if not ok then app.power.error = tostring(err) end
      end
      sleep(app.cfg.power.sampleSeconds)
    end
  end)
end

-- Pages redraw on this, exactly as they do on "scan" and "env".
view.events = { "power" }

-- ------------------------------------------------------------------- page ---

--- Rows the readout above the graph takes, shrinking on a short screen until
--- there is nothing left but the rates.
local function headerRows(height)
  if height >= 12 then return 5 end
  if height >= 8 then return 4 end
  if height >= 5 then return 3 end
  return height
end

function view.build(container, app)
  local grid = pixel.new(1, 1, PALETTE)

  local canvas = container:addCanvas({
    x = 1, y = 1,
    width = function(s) return s.parent.width end,
    height = function(s) return s.parent.height end,
    background = theme.bg,
  })

  canvas.draw = function(self, buf)
    local w, h = self.width, self.height
    buf:fill(1, 1, w, h, " ", theme.text, theme.bg)

    local model = app.power
    local cfg = app.cfg.power
    local unit = cfg.unit

    -- ------------------------------------------------------- nothing yet ---
    if not model or not model.available then
      buf:blit(2, 1, "POWER", theme.accent, theme.bg)
      if h >= 2 then buf:fill(1, 2, w, 1, "-", theme.line, theme.bg) end
      local lines = {
        "No energy peripheral found.",
        "",
        "Put an Advanced Peripherals Energy",
        "Detector inline in your main cable, or",
        "connect a battery to the wired modem",
        "network - an induction matrix, an energy",
        "cell, a flux point.",
        "",
        "Then press Rescan under",
        "Settings / Power.",
      }
      for i, line in ipairs(lines) do
        if 3 + i - 1 > h then break end
        buf:blit(2, 3 + i - 1, util.shorten(line, max(1, w - 2)),
          i == 1 and theme.warn or theme.dim, theme.bg)
      end
      return
    end

    local rows = headerRows(h)

    -- ----------------------------------------------------------- heading ---
    buf:blit(2, 1, "POWER", theme.accent, theme.bg)

    local badge, badgeColor
    if model.error then
      badge, badgeColor = "FAULT", theme.alarm
    elseif model.low then
      badge, badgeColor = "LOW", theme.alarm
    elseif not cfg.enabled then
      badge, badgeColor = "PAUSED", theme.dim
    elseif model.net < 0 then
      badge, badgeColor = "DRAINING", theme.warn
    else
      badge, badgeColor = "STABLE", theme.good
    end
    if w >= 22 then
      buf:blit(max(1, w - #badge), 1, badge, badgeColor, theme.bg)
    end

    if rows >= 2 then buf:fill(1, 2, w, 1, "-", theme.line, theme.bg) end

    -- ------------------------------------------------------------- rates ---
    -- Three figures on one line when there is room, the net alone when there
    -- is not: on a pocket screen the balance is the one that matters.
    if rows >= 3 then
      local netText = powerLib.formatSigned(model.net) .. " " .. unit .. "/t"
      local netColor = model.net < 0 and theme.warn
        or (model.net > 0 and theme.good or theme.dim)

      if w >= 34 then
        buf:blit(2, 3, "IN", theme.dim, theme.bg)
        buf:blit(5, 3, powerLib.format(model.input), theme.good, theme.bg)
        local outX = floor(w / 3) + 1
        buf:blit(outX, 3, "OUT", theme.dim, theme.bg)
        buf:blit(outX + 4, 3, powerLib.format(model.output), theme.warn, theme.bg)
        buf:blit(max(1, w - #netText), 3, netText, netColor, theme.bg)
      else
        buf:blit(2, 3, "NET", theme.dim, theme.bg)
        buf:blit(6, 3, util.shorten(netText, max(1, w - 7)), netColor, theme.bg)
      end
    end

    -- ------------------------------------------------------------ buffer ---
    local plotTop = rows + 1

    if rows >= 4 then
      if model.percent then
        local pct = util.round(model.percent)
        local threshold = cfg.lowPercent
        local color = model.low and theme.alarm
          or (pct <= threshold + powerLib.ALARM_HYSTERESIS and theme.warn or theme.accent)

        buf:blit(2, 4, ("%3d%%"):format(pct), color, theme.bg)

        local text = ("%s / %s"):format(
          powerLib.format(model.stored), powerLib.format(model.capacity))
        if w >= 30 then
          buf:blit(max(8, w - #text), 4, text, theme.dim, theme.bg)
        end

        -- The bar itself, in sub-pixels so it is two-thirds of a cell tall and
        -- reads as a gauge rather than as a row of blocks.
        local barX, barW = 7, max(4, (w >= 30 and (w - #text - 9) or (w - 8)))
        if barW >= 4 then
          grid:resize(barW, 1)
          grid:clear(BG)
          local box = { x = 1, y = 1, w = grid.w, h = 2 }
          chart.gauge(grid, box, model.percent / 100,
            model.low and ALARM or BANK, PANEL)
          chart.gaugeTicks(grid, box, 0.25, LINE)
          -- The alarm threshold, so how close it is is visible before it fires.
          local markX = floor(1 + (grid.w - 1) * threshold / 100 + 0.5)
          grid:set(markX, 3, ALARM)
          grid:blitTo(buf, barX, 4)
        end
      else
        buf:blit(2, 4, "No battery attached - rate only", theme.dim, theme.bg)
      end
    end

    -- ------------------------------------------------------------- graph ---
    local plotBottom = h - (h >= 6 and 1 or 0)
    local plotHeight = plotBottom - plotTop + 1

    if plotHeight >= 2 and w >= 8 then
      grid:resize(w - 2, plotHeight)
      grid:clear(BG)

      local ins, outs, pct = model.history:series()
      local slots = model.history.cap
      local box = { x = 1, y = 1, w = grid.w, h = grid.h }

      chart.ticks(grid, box, 4, LINE)

      -- Rates and buffer percentage share no scale at all, so the buffer is
      -- plotted against its own 0-100 and the rates against theirs. Two
      -- scales on one panel would be a lie if they were labelled and clutter
      -- if they were not, so the buffer is drawn as a filled backdrop the
      -- rates ride over -- it reads as context rather than as a second series.
      if model.hasStore then
        chart.line(grid, box, {
          { values = pct, index = PANEL, fill = true, fillIndex = PANEL },
        }, { count = slots, min = 0, max = 100 })
      end

      local lo, hi = chart.line(grid, box, {
        { values = ins,  index = IN },
        { values = outs, index = OUT },
      }, { count = slots, zero = true })

      chart.rule(grid, box, 0, lo, hi, LINE, 2)
      grid:blitTo(buf, 2, plotTop)

      -- Scale, tucked into the corners of the plot rather than given a row.
      if w >= 26 and plotHeight >= 3 then
        buf:blit(2, plotTop, util.shorten(powerLib.format(hi), 8), theme.dim, theme.bg)
        local window = powerLib.duration(cfg.windowSeconds)
        buf:blit(2, plotBottom, window .. " ago", theme.line, theme.bg)
      end
    end

    -- ------------------------------------------------------------ footer ---
    if h >= 6 then
      local parts = {}

      if model.error then
        parts[#parts + 1] = model.error
      else
        local seconds, direction = model:timeToLimit()
        if seconds then
          parts[#parts + 1] = ("%s in %s"):format(direction, powerLib.duration(seconds))
        elseif model.hasStore then
          parts[#parts + 1] = "holding"
        end
      end

      local count = #model.sources
      parts[#parts + 1] = ("%d device%s"):format(count, count == 1 and "" or "s")
      if not model.hasRate and model.hasStore then
        parts[#parts + 1] = "rate from storage"
      end

      local footer = table.concat(parts, "   ")
      buf:blit(2, h, util.shorten(footer, max(1, w - 2)),
        model.error and theme.alarm or theme.line, theme.bg)
    end
  end

  return { refresh = function() canvas:markRenderDirty() end }
end

-- ---------------------------------------------------------------- settings ---

function view.settings(ctx)
  local app, root = ctx.app, ctx.root
  local cfg = app.cfg.power

  ctx.heading("POWER")

  ctx.row("Monitoring", function() return ctx.onOff(cfg.enabled) end, function()
    cfg.enabled = not cfg.enabled
    app:saveConfig()
    if cfg.enabled then pcall(app.power.poll, app.power, app.cfg) end
  end, ctx.onOffColor(function() return cfg.enabled end))

  ctx.row("Devices", function()
    local model = app.power
    if not model or #model.sources == 0 then return "none found" end
    local meters, stores = 0, 0
    for _, source in ipairs(model.sources) do
      if source.meter then meters = meters + 1 end
      if source.store then stores = stores + 1 end
    end
    return ("%d meter%s  %d batter%s"):format(
      meters, meters == 1 and "" or "s", stores, stores == 1 and "y" or "ies")
  end, function()
    local model = app.power
    if not model or #model.sources == 0 then
      root:toast("No energy peripheral found - press Rescan", "warning")
      return
    end

    -- One picker for the list, another for the chosen device's role, then back
    -- to the list -- the same shape the ignore list and the backdrop cycle use.
    local function editDevice(source)
      local entries = {}
      for _, role in ipairs(view.ROLES) do
        entries[#entries + 1] = {
          label = ctx.withHint(role.label, role.hint),
          value = role.id,
        }
      end
      if source._limitSet then
        entries[#entries + 1] = { label = "-- clear the transfer limit --", value = "nolimit" }
      end
      ctx.openPicker(source.name, entries, powerLib.roleOf(app.cfg, source), function(value)
        if value == "nolimit" then
          -- Advanced Peripherals treats a limit of the maximum as "no limit";
          -- there is no separate call to remove one.
          local ok, message = app.power:setLimit(source, 2147483647)
          root:toast(ok and "Transfer limit cleared" or message, ok and "success" or "error")
        else
          cfg.roles[source.name] = value
          app:saveConfig()
        end
        ctx.refreshRows()
      end)
    end

    local entries = {}
    for _, source in ipairs(model.sources) do
      local bits = {}
      if source.meter then
        bits[#bits + 1] = powerLib.roleOf(app.cfg, source):upper()
        bits[#bits + 1] = (source.rate and powerLib.format(source.rate) or "-") .. "/t"
      end
      if source.store and source.stored and source.capacity then
        bits[#bits + 1] = ("%d%%"):format(
          util.round(source.stored / max(1, source.capacity) * 100))
      end
      if source.fault then bits[#bits + 1] = source.fault end
      entries[#entries + 1] = {
        label = ("%s   %s"):format(
          util.shorten(source.name, 20), table.concat(bits, "  ")),
        value = source.name,
      }
    end

    ctx.openPicker("ENERGY DEVICES", entries, nil, function(name)
      local source = app.power:sourceByName(name)
      if source then editDevice(source) end
    end)
  end, function()
    return (app.power and app.power.available) and theme.good or theme.warn
  end)

  ctx.note("Press a device to say whether it measures supply or demand. "
    .. "A battery is read for stored and capacity.")

  ctx.row("Units", function() return cfg.unit end, function()
    ctx.openPicker("ENERGY UNITS",
      ctx.entriesOf(view.UNITS, function(u) return u end, function(u) return u end),
      cfg.unit,
      function(value)
        cfg.unit = value
        app:saveConfig()
        ctx.refreshRows()
      end)
  end)

  ctx.note("A label only. Nothing is converted.")

  ctx.row("Graph window", function() return powerLib.duration(cfg.windowSeconds) end, function()
    ctx.openPicker("GRAPH WINDOW",
      ctx.entriesOf(view.WINDOWS, powerLib.duration, function(v) return v end),
      cfg.windowSeconds,
      function(value)
        cfg.windowSeconds = value
        app:saveConfig()
        app.power:applyWindow(app.cfg)
        ctx.refreshRows()
      end)
  end)

  ctx.row("Sample every", function() return cfg.sampleSeconds .. " seconds" end, function()
    ctx.openPicker("SAMPLE RATE",
      ctx.entriesOf(view.SAMPLES,
        function(v) return v .. " seconds" end, function(v) return v end),
      cfg.sampleSeconds,
      function(value)
        cfg.sampleSeconds = value
        app:saveConfig()
        app.power:applyWindow(app.cfg)
        ctx.refreshRows()
      end)
  end)

  ctx.note("Every reading is a server-thread call, so a slow sample rate is "
    .. "the polite setting on a busy world.")

  ctx.row("Low alarm", function() return ctx.onOff(cfg.alarm) end, function()
    cfg.alarm = not cfg.alarm
    app:saveConfig()
  end, ctx.onOffColor(function() return cfg.alarm end))

  ctx.row("Alarm below", function() return cfg.lowPercent .. "%" end, function()
    ctx.openPicker("LOW POWER THRESHOLD",
      ctx.entriesOf({ 5, 10, 15, 20, 25, 30, 40, 50 },
        function(v) return v .. "%" end, function(v) return v end),
      cfg.lowPercent,
      function(value)
        cfg.lowPercent = value
        app:saveConfig()
        ctx.refreshRows()
      end)
  end)

  ctx.note("Fires the same sound, flash and redstone pulse a contact does, "
    .. "once per crossing. Needs a battery.")
  ctx.note("Redstone Output / Mode / Buffer drives a fuel gate from the same "
    .. "reading.")

  ctx.action("Rescan for energy devices", function()
    app:rescan()
    local count = app.power and #app.power.sources or 0
    root:toast(("%d energy device%s found"):format(count, count == 1 and "" or "s"),
      count > 0 and "success" or "warning")
  end)

  ctx.action("Clear the graph", function()
    app.power.history:clear()
    root:toast("Graph cleared", "info")
  end)

  ctx.spacer()
end

view.PALETTE = PALETTE
view.headerRows = headerRows

return view
