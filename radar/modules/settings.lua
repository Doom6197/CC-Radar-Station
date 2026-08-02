-- SETTINGS module: everything configurable, on one scrolling page.
--
-- Every setting is a row: a dim label on the left and a button showing the
-- current value on the right. Pressing the button either toggles it or opens a
-- full-page picker, so the same interaction works for a two-state switch and
-- for a twenty-eight entry sound list, and there is only one code path to keep
-- correct. The whole body is rebuilt whenever the hardware or the module set
-- changes.
--
-- What is HERE is what belongs to the station rather than to a page: the
-- profile, which modules are on, tracking, the scope, the sweep, the link, the
-- alerts, the redstone line, the displays and the ignore list. Anything owned
-- by one page is built by that page's module through settings(ctx) -- the
-- weather module contributes ENVIRONMENT and BACKDROP, the power module
-- contributes POWER -- and those sections come and go with their modules
-- rather than being switched on and off from in here.

local basalt = require("basalt")
local config = require("radar.config")
local alertsLib = require("radar.alerts")
local linkLib = require("radar.link")
local modules = require("radar.modules")
local profiles = require("radar.profiles")
local scan   = require("radar.scan")
local theme  = require("radar.theme")
local util   = require("radar.util")

local view = {
  id = "settings",
  title = "SETTINGS",
  short = "SET",
  order = 90,
  core = true,
  -- A monitor has no keyboard, and this page is mostly typing.
  monitor = false,
  summary = "everything configurable; terminal only",
}

local LABEL_WIDTH = 14

-- Below this width the side-by-side layout stops working. A pocket computer is
-- 26 cells across: a 14-cell label column leaves ten for the value, which turns
-- "FIXED - watch the base" into "FIXED - wa" and puts two of the three
-- coordinate boxes off the right-hand edge entirely. Under it, every row
-- stacks -- label on one line, full-width value under it.
view.NARROW_WIDTH = 34

view.LAYOUTS = {
  { id = "auto",    label = "Auto",         hint = "stacked on a small screen" },
  { id = "stacked", label = "Stacked",      hint = "label above the value" },
  { id = "columns", label = "Side by side", hint = "label beside the value" },
}

view.defaults = {
  settingsLayout = "auto",
}

function view.sanitise(cfg)
  local known = false
  for _, entry in ipairs(view.LAYOUTS) do
    if entry.id == cfg.settingsLayout then known = true end
  end
  if not known then cfg.settingsLayout = "auto" end
end

--- Whether rows stack, given the screen and the operator's preference.
function view.isNarrow(width, layout)
  if layout == "stacked" then return true end
  if layout == "columns" then return false end
  return (tonumber(width) or 51) < view.NARROW_WIDTH
end

function view.build(container, app, root)
  -- How wide the screen this page is being built for actually is. Set at the
  -- top of every build(), and read by row(), note() and the picker. A terminal
  -- cannot be resized while it is running, so deciding once per build is
  -- enough -- and build() re-runs whenever the module set or the layout
  -- setting changes.
  local narrow = false
  local screenWidth = 51

  local function measure()
    local frame = root and root.root
    screenWidth = (frame and tonumber(frame.width)) or 51
    narrow = view.isNarrow(screenWidth, app.cfg.settingsLayout)
  end

  --- "LABEL - the hint", or just the label when there is no room for both.
  --- Picker entries are the worst case on a small screen: the list is barely
  --- twenty cells wide, and a trailing hint pushes the part that identifies
  --- the entry off the end.
  local function withHint(label, hint)
    if narrow or not hint then return label end
    return label .. " - " .. hint
  end

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
  -- Inset by a cell on a screen with room to spare, so it reads as a panel
  -- over the page; flush to the edges on one that has not, where two cells of
  -- decoration is two cells of the entry you are trying to read.
  local function pickerInset() return narrow and 0 or 1 end

  local picker = container:addFrame({
    y = 1, z = 800,
    x = function() return 1 + pickerInset() end,
    width = function(s) return math.max(10, s.parent.width - pickerInset() * 2) end,
    height = function(s) return s.parent.height end,
    background = theme.panel,
    visible = false,
  })
  local pickerTitle = picker:addLabel({
    y = 1, text = "", foreground = theme.accent,
    x = function() return 1 + pickerInset() end,
  })
  local pickerList = picker:addList({
    y = 3,
    x = function() return 1 + pickerInset() end,
    width = function(s) return math.max(4, s.parent.width - pickerInset() * 2) end,
    height = function(s) return math.max(1, s.parent.height - 4) end,
    background = theme.panel,
    foreground = theme.text,
    selectionBackground = theme.accent,
    selectionForeground = theme.bg,
    scrollbarColor = theme.line,
    scrollbarThumbColor = theme.accent,
  })
  picker:addButton({
    height = 1, width = 10,
    x = function() return 1 + pickerInset() end,
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

  local refreshRows
  local build

  --- Offers whichever base stations have announced themselves lately. Pairing
  --- is a choice, not a subscription, so two crews on one world never end up
  --- watching each other's contacts.
  local function openBasePicker()
    local found = app.link:knownBases()
    if #found == 0 then
      root:toast(app.link.open and "No base stations heard"
        or (app.link.error or "No modem attached"),
        app.link.open and "warning" or "error")
      return
    end
    local entries = {}
    for i, base in ipairs(found) do
      entries[i] = { label = ("%s   (id %d)"):format(base.name, base.id), value = base.id }
    end
    openPicker("BASE STATIONS HEARD", entries, app.cfg.pairedBaseId, function(id)
      local name
      for _, base in ipairs(found) do
        if base.id == id then name = base.name end
      end
      app:pairWithBase(id, name)
      root:toast("Linked to " .. (name or ("computer " .. id)), "success")
      refreshRows()
    end)
  end

  refreshRows = function()
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

  --- A label plus a value button: side by side where there is room, stacked
  --- where there is not. Stacking costs a row per setting on a page that
  --- already scrolls, and buys the value the whole width of the screen.
  local function row(label, text, onPress, color)
    local button
    if narrow then
      body:addLabel({ x = 1, y = nextY, text = label, foreground = theme.dim })
      nextY = nextY + 1
      button = body:addButton({
        x = 1, y = nextY, height = 1,
        width = function(s) return math.max(6, s.parent.width - 1) end,
        text = text(), background = theme.panel,
        foreground = color and color() or theme.text,
      })
    else
      body:addLabel({ x = 1, y = nextY, text = label, foreground = theme.dim })
      button = body:addButton({
        x = LABEL_WIDTH + 1, y = nextY, height = 1,
        width = function(s) return math.max(6, s.parent.width - LABEL_WIDTH - 2) end,
        text = text(), background = theme.panel,
        foreground = color and color() or theme.text,
      })
    end
    button:onClick(function()
      local ok, err = pcall(onPress)
      if not ok then root:toast("Failed: " .. tostring(err), "error") end
      refreshRows()
    end)
    rows[#rows + 1] = { button = button, text = text, color = color }
    nextY = nextY + 1
    return button
  end

  --- A full-width text input under its own label. Every one of these was
  --- previously pinned to the label column, which put it off the edge of a
  --- pocket screen.
  local function input(label, props)
    body:addLabel({ x = 1, y = nextY, text = label, foreground = theme.dim })
    if narrow then nextY = nextY + 1 end
    local element = body:addInput({
      x = narrow and 1 or (LABEL_WIDTH + 1), y = nextY, height = 1,
      width = function(s)
        return math.max(6, s.parent.width - (narrow and 1 or (LABEL_WIDTH + 2)))
      end,
      background = theme.panel, foreground = theme.text,
      placeholderColor = theme.line,
      text = props.text, placeholder = props.placeholder,
    })
    nextY = nextY + 1
    return element
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

  --- Explanatory small print. Wrapped rather than clipped: a note cut off at
  --- twenty-five cells is worse than no note at all, because it reads as a
  --- sentence that means something other than what it says.
  ---
  --- A line that already fits is emitted untouched. util.wrap rejoins on single
  --- spaces, which would collapse the run of spaces the keyboard list uses to
  --- line its descriptions up into a column.
  local function note(text)
    local room = math.max(8, screenWidth - 1)
    if #text <= room then
      body:addLabel({ x = 1, y = nextY, text = text, foreground = theme.line })
      nextY = nextY + 1
      return
    end
    for _, line in ipairs(util.wrap(text, room)) do
      body:addLabel({ x = 1, y = nextY, text = line, foreground = theme.line })
      nextY = nextY + 1
    end
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

  --- What a module's settings() is handed: everything it needs to build a
  --- section that matches the rest of the page, and nothing else. A module
  --- cannot reach the row list or the layout cursor, so it cannot leave the
  --- page half built.
  local ctx = {
    app = app, root = root,
    heading = heading, row = row, action = action, note = note, spacer = spacer,
    input = input, withHint = withHint,
    openPicker = openPicker,
    refreshRows = function() refreshRows() end,
    entriesOf = entriesOf, onOff = onOff, onOffColor = onOffColor,
    body = body, LABEL_WIDTH = LABEL_WIDTH,
    rebuild = function() build() end,
    -- Read by a module that wants to lay something out itself. Both are
    -- refreshed before any module's settings() is called.
    isNarrow = function() return narrow end,
    screenWidth = function() return screenWidth end,
  }

  -- ---------------------------------------------------------------- build ---
  build = function()
    measure()
    rows, nextY = {}, 1
    local children = body:getChildren()
    for i = #children, 1, -1 do children[i]:destroy() end

    local cfg = app.cfg

    -- profile ---------------------------------------------------------------
    -- Applying one is destructive on purpose, so the only way in is the picker
    -- rather than a toggle that could be hit by accident.
    heading("PROFILE")

    row("This station", function() return profiles.summary(cfg, narrow) end, function()
      local entries = {}
      for _, entry in ipairs(profiles.LIST) do
        entries[#entries + 1] = {
          label = withHint(entry.label, entry.hint),
          value = entry.id,
        }
      end
      openPicker("APPLY A PROFILE", entries, cfg.profile, function(value)
        app:setProfile(value)
        root:toast("Applied " .. profiles.label(value), "success")
        build()
      end)
    end, function() return cfg.profile and theme.accent or theme.dim end)

    note("Applying one OVERWRITES the settings it covers - tracking, the "
      .. "scope, poll rates and which modules are on. Everything stays "
      .. "editable afterwards.")

    -- Kept at the top, next to the profile, because it is the row you want
    -- when the rest of the page is the thing that is hard to read.
    row("Layout", function()
      for _, entry in ipairs(view.LAYOUTS) do
        if entry.id == cfg.settingsLayout then
          if cfg.settingsLayout == "auto" then
            return ("auto - %s"):format(narrow and "stacked" or "side by side")
          end
          return entry.label
        end
      end
      return cfg.settingsLayout
    end, function()
      openPicker("SETTINGS LAYOUT",
        entriesOf(view.LAYOUTS,
          function(e) return withHint(e.label, e.hint) end,
          function(e) return e.id end),
        cfg.settingsLayout,
        function(value)
          cfg.settingsLayout = value
          app:saveConfig()
          build()
        end)
    end)

    note("This page only. Stacked puts each value on its own line, "
      .. "which is what a 26-cell pocket screen needs.")
    spacer()

    -- modules ---------------------------------------------------------------
    heading("MODULES")

    for _, entry in ipairs(modules.all()) do
      local id = entry.id
      row(util.shorten(entry.title, LABEL_WIDTH - 1), function()
        if entry.core then return "always on" end
        return modules.isEnabled(cfg, id) and "ON" or "off"
      end, function()
        if entry.core then
          root:toast(entry.title .. " cannot be switched off", "info")
          return
        end
        app:toggleModule(id)
        -- The tab strip, the terminal page and every monitor's rotation may
        -- all have changed, so the page is rebuilt rather than refreshed.
        build()
        root:toast(entry.title .. (modules.isEnabled(cfg, id) and " on" or " off"),
          "info")
      end, function()
        if entry.core then return theme.dim end
        return modules.isEnabled(cfg, id) and theme.good or theme.dim
      end)
      if entry.summary then note("  " .. entry.summary) end
    end

    for _, failure in ipairs(modules.failures or {}) do
      note("! " .. util.shorten(failure.id .. ": " .. failure.error, 160))
    end

    note("A module is one file in radar/modules/. Drop one in and it is "
      .. "a page here after a restart.")
    spacer()

    -- tracking --------------------------------------------------------------
    heading("TRACKING")

    row("Mode", function()
      return cfg.mode == "fixed" and "FIXED - watch the base" or "SELF - watch you"
    end, function() app:toggleMode() end)

    row("Base", function()
      if not cfg.baseX then
        return narrow and "not set - press to set"
          or "not set - press to use your position"
      end
      return ("%d, %d, %d"):format(cfg.baseX, cfg.baseY or 0, cfg.baseZ or 0)
    end, function()
      local ok, message = app:setBaseFromPosition()
      root:toast(message, ok and "success" or "error")
    end, function() return cfg.baseX and theme.text or theme.warn end)

    note("Press to snap the base to where you stand.")

    -- Three boxes on one line. Stacked, the label gets its own row and the
    -- boxes start hard left; side by side they sit in the value column. The
    -- old fixed offsets needed 41 cells and ran off a pocket screen.
    body:addLabel({ x = 1, y = nextY, text = "Base X Y Z", foreground = theme.dim })
    if narrow then nextY = nextY + 1 end
    local coordX = narrow and 1 or (LABEL_WIDTH + 1)
    local coordW = narrow and 7 or 8
    local coordGap = coordW + 1
    for i, axis in ipairs({ "baseX", "baseY", "baseZ" }) do
      local box = body:addInput({
        x = coordX + (i - 1) * coordGap, y = nextY,
        width = coordW, height = 1,
        text = tostring(cfg[axis] or ""),
        placeholder = axis:sub(5),
        pattern = "[%d%-]",          -- Input tests each typed character

        background = theme.panel, foreground = theme.text,
        placeholderColor = theme.line,
      })
      box:onEnter(function(self)
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

    local nameInput = input("Username", {
      text = cfg.myName or "",
      placeholder = "exact, case sensitive",
    })
    local function commitName(self)
      local value = self.text
      cfg.myName = (value and #value > 0) and value or nil
      app:saveConfig()
    end
    nameInput:onEnter(commitName)
    nameInput:onBlur(commitName)

    note("Your own name is excluded from the radar.")

    -- orientation -----------------------------------------------------------
    heading("ORIENTATION")

    row("Scope", function()
      return config.isUnlocked(cfg) and "UNLOCKED - follows you" or "LOCKED - fixed bearing"
    end, function()
      local unlocked = app:toggleOrientation()
      if unlocked and not app.heading then
        root:toast("Unlocked, but your heading is unreadable. Set a username.", "warning")
      end
    end, function() return config.isUnlocked(cfg) and theme.accent or theme.text end)

    row("Bearing up", function() return config.rotationLabel(cfg) end, function()
      local names = {
        [0] = "North", [45] = "North-East", [90] = "East", [135] = "South-East",
        [180] = "South", [225] = "South-West", [270] = "West", [315] = "North-West",
      }
      local entries = {}
      for degrees = 0, 315, 45 do
        entries[#entries + 1] = {
          label = ("%3d deg - %s at the top"):format(degrees, names[degrees]),
          value = degrees,
        }
      end
      openPicker("BEARING AT THE TOP", entries, cfg.rotation, function(value)
        cfg.rotation = value
        app:saveConfig()
        refreshRows()
      end)
    end, function() return config.isUnlocked(cfg) and theme.line or theme.text end)

    note("Used while locked. Turns the picture only; bearings stay true.")

    row("Heading steps", function() return config.headingStepLabel(cfg) end, function()
      openPicker("HEADING STEPS",
        entriesOf(config.HEADING_STEPS,
          function(s) return s.label end, function(s) return s.value end),
        cfg.headingStep,
        function(value)
          cfg.headingStep = value
          app:readHeading()
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Heading rate", function() return cfg.headingSeconds .. " seconds" end, function()
      openPicker("HEADING POLL RATE",
        entriesOf(config.HEADING_INTERVALS,
          function(v) return v .. " seconds" end, function(v) return v end),
        cfg.headingSeconds,
        function(value)
          cfg.headingSeconds = value
          app:saveConfig()
          refreshRows()
        end)
    end)

    row("Ease turns", function() return onOff(cfg.headingSmooth) end, function()
      cfg.headingSmooth = not cfg.headingSmooth
      app:readHeading()
      app:saveConfig()
    end, onOffColor(function() return cfg.headingSmooth end))

    note("Slide into a turn instead of jumping to it. Needs animation on.")

    -- Animation lives here rather than with the weather settings because it
    -- drives the radar sweep and the eased turn directly above as well as the
    -- sky -- and because a station with the weather module switched off would
    -- otherwise have no way to reach it at all.
    row("Animation", function() return onOff(cfg.animate) end, function()
      cfg.animate = not cfg.animate
      app:saveConfig()
    end, onOffColor(function() return cfg.animate end))

    note("Drives the radar sweep, eased turns, and the sky.")
    note("Off is the quiet setting for a pocket computer.")

    row("Now facing", function()
      return config.orientationLabel(cfg, app.heading)
    end, function()
      app:readHeading()
      root:toast(app.heading and ("Heading " .. math.floor(app.heading) .. " deg")
        or "No heading - set your username", app.heading and "info" or "warning")
    end, function() return app.heading and theme.good or theme.dim end)

    note("Unlocking needs your username, so the radar can read your yaw.")
    note("The L key locks and unlocks it too.")
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

    -- link ------------------------------------------------------------------
    -- Only the rows the chosen role actually uses are built, so the page does
    -- not grow a networking section for a station that has no network.
    heading("LINK")

    row("Role", function() return config.roleLabel(cfg, narrow) end, function()
      openPicker("STATION ROLE",
        entriesOf(config.ROLES,
          function(r) return withHint(r.label, r.hint) end,
          function(r) return r.id end),
        cfg.role,
        function(value)
          app:setRole(value)
          -- The rest of this section depends on the role, so it is rebuilt
          -- rather than left showing rows that no longer apply.
          build()
        end)
    end, function() return cfg.role == "station" and theme.text or theme.accent end)

    if cfg.role == "station" then
      note("STATION is the stand-alone radar, exactly as before.")
      note("A ship assembled by Create: Aeronautics cannot scan for itself, "
        .. "so pair a BASE on the ground with a SHIP aboard.")
    else
      row("Modem", function()
        if not app.kit.modem then return "not found" end
        return app.kit.modem.name .. (app.kit.modem.wireless and "  wireless" or "  wired")
      end, function()
        app:rescan()
        root:toast(app.kit.modem and ("Modem: " .. app.kit.modem.name)
          or "Still no modem", app.kit.modem and "success" or "warning")
      end, function() return app.kit.modem and theme.good or theme.warn end)
      note("An ender modem has no range limit and crosses dimensions.")
    end

    if cfg.role == "base" then
      local stationInput = input("Station name", {
        text = cfg.stationName,
        placeholder = "how ships see this base",
      })
      local function commitStationName(self)
        app:setStationName(self.text)
        self.text = cfg.stationName
      end
      stationInput:onEnter(commitStationName)
      stationInput:onBlur(commitStationName)

      row("Relay weather", function() return onOff(cfg.relayWeather) end, function()
        app:toggleRelayWeather()
      end, onOffColor(function() return cfg.relayWeather end))

      note("Also sends the environment, so the ship's weather page works.")

      row("Broadcasting", function()
        local text = app.link:summary(cfg)
        return text
      end, function()
        app.link:attach(app.kit, cfg)
        app.link:announce(cfg)
        root:toast(app.link.open and "Announced on the network"
          or (app.link.error or "No modem"), app.link.open and "success" or "error")
      end, function() return app.link.open and theme.good or theme.warn end)
    end

    if cfg.role == "ship" then
      row("Paired base", function()
        return config.pairedLabel(cfg) or "not paired - scan below"
      end, function()
        openBasePicker()
      end, function() return cfg.pairedBaseId and theme.text or theme.warn end)

      action("Scan for base stations", function()
        if not app.link.open then
          root:toast(app.link.error or "No modem attached", "error")
          return
        end
        root:toast("Listening for " .. linkLib.SCAN_SECONDS .. " seconds...", "info")
        -- Listening blocks, so it runs as a schedule and the UI stays live.
        basalt.schedule(function()
          sleep(linkLib.SCAN_SECONDS)
          openBasePicker()
        end)
      end)

      row("Link", function() return (app.link:summary(cfg)) end, function()
        app:checkLink()
        root:toast((app.link:summary(cfg)), app.link:status(cfg) and "warning" or "success")
      end, function()
        local _, healthy = app.link:summary(cfg)
        return healthy and theme.good or theme.warn
      end)

      note("A ship needs no Player Detector and no GPS: the base reads the "
        .. "pilot by name, so it sees them in the air.")
    end
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
      local mode = config.redstoneMode(cfg)
      return withHint(mode.label, mode.hint)
    end, function()
      openPicker("OUTPUT MODE",
        entriesOf(config.RS_MODES,
          function(m) return withHint(m.label, m.hint) end,
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

    note("Pulse, Hold and Analog read the contact list. A mode added by a "
      .. "module reads whatever that module measures.")

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

    -- the modules' own sections ---------------------------------------------
    -- In page order, so a section turns up where its tab does. A module that
    -- throws while building loses its section rather than the whole page.
    for _, entry in ipairs(modules.enabled(cfg)) do
      if entry.id ~= view.id and type(entry.settings) == "function" then
        local ok, err = pcall(entry.settings, ctx)
        if not ok then
          heading(entry.title)
          note("This module's settings failed to build:")
          note(util.shorten(tostring(err), 46))
          spacer()
        end
      end
    end

    -- displays --------------------------------------------------------------
    heading("DISPLAYS")

    local pages = config.pages(cfg)
    local terminalPages = config.terminalPages(cfg)

    row("Terminal", function() return cfg.terminalPage end, function()
      openPicker("TERMINAL PAGE",
        entriesOf(terminalPages, function(p) return p end, function(p) return p end),
        cfg.terminalPage,
        function(value)
          root:setPage(value)
        end)
    end)

    row("Tap to change", function() return onOff(cfg.tapCycle) end, function()
      cfg.tapCycle = not cfg.tapCycle
      app:saveConfig()
    end, onOffColor(function() return cfg.tapCycle end))

    note("Right-click a monitor in game to move it to the next page.")

    if #app.kit.monitors == 0 then
      note("No monitors attached.")
    end
    for _, monitor in ipairs(app.kit.monitors) do
      local displayCfg = app:displayConfig(monitor.name)

      row(util.shorten(monitor.name, LABEL_WIDTH - 1), function()
        return ("%s   scale %.1f"):format(displayCfg.page, displayCfg.scale)
      end, function()
        openPicker("PAGE FOR " .. monitor.name,
          entriesOf(pages, function(p) return p end, function(p) return p end),
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

      row("  auto cycle", function()
        if not displayCfg.cycle then return "off" end
        return ("every %ds   %d pages"):format(
          displayCfg.cycleSeconds, #config.cyclePages(cfg, displayCfg))
      end, function()
        displayCfg.cycle = not displayCfg.cycle
        app:saveConfig()
      end, function() return displayCfg.cycle and theme.good or theme.dim end)

      row("  cycle every", function() return displayCfg.cycleSeconds .. " seconds" end, function()
        openPicker("CYCLE INTERVAL FOR " .. monitor.name,
          entriesOf(config.CYCLE_INTERVALS,
            function(v) return v .. " seconds" end, function(v) return v end),
          displayCfg.cycleSeconds,
          function(value)
            displayCfg.cycleSeconds = value
            app:saveConfig()
            refreshRows()
          end)
      end)

      -- The rotation list is a set rather than a single choice, so the picker
      -- toggles one page and opens itself again for the next.
      local function editRotation()
        local entries = {}
        for _, page in ipairs(pages) do
          local inRotation = not displayCfg.cycleSkip[page]
          entries[#entries + 1] = {
            label = (inRotation and "[x] " or "[ ] ") .. page,
            value = page,
          }
        end
        entries[#entries + 1] = { label = "-- done --", value = false }
        openPicker("PAGES IN ROTATION: " .. monitor.name, entries, nil, function(page)
          if not page then refreshRows(); return end
          local skip = displayCfg.cycleSkip
          skip[page] = (not skip[page]) or nil
          -- Refuse to empty the rotation. config.cyclePages papers over an
          -- empty set by handing back one page, so the count has to be taken
          -- from the skip list itself.
          local remaining = 0
          for _, id in ipairs(pages) do
            if not skip[id] then remaining = remaining + 1 end
          end
          if remaining == 0 then
            skip[page] = nil
            root:toast("At least one page has to stay in the rotation", "warning")
          end
          app:saveConfig()
          refreshRows()
          editRotation()
        end)
      end

      row("  cycle pages", function()
        local inRotation = config.cyclePages(cfg, displayCfg)
        if #inRotation == #pages then return "all pages" end
        return table.concat(inRotation, " ")
      end, editRotation)
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

    -- help ------------------------------------------------------------------
    heading("KEYBOARD")

    -- Two descriptions per key. This is the one list on the page that must not
    -- be wrapped -- the run of spaces is what lines the descriptions up into a
    -- column, and note() rejoins wrapped text on single spaces -- so instead of
    -- wrapping, a narrow screen gets a shorter description that still fits.
    local shortcuts = {
      { "1-9",     "jump to a page",                "jump to a page" },
      { "Lt / Rt", "previous / next page",          "prev/next page" },
      { "Up / Dn", "scan range up / down",          "range up/down" },
      { "R",       "rotate the picture 45 deg",     "rotate 45 deg" },
      { "L",       "lock / unlock the orientation", "lock/unlock scope" },
      { "T",       "FIXED / SELF tracking",         "FIXED / SELF" },
      { "A",       "mute or unmute alerts",         "mute alerts" },
      { "P",       "test the alert sound",          "test the sound" },
      { "N",       "ignore the nearest contact",    "ignore nearest" },
      { "B",       "set the base to your position", "base = your pos" },
      { "C",       "clear the log",                 "clear the log" },
      { "Q",       "quit",                          "quit" },
    }
    for _, entry in ipairs(shortcuts) do
      if narrow then
        note(util.fit(entry[1], 8) .. entry[3])
      else
        note(util.fit(entry[1], 9) .. entry[2])
      end
    end
    for _, entry in ipairs(modules.keys(cfg)) do
      if entry.action and entry.action.hint then note(entry.action.hint) end
    end
    note("Right-click a monitor to move it to the next page.")
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
  app:on("modules", build)

  return {
    refresh = refreshRows,
    hidden = function() picker.visible = false end,
    -- Named so the pairing flow can be driven without a keyboard.
    pickBase = openBasePicker,
  }
end

return view
