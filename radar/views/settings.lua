-- Settings, hardware and the ignore list.
--
-- Every setting is a row: a dim label on the left and a button showing the
-- current value on the right. Pressing the button either toggles it or opens a
-- full-page picker, so the same interaction works for a two-state switch and
-- for a twenty-eight entry sound list, and there is only one code path to keep
-- correct. The whole body is rebuilt whenever the hardware changes.

local basalt = require("basalt")
local config = require("radar.config")
local alertsLib = require("radar.alerts")
local scan   = require("radar.scan")
local theme  = require("radar.theme")
local util   = require("radar.util")

local view = {}

local LABEL_WIDTH = 14

function view.build(container, app, root)
  local body = container:addFrame({
    x = 1, y = 1,
    width = function(s) return s.parent.width end,
    height = function(s) return s.parent.height end,
    background = theme.bg,
    scrollable = true,
    scrollbarColor = theme.panel,
    scrollbarThumbColor = theme.line,
  })

  -- ----------------------------------------------------------- the picker ---
  local picker = container:addFrame({
    x = 2, y = 1, z = 800,
    width = function(s) return math.max(10, s.parent.width - 2) end,
    height = function(s) return s.parent.height end,
    background = theme.panel,
    visible = false,
  })
  local pickerTitle = picker:addLabel({ x = 2, y = 1, text = "", foreground = theme.accent })
  local pickerList = picker:addList({
    x = 2, y = 3,
    width = function(s) return math.max(4, s.parent.width - 2) end,
    height = function(s) return math.max(1, s.parent.height - 4) end,
    background = theme.panel,
    foreground = theme.text,
    selectionBackground = theme.accent,
    selectionForeground = theme.bg,
    scrollbarColor = theme.line,
    scrollbarThumbColor = theme.accent,
  })
  picker:addButton({
    x = 2, height = 1, width = 10,
    y = function(s) return s.parent.height end,
    text = "Cancel", background = theme.line, foreground = theme.text,
  }):onClick(function() picker.visible = false end)

  --- Opens the picker. Each entry is { label = , value = }; onPick receives
  --- the chosen value.
  local function openPicker(title, entries, currentValue, onPick)
    pickerTitle.text = title
    pickerList:clear()
    for _, entry in ipairs(entries) do
      local marker = (entry.value == currentValue) and "* " or "  "
      pickerList:addItem({
        text = marker .. entry.label,
        callback = function()
          picker.visible = false
          onPick(entry.value)
        end,
      })
    end
    picker.visible = true
    picker:markDirty()
  end

  -- ------------------------------------------------------------- row model ---
  local rows = {}        -- refreshed in place, so values never go stale
  local nextY = 1

  local function refreshRows()
    for _, entry in ipairs(rows) do
      entry.button.text = entry.text()
      if entry.color then entry.button.foreground = entry.color() end
    end
  end

  local function heading(text)
    body:addLabel({ x = 1, y = nextY, text = text, foreground = theme.accent })
    nextY = nextY + 1
    body:addFrame({
      x = 1, y = nextY, height = 1,
      width = function(s) return math.max(1, s.parent.width - 1) end,
      background = theme.line,
    })
    nextY = nextY + 1
  end

  local function spacer() nextY = nextY + 1 end

  --- A label plus a value button.
  local function row(label, text, onPress, color)
    body:addLabel({ x = 1, y = nextY, text = label, foreground = theme.dim })
    local button = body:addButton({
      x = LABEL_WIDTH + 1, y = nextY, height = 1,
      width = function(s) return math.max(6, s.parent.width - LABEL_WIDTH - 2) end,
      text = text(), background = theme.panel, foreground = color and color() or theme.text,
    })
    button:onClick(function()
      local ok, err = pcall(onPress)
      if not ok then root:toast("Failed: " .. tostring(err), "error") end
      refreshRows()
    end)
    rows[#rows + 1] = { button = button, text = text, color = color }
    nextY = nextY + 1
    return button
  end

  --- A full-width button with no label column.
  local function action(text, onPress, color)
    local button = body:addButton({
      x = 1, y = nextY, height = 1,
      width = function(s) return math.max(6, s.parent.width - 1) end,
      text = text, background = theme.panel, foreground = color or theme.accent,
    })
    button:onClick(function()
      local ok, err = pcall(onPress)
      if not ok then root:toast("Failed: " .. tostring(err), "error") end
      refreshRows()
    end)
    nextY = nextY + 1
    return button
  end

  local function note(text)
    body:addLabel({ x = 1, y = nextY, text = text, foreground = theme.line })
    nextY = nextY + 1
  end

  local function onOff(value) return value and "ON" or "off" end
  local function onOffColor(value)
    return function() return value() and theme.good or theme.dim end
  end

  --- Turns a plain array into picker entries.
  local function entriesOf(list, labelOf, valueOf)
    local out = {}
    for i, item in ipairs(list) do
      out[i] = { label = labelOf(item, i), value = valueOf and valueOf(item, i) or i }
    end
    return out
  end

  -- ---------------------------------------------------------------- build ---
  local function build()
    rows, nextY = {}, 1
    local children = body:getChildren()
    for i = #children, 1, -1 do children[i]:destroy() end

    local cfg = app.cfg

    -- tracking --------------------------------------------------------------
    heading("TRACKING")

    row("Mode", function()
      return cfg.mode == "fixed" and "FIXED - watch the base" or "SELF - watch you"
    end, function() app:toggleMode() end)

    row("Base", function()
      if not cfg.baseX then return "not set - press to use your position" end
      return ("%d, %d, %d"):format(cfg.baseX, cfg.baseY or 0, cfg.baseZ or 0)
    end, function()
      local ok, message = app:setBaseFromPosition()
      root:toast(message, ok and "success" or "error")
    end, function() return cfg.baseX and theme.text or theme.warn end)

    note("Press to snap the base to where you stand.")

    body:addLabel({ x = 1, y = nextY, text = "Base X Y Z", foreground = theme.dim })
    local coordInputs = {}
    for i, axis in ipairs({ "baseX", "baseY", "baseZ" }) do
      coordInputs[i] = body:addInput({
        x = LABEL_WIDTH + 1 + (i - 1) * 9, y = nextY,
        width = 8, height = 1,
        text = tostring(cfg[axis] or ""),
        placeholder = axis:sub(5),
        pattern = "[%d%-]",          -- Input tests each typed character

        background = theme.panel, foreground = theme.text,
        placeholderColor = theme.line,
      })
      coordInputs[i]:onEnter(function(self)
        local value = tonumber(self.text)
        if value then
          cfg[axis] = math.floor(value)
          app:saveConfig()
          root:toast("Base updated", "success")
        end
        refreshRows()
      end)
    end
    nextY = nextY + 1

    body:addLabel({ x = 1, y = nextY, text = "Username", foreground = theme.dim })
    local nameInput = body:addInput({
      x = LABEL_WIDTH + 1, y = nextY, height = 1,
      width = function(s) return math.max(6, s.parent.width - LABEL_WIDTH - 2) end,
      text = cfg.myName or "",
      placeholder = "exact, case sensitive",
      background = theme.panel, foreground = theme.text,
      placeholderColor = theme.line,
    })
    local function commitName(self)
      local value = self.text
      cfg.myName = (value and #value > 0) and value or nil
      app:saveConfig()
    end
    nameInput:onEnter(commitName)
    nameInput:onBlur(commitName)
    nextY = nextY + 1

    note("Your own name is excluded from the radar.")

    row("Rotation", function() return config.rotationLabel(cfg) end, function()
      local entries = {}
      for degrees = 0, 315, 45 do
        local names = {
          [0] = "North", [45] = "North-East", [90] = "East", [135] = "South-East",
          [180] = "South", [225] = "South-West", [270] = "West", [315] = "North-West",
        }
        entries[#entries + 1] = {
          label = ("%3d deg - %s at the top"):format(degrees, names[degrees]),
          value = degrees,
        }
      end
      openPicker("DISPLAY ROTATION", entries, cfg.rotation, function(value)
        cfg.rotation = value
        app:saveConfig()
        refreshRows()
      end)
    end)

    note("Turns the picture only. Bearings stay true.")
    spacer()

    -- scanning --------------------------------------------------------------
    heading("SCANNING")

    row("Range", function() return config.rangeLabel(cfg) .. " blocks" end, function()
      openPicker("SCAN RANGE",
        entriesOf(config.RANGES, function(r) return r.label end),
        cfg.rangeIndex,
        function(value) app:setRangeIndex(value); refreshRows() end)
    end)

    row("Alert within", function() return config.alertRangeLabel(cfg) .. " blocks" end, function()
      openPicker("ALERT RANGE",
        entriesOf(config.RANGES, function(r) return r.label end),
        cfg.alertRangeIndex,
        function(value)
          cfg.alertRangeIndex = value
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Sweep every", function() return config.scanInterval(cfg) .. " seconds" end, function()
      openPicker("SCAN INTERVAL",
        entriesOf(config.SCAN_INTERVALS, function(s) return s .. " seconds" end),
        cfg.scanIndex,
        function(value)
          cfg.scanIndex = value
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Other worlds", function()
      return cfg.dimFilter and "hidden" or "shown"
    end, function()
      cfg.dimFilter = not cfg.dimFilter
      app:saveConfig()
    end)

    note("MAX asks for the largest radius the server permits.")
    spacer()

    -- alerts ----------------------------------------------------------------
    heading("ALERTS")

    row("Master", function() return onOff(cfg.alert) end, function()
      app:toggleAlerts()
    end, onOffColor(function() return cfg.alert end))

    row("Screen flash", function() return onOff(cfg.flash) end, function()
      cfg.flash = not cfg.flash
      app:saveConfig()
    end, onOffColor(function() return cfg.flash end))

    row("Banner", function() return onOff(cfg.toast) end, function()
      cfg.toast = not cfg.toast
      app:saveConfig()
    end, onOffColor(function() return cfg.toast end))

    row("Sound", function()
      if #app.kit.speakers == 0 then return "no speaker attached" end
      return onOff(cfg.sound.enabled)
    end, function()
      cfg.sound.enabled = not cfg.sound.enabled
      app:saveConfig()
    end, function()
      return (#app.kit.speakers > 0 and cfg.sound.enabled) and theme.good or theme.dim
    end)

    row("Alert sound", function() return config.sound(cfg).label end, function()
      openPicker("ALERT SOUND",
        entriesOf(config.SOUNDS, function(s) return s.label end),
        cfg.sound.index,
        function(value)
          cfg.sound.index = value
          app:saveConfig()
          app.alerts:play()
          refreshRows()
        end)
    end)

    row("Volume", function() return ("%.2f"):format(cfg.sound.volume) end, function()
      openPicker("VOLUME",
        entriesOf({ 0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0 },
          function(v) return ("%.2f"):format(v) end, function(v) return v end),
        cfg.sound.volume,
        function(value)
          cfg.sound.volume = value
          app:saveConfig()
          app.alerts:play()
          refreshRows()
        end)
    end)

    row("Pitch", function() return ("%.2f"):format(cfg.sound.pitch) end, function()
      openPicker("PITCH",
        entriesOf({ 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0 },
          function(v) return ("%.2f"):format(v) end, function(v) return v end),
        cfg.sound.pitch,
        function(value)
          cfg.sound.pitch = value
          app:saveConfig()
          app.alerts:play()
          refreshRows()
        end)
    end)

    row("Repeats", function() return tostring(cfg.sound.repeats) end, function()
      openPicker("REPEAT COUNT",
        entriesOf({ 1, 2, 3, 4, 5 }, tostring, function(v) return v end),
        cfg.sound.repeats,
        function(value)
          cfg.sound.repeats = value
          app:saveConfig()
          refreshRows()
        end)
    end)

    action("Test the alert sound", function()
      if #app.kit.speakers == 0 then
        root:toast("No speaker on the network", "error")
      else
        app.alerts:play()
      end
    end)
    spacer()

    -- redstone --------------------------------------------------------------
    heading("REDSTONE OUTPUT")

    row("Output", function() return onOff(cfg.rs.enabled) end, function()
      cfg.rs.enabled = not cfg.rs.enabled
      app.alerts:invalidate()
      app.alerts:updateRedstone()
      app:saveConfig()
    end, onOffColor(function() return cfg.rs.enabled end))

    row("Side", function() return cfg.rs.side end, function()
      openPicker("OUTPUT SIDE",
        entriesOf(alertsLib.sides(), function(s) return s end, function(s) return s end),
        cfg.rs.side,
        function(value)
          -- Drop the old side before moving, or it stays latched on.
          pcall(redstone.setAnalogOutput, cfg.rs.side, 0)
          cfg.rs.side = value
          app.alerts:invalidate()
          app.alerts:updateRedstone()
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Mode", function()
      for _, mode in ipairs(config.RS_MODES) do
        if mode.id == cfg.rs.mode then return mode.label .. " - " .. mode.hint end
      end
      return cfg.rs.mode
    end, function()
      openPicker("OUTPUT MODE",
        entriesOf(config.RS_MODES,
          function(m) return m.label .. " - " .. m.hint end,
          function(m) return m.id end),
        cfg.rs.mode,
        function(value)
          cfg.rs.mode = value
          app.alerts:invalidate()
          app.alerts:updateRedstone()
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Pulse length", function() return cfg.rs.pulse .. " seconds" end, function()
      openPicker("PULSE LENGTH",
        entriesOf(config.RS_PULSE_OPTIONS,
          function(v) return v .. " seconds" end, function(v) return v end),
        cfg.rs.pulse,
        function(value)
          cfg.rs.pulse = value
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Trigger range", function()
      return config.RANGES[cfg.rs.rangeIndex].label .. " blocks"
    end, function()
      openPicker("TRIGGER RANGE",
        entriesOf(config.RANGES, function(r) return r.label end),
        cfg.rs.rangeIndex,
        function(value)
          cfg.rs.rangeIndex = value
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Inverted", function() return onOff(cfg.rs.invert) end, function()
      cfg.rs.invert = not cfg.rs.invert
      app.alerts:invalidate()
      app.alerts:updateRedstone()
      app:saveConfig()
    end, onOffColor(function() return cfg.rs.invert end))

    action("Test pulse", function()
      basalt.schedule(function()
        local wasEnabled = cfg.rs.enabled
        cfg.rs.enabled = true
        app.alerts:invalidate()
        app.alerts:setLevel(15)
        sleep(math.min(cfg.rs.pulse, 2))
        cfg.rs.enabled = wasEnabled
        app.alerts:invalidate()
        app.alerts:updateRedstone()
      end)
    end)
    spacer()

    -- environment -----------------------------------------------------------
    heading("ENVIRONMENT")

    row("Detector", function()
      return app.kit.env and ("attached: " .. app.kit.envName) or "not found"
    end, function()
      app:rescan()
      root:toast(app.kit.env and "Environment Detector found"
        or "Still no Environment Detector", app.kit.env and "success" or "warning")
    end, function() return app.kit.env and theme.good or theme.warn end)

    row("Polling", function() return onOff(cfg.env) end, function()
      cfg.env = not cfg.env
      app:saveConfig()
      if cfg.env then app:pollEnvironment(true) end
    end, onOffColor(function() return cfg.env end))

    row("Poll every", function() return cfg.envSeconds .. " seconds" end, function()
      openPicker("ENVIRONMENT POLL RATE",
        entriesOf({ 1, 2, 5, 10, 30 },
          function(v) return v .. " seconds" end, function(v) return v end),
        cfg.envSeconds,
        function(value)
          cfg.envSeconds = value
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Animation", function() return onOff(cfg.animate) end, function()
      cfg.animate = not cfg.animate
      app:saveConfig()
    end, onOffColor(function() return cfg.animate end))

    note("Animation drives the sky, clouds, rain and radar sweep.")
    spacer()

    -- displays --------------------------------------------------------------
    heading("DISPLAYS")

    row("Terminal", function() return cfg.terminalPage end, function()
      openPicker("TERMINAL PAGE",
        entriesOf(config.PAGES, function(p) return p end, function(p) return p end),
        cfg.terminalPage,
        function(value)
          root:setPage(value)
        end)
    end)

    if #app.kit.monitors == 0 then
      note("No monitors attached.")
    end
    for _, monitor in ipairs(app.kit.monitors) do
      local displayCfg = app:displayConfig(monitor.name)
      row(util.shorten(monitor.name, LABEL_WIDTH - 1), function()
        return ("%s   scale %.1f"):format(displayCfg.page, displayCfg.scale)
      end, function()
        openPicker("PAGE FOR " .. monitor.name,
          entriesOf(config.PAGES, function(p) return p end, function(p) return p end),
          displayCfg.page,
          function(value)
            displayCfg.page = value
            app:saveConfig()
            root:toast("Restart to apply monitor changes", "info")
            refreshRows()
          end)
      end)
      row("  text scale", function() return ("%.1f"):format(displayCfg.scale) end, function()
        openPicker("TEXT SCALE FOR " .. monitor.name,
          entriesOf({ 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0 },
            function(v) return ("%.1f"):format(v) end, function(v) return v end),
          displayCfg.scale,
          function(value)
            displayCfg.scale = value
            app:saveConfig()
            pcall(monitor.dev.setTextScale, value)
            refreshRows()
          end)
      end)
    end

    action("Rescan peripherals", function()
      app:rescan()
      root:toast(("%d monitor(s), %d speaker(s)"):format(
        #app.kit.monitors, #app.kit.speakers), "info")
    end)
    note("Monitors added or removed need a restart to get their own page.")
    spacer()

    -- ignore list -----------------------------------------------------------
    heading("IGNORE LIST")

    local function ignoredNames()
      local names = {}
      for name in pairs(app.ignore) do names[#names + 1] = name end
      table.sort(names)
      return names
    end

    row("Ignored", function()
      local names = ignoredNames()
      if #names == 0 then return "nobody" end
      return ("%d: %s"):format(#names, table.concat(names, ", "))
    end, function()
      local names = ignoredNames()
      if #names == 0 then
        root:toast("The ignore list is empty", "info")
        return
      end
      openPicker("REMOVE FROM IGNORE LIST",
        entriesOf(names, function(n) return n end, function(n) return n end), nil,
        function(value)
          app:unignorePlayer(value)
          root:toast(value .. " will be tracked again", "success")
          refreshRows()
        end)
    end)

    action("Ignore an online player", function()
      local online = {}
      for _, name in ipairs(scan.onlinePlayers(app.kit)) do
        if name ~= app.cfg.myName and not app.ignore[name] then
          online[#online + 1] = name
        end
      end
      if #online == 0 then
        root:toast("Nobody else is online", "info")
        return
      end
      openPicker("IGNORE A PLAYER",
        entriesOf(online, function(n) return n end, function(n) return n end), nil,
        function(value)
          app:ignorePlayer(value)
          root:toast("Ignoring " .. value, "success")
          refreshRows()
        end)
    end)
    spacer()

    -- log -------------------------------------------------------------------
    heading("HISTORY")
    row("Entries", function() return tostring(app.log:count()) end, function()
      app:clearLog()
      root:toast("Log cleared", "info")
    end)
    note("Press to clear. The C key does the same thing.")
    spacer()

    -- help ------------------------------------------------------------------
    heading("KEYBOARD")
    local shortcuts = {
      "1-6      jump to a page",
      "Lt / Rt  previous / next page",
      "Up / Dn  scan range up / down",
      "R        rotate the picture 45 deg",
      "T        FIXED / SELF tracking",
      "A        mute or unmute alerts",
      "P        test the alert sound",
      "N        ignore the nearest contact",
      "B        set the base to your position",
      "C        clear the log",
      "Q        quit",
    }
    for _, line in ipairs(shortcuts) do note(line) end
    note("Tap a monitor without a tab strip to change its page.")
    spacer()

    action("Quit Radar Station", function()
      app:stop()
      basalt.stop()
    end, theme.alarm)

    body:markDirty()
    refreshRows()
  end

  build()
  app:on("hardware", build)

  return {
    refresh = refreshRows,
    hidden = function() picker.visible = false end,
  }
end

return view
