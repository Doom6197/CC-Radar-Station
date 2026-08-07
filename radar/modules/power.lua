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
local linkLib  = require("radar.link")
local modules  = require("radar.modules")
local pixel    = require("radar.pixel")
local powerLib = require("radar.power")
local theme    = require("radar.theme")
local ui       = require("radar.ui")
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

-- Power clients broadcast on their own protocol; the merged totals go out to
-- the mobiles as one more payload type on the main link.
view.PROTOCOL = "radar_power"
view.RELAY_KIND = "pw"

view.defaults = {
  power = {
    enabled       = true,
    unit          = "FE",
    windowSeconds = 300,      -- five minutes of graph
    sampleSeconds = 1,
    alarm         = true,
    lowPercent    = 20,
    roles         = {},       -- source key -> "in" | "out" | "off"
    units         = {},       -- source key -> "fe" | "j"; see radar/power.lua

    -- Accept readings from power clients. The modem still has to be open for
    -- its own reasons -- a STANDALONE station never opens one -- so in
    -- practice this is a MAIN BASE deciding whether to trust the mesh.
    clients       = true,

    -- A MAIN BASE sends the merged totals on to every mobile, so a pocket
    -- computer with no energy hardware anywhere near it still has the page.
    relay         = true,
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
  p.clients = p.clients ~= false
  p.relay   = p.relay ~= false
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

  -- Per-device unit overrides. Only ids that exist; anything else falls back
  -- to what the device's own methods suggest.
  local units = {}
  if type(p.units) == "table" then
    for name, id in pairs(p.units) do
      if type(name) == "string" and powerLib.unit(id).id == id then
        units[name] = id
      end
    end
  end
  p.units = units
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

  -- Readings arriving from a power client.
  --
  -- A paired client addresses this computer directly, so on a shared server
  -- nobody else's readings can reach it. It also stamps the payload with the
  -- base it meant, which is what makes a broadcasting client -- the "any main
  -- base" option -- safe to ignore when it was meant for somebody else.
  linkLib.onProtocol(view.PROTOCOL, function(_, target, id, message)
    if not target or not target.cfg.power.clients then return false end
    if message.t ~= "pw" then return false end

    local meantFor = tonumber(message.b)
    if meantFor and meantFor ~= os.getComputerID() then return false end

    local accepted = target.power:applyClient(id, message)
    if accepted then target:emit("power") end
    return accepted
  end)

  -- Merged totals arriving from the main base, for a mobile with no energy
  -- hardware of its own.
  linkLib.onRelay(view.RELAY_KIND, function(_, target, message)
    if not target then return false end
    local accepted = target.power:applyRelay(message)
    if accepted then target:emit("power") end
    return accepted
  end)
end

--- One cycle of the poll loop. Split out so the whole decision -- poll, or
--- sit on what the main base relayed -- can be driven without a scheduler.
function view.tick(app, now)
  local model = app.power

  -- A mobile being fed the totals leaves its own hardware alone; it probably
  -- has none, and the merged figure from the base is the whole grid rather
  -- than whatever happens to be plugged into a pocket computer.
  if config.isMobile(app.cfg) and model:relayFresh(now) then
    app:emit("power")
    return false
  end

  model:poll(app.cfg, now)

  -- Raised through the app rather than straight at the alert channels, so it
  -- lands in the alert log and the status page's RECENT list alongside the
  -- arrivals. A buffer that emptied while nobody was watching is exactly the
  -- kind of thing you want to find written down afterwards.
  if model:checkAlarm(app.cfg, now) then
    app:alarm(("Power low - buffer at %d%%"):format(
      util.round(model.percent or 0)), "power")
  end

  -- The contact sweep already refreshes the line on its own cadence, but a
  -- buffer draining between sweeps has to move it too.
  if app.cfg.rs.enabled and app.cfg.rs.mode == "buffer" then
    app.alerts:updateRedstone()
  end

  -- Onward to the mobiles. Only the main base does this: it is the one that
  -- has collected every client, so it is the only one with a whole answer.
  if config.isMain(app.cfg) and app.cfg.power.relay and model.available then
    local payload = model:relayPayload()
    payload.n = app.cfg.power.sampleSeconds
    app.link:relay(view.RELAY_KIND, payload)
  end

  app:emit("power")
  return true
end

function view.start(app)
  local basalt = require("basalt")
  basalt.schedule(function()
    while app.running do
      -- The loop outlives the module being switched off, so it checks rather
      -- than assuming: there is no way to cancel a Basalt schedule, and a
      -- disabled page must stop costing server-thread calls.
      if app.cfg.power.enabled and modules.isEnabled(app.cfg, "power") then
        local ok, err = pcall(view.tick, app)
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

--- The compact panel a 1x1 monitor gets: percentage, gauge, net rate, and
--- whatever rows are left over as a graph. No heading, no separator, and the
--- unit dropped from the rate -- "NET -126 FE/" told you less than "-126"
--- and a graph one row taller.
local function drawTiny(buf, grid, app, w, h)
  local model = app.power
  local cfg = app.cfg.power

  if not model or not model.available then
    buf:blit(1, 1, "No power", theme.warn, theme.bg)
    if h >= 3 then
      buf:blit(1, 3, "hardware", theme.dim, theme.bg)
      buf:blit(1, 4, "found.", theme.dim, theme.bg)
    end
    return
  end

  local y = 1

  if model.percent then
    local pct = ("%d%%"):format(util.round(model.percent))
    buf:blit(1, y, pct, model.low and theme.alarm or theme.accent, theme.bg)

    -- Stored and capacity share the row with the percentage, since the bar
    -- below already says how full it is. A gap of at least one cell, or they
    -- run together and read as one number: "30%1.20G/4.00G".
    local both = powerLib.format(model.stored) .. "/" .. powerLib.format(model.capacity)
    local held = powerLib.format(model.stored)
    local text = (#both + #pct + 2 <= w) and both
      or ((#held + #pct + 2 <= w) and held or nil)
    if text then
      buf:blit(max(1, w - #text), y, text, theme.dim, theme.bg)
    end
    y = y + 1

    if h >= 4 then
      grid:resize(w, 1)
      grid:clear(BG)
      local box = { x = 1, y = 1, w = grid.w, h = 2 }
      chart.gauge(grid, box, model.percent / 100, model.low and ALARM or BANK, PANEL)
      chart.gaugeTicks(grid, box, 0.25, LINE)
      grid:blitTo(buf, 1, y)
      y = y + 1
    end
  end

  local net = powerLib.formatSigned(model.net)
  buf:blit(1, y, "NET", theme.dim, theme.bg)
  buf:blit(max(1, w - #net), y, net,
    model.net < 0 and theme.warn or theme.good, theme.bg)
  y = y + 1

  -- Whatever is left is the graph, which is the reason to have the page up.
  local bottom = h - ((h >= 7) and 1 or 0)
  local plotHeight = bottom - y + 1
  if plotHeight >= 2 then
    grid:resize(w, plotHeight)
    grid:clear(BG)
    local ins, outs, pct = model.history:series()
    local box = { x = 1, y = 1, w = grid.w, h = grid.h }
    if model.hasStore then
      chart.line(grid, box, {
        { values = pct, index = PANEL, fill = true, fillIndex = PANEL },
      }, { count = model.history.cap, min = 0, max = 100 })
    end
    local lo, hi = chart.line(grid, box, {
      { values = ins, index = IN },
      { values = outs, index = OUT },
    }, { count = model.history.cap, zero = true })
    chart.rule(grid, box, 0, lo, hi, LINE, 2)
    grid:blitTo(buf, 1, y)
  end

  if h >= 7 then
    local state = model:bufferState()
    local seconds, direction = model:timeToLimit()
    local footer = state
      or (seconds and ("%s %s"):format(direction, powerLib.duration(seconds)))
      or (model.error and "fault" or "holding")
    buf:blit(1, h, util.shorten(footer, w), theme.line, theme.bg)
  end
end

function view.build(container, app, root)
  local grid = pixel.new(1, 1, PALETTE)

  -- Where the graph reset landed on this draw, in the shape the flight page
  -- uses. Rebuilt every frame, because it moves with the width of the screen.
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

    if ui.isTiny(w) then
      return drawTiny(buf, grid, app, w, h)
    end

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
        local state = model:bufferState()
        local seconds, direction = model:timeToLimit()
        if state then
          parts[#parts + 1] = state
        elseif seconds then
          parts[#parts + 1] = ("%s in %s"):format(direction, powerLib.duration(seconds))
        elseif model.hasStore then
          parts[#parts + 1] = "holding"
        end
      end

      -- Where the figures came from. On a mobile that is the whole answer:
      -- the totals were computed on the main base and arrived finished.
      if model.relayed then
        parts[#parts + 1] = ("relayed   %d device%s"):format(
          model.deviceCount or 0, (model.deviceCount == 1) and "" or "s")
      else
        local count = #model:allSources()
        parts[#parts + 1] = ("%d device%s"):format(count, count == 1 and "" or "s")

        local clients = 0
        for _ in pairs(model.clients) do clients = clients + 1 end
        if clients > 0 then
          parts[#parts + 1] = ("%d client%s"):format(clients, clients == 1 and "" or "s")
        end
      end

      if not model.hasRate and model.hasStore then
        parts[#parts + 1] = "rate from storage"
      end

      -- The graph reset, on the page rather than three levels into the
      -- settings. The window is minutes long, so a spike from something that
      -- has since been fixed sits there squashing the scale flat until it
      -- ages out -- and wanting rid of it is exactly when you are looking at
      -- the graph, not when you are in a menu.
      local footer = table.concat(parts, "   ")
      local label = "[ RESET ]"
      local edge = w + 1
      if w >= #label + 12 then
        edge = w + 1 - #label
        buf:blit(edge, h, label, theme.accent, theme.bg)
        hits[#hits + 1] = { x1 = edge, x2 = w, y = h, key = "reset" }
        edge = edge - 1
      end

      buf:blit(2, h, util.shorten(footer, max(1, edge - 2)),
        model.error and theme.alarm or theme.line, theme.bg)
    end
  end

  --- Throws the history away and starts the graph again from now.
  local function resetGraph()
    app.power.history:clear()
    -- Straight back to a reading rather than an empty panel: the poll loop is
    -- seconds away and a graph that blanks on press looks like a fault.
    pcall(app.power.poll, app.power, app.cfg)
    canvas:markRenderDirty()
    if root then root:toast("Graph reset", "info") end
    return true
  end

  return {
    refresh = function() canvas:markRenderDirty() end,
    resetGraph = resetGraph,

    --- One press on this page, and only where it was drawn: a 1x1 monitor has
    --- no room for the button, and there a tap still moves the screen on.
    touch = function(x, y)
      for _, hit in ipairs(hits) do
        if y == hit.y and x >= hit.x1 and x <= hit.x2 then return resetGraph() end
      end
      return false
    end,
  }
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
    if not model or #model:allSources() == 0 then return "none found" end
    local meters, stores = 0, 0
    for _, source in ipairs(model:allSources()) do
      if source.meter then meters = meters + 1 end
      if source.store then stores = stores + 1 end
    end
    return ("%d meter%s  %d batter%s"):format(
      meters, meters == 1 and "" or "s", stores, stores == 1 and "y" or "ies")
  end, function()
    local model = app.power
    if not model or #model:allSources() == 0 then
      root:toast("No energy peripheral found - press Rescan", "warning")
      return
    end

    -- One picker for the list, another for the chosen device's role, then back
    -- to the list -- the same shape the ignore list and the backdrop cycle use.
    local function editDevice(source)
      local key = source.key or source.name
      local entries = {}
      for _, role in ipairs(view.ROLES) do
        entries[#entries + 1] = {
          label = ctx.withHint(role.label, role.hint),
          value = "role:" .. role.id,
        }
      end

      -- The unit matters as much as the role and is far easier to get wrong:
      -- Mekanism answers in Joules, and reading those as FE overstates a
      -- battery by exactly two and a half times.
      local current = powerLib.unitOf(app.cfg, source)
      for _, unit in ipairs(powerLib.UNITS) do
        entries[#entries + 1] = {
          label = (unit.id == current.id and "* " or "  ")
            .. ctx.withHint("reads " .. unit.label, unit.hint),
          value = "unit:" .. unit.id,
        }
      end

      if source._limitSet then
        entries[#entries + 1] = { label = "-- clear the transfer limit --", value = "nolimit" }
      end

      ctx.openPicker(source.name, entries,
        "role:" .. powerLib.roleOf(app.cfg, source), function(value)
        if value == "nolimit" then
          -- Advanced Peripherals treats a limit of the maximum as "no limit";
          -- there is no separate call to remove one.
          local ok, message = app.power:setLimit(source, 2147483647)
          root:toast(ok and "Transfer limit cleared" or message, ok and "success" or "error")
        elseif value:sub(1, 5) == "unit:" then
          cfg.units[key] = value:sub(6)
          app:saveConfig()
          pcall(app.power.poll, app.power, app.cfg)
          root:toast(source.name .. " reads " ..
            powerLib.unit(cfg.units[key]).label, "success")
        else
          cfg.roles[key] = value:sub(6)
          app:saveConfig()
        end
        ctx.refreshRows()
      end)
    end

    local entries = {}
    for _, source in ipairs(model:allSources()) do
      local bits = {}
      if source.meter then
        bits[#bits + 1] = powerLib.roleOf(app.cfg, source):upper()
        bits[#bits + 1] = (source.rate and powerLib.format(source.rate) or "-") .. "/t"
      end
      if source.store and source.stored and source.capacity then
        bits[#bits + 1] = ("%d%%"):format(
          util.round(source.stored / max(1, source.capacity) * 100))
      end
      -- A device being read in anything but plain FE says so here, because it
      -- is the difference between a right answer and one 2.5 times too big.
      local unit = powerLib.unitOf(app.cfg, source)
      if unit.id ~= "fe" then bits[#bits + 1] = unit.label end

      if source.fault then bits[#bits + 1] = source.fault end

      -- A device on a client is named for the client as well as for itself:
      -- "energyDetector_0" on its own says nothing about which room it is in.
      local name = source.remote
        and (util.shorten(source.client, 10) .. "/" .. util.shorten(source.name, 12))
        or util.shorten(source.name, 20)

      entries[#entries + 1] = {
        label = ("%s   %s"):format(name, table.concat(bits, "  ")),
        value = source.key,
      }
    end

    ctx.openPicker("ENERGY DEVICES", entries, nil, function(key)
      local source = app.power:sourceByKey(key)
      if source then editDevice(source) end
    end)
  end, function()
    return (app.power and app.power.available) and theme.good or theme.warn
  end)

  ctx.note("Press a device to say whether it measures supply or demand. "
    .. "A battery is read for stored and capacity.")

  -- power clients ------------------------------------------------------------
  ctx.row("Clients", function()
    local list = app.power and app.power:clientList() or {}
    if #list == 0 then
      if not app.link.open then return "off - the modem is shut" end
      return cfg.clients and "listening - none heard yet" or "off"
    end
    local devices = 0
    for _, client in ipairs(list) do devices = devices + #client.sources end
    return ("%d client%s   %d device%s"):format(
      #list, #list == 1 and "" or "s", devices, devices == 1 and "" or "s")
  end, function()
    local list = app.power and app.power:clientList() or {}
    if #list == 0 then
      cfg.clients = not cfg.clients
      app:saveConfig()
      root:toast(cfg.clients and "Listening for power clients"
        or "Ignoring power clients", "info")
      return
    end
    local entries = {}
    for _, client in ipairs(list) do
      local devices = #client.sources
      entries[#entries + 1] = {
        label = ("%s   id %d   %d device%s"):format(
          util.shorten(client.name, 18), client.id, devices,
          devices == 1 and "" or "s"),
        value = client.id,
      }
    end
    ctx.openPicker("POWER CLIENTS REPORTING", entries, nil, function() end)
  end, function()
    if not cfg.clients then return theme.dim end
    return (app.power and next(app.power.clients)) and theme.good or theme.warn
  end)

  ctx.note("Run powerclient on any computer wired to meters or batteries and "
    .. "it reports here. The modem has to be open, so this needs the MAIN "
    .. "BASE role.")

  ctx.row("Relay power", function() return ctx.onOff(cfg.relay) end, function()
    cfg.relay = not cfg.relay
    app:saveConfig()
  end, ctx.onOffColor(function() return cfg.relay end))

  ctx.note("A MAIN BASE sends the merged totals on, so a pocket computer has "
    .. "the page with no energy hardware anywhere near it.")

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
    local count = app.power and #app.power:allSources() or 0
    root:toast(("%d energy device%s found"):format(count, count == 1 and "" or "s"),
      count > 0 and "success" or "warning")
  end)

  ctx.action("Reset the graph", function()
    app.power.history:clear()
    root:toast("Graph reset", "info")
  end)

  ctx.note("The RESET button on the page itself does the same thing, which is "
    .. "where you will want it.")

  ctx.spacer()
end

view.PALETTE = PALETTE
view.headerRows = headerRows

return view
