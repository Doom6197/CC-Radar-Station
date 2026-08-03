-- SETTINGS module: an index of groups, each opening onto one screen.
--
-- Until v8.5 this was one scrolling page. It had grown to 17 sections, 85
-- controls and 99 explanatory notes -- 231 rows, or fourteen screenfuls on a
-- terminal and twenty-one on a pocket computer. Worse than the length was the
-- filing: a module's ON/OFF switch sat about a hundred rows above the settings
-- it governed, the alert range lived under SCANNING while the alerts lived
-- under ALERTS, and two sections were both called some variety of "alerts".
--
-- So the page is now two levels. The top is a short INDEX of groups, each
-- showing its own current state, which makes it a summary of the station as
-- well as a menu. Pressing one fills the page with that group and a back row.
-- Nothing was removed; everything moved to where it belongs.
--
--   STATION    who this computer is, and the network it is on
--   TRACKING   who you are, and what distances are measured from
--   SCANNING   how far, how often, and who is ignored
--   SCOPE      how the radar picture is oriented and animated
--   ALERTS     every way the station can shout: banner, sound, redstone
--   DISPLAYS   this page's own layout, the terminal, and every monitor
--   PAGES      which modules are on -- and each module's own settings
--   KEYBOARD   the shortcut list
--
-- A MODULE gets a screen of its own, reached from PAGES, holding its ON/OFF
-- switch and whatever its settings(ctx) builds. Module files did not change:
-- the ctx they are handed is the same one, called at a different moment.
--
-- Every setting is a row: a dim label on the left and a button showing the
-- current value on the right. Pressing it either toggles the value or opens a
-- full-page picker, so a two-state switch and a twenty-eight entry sound list
-- are the same code path.

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

  -- The explanatory notes under the rows. There were 99 of them, which is more
  -- notes than there are controls and roughly 37% of the page. Off by default:
  -- the ones that stop a mistake being made are marked as such and shown
  -- whatever this says, so turning them off cannot cost you a warning.
  settingsHints = false,
}

function view.sanitise(cfg)
  local known = false
  for _, entry in ipairs(view.LAYOUTS) do
    if entry.id == cfg.settingsLayout then known = true end
  end
  if not known then cfg.settingsLayout = "auto" end

  cfg.settingsHints = cfg.settingsHints == true
end

--- Whether rows stack, given the screen and the operator's preference.
function view.isNarrow(width, layout)
  if layout == "stacked" then return true end
  if layout == "columns" then return false end
  return (tonumber(width) or 51) < view.NARROW_WIDTH
end

-- ------------------------------------------------------------------ groups ---
-- Each group is one screen. `summary` is the line the index shows beside its
-- name, so the index reports the state of the station rather than being a bare
-- list of words; `build` is handed exactly the ctx a module's settings() gets.

local MODULE_PREFIX = "module:"

view.GROUPS = {

  -- ------------------------------------------------------------- station ---
  {
    id = "station",
    title = "STATION",
    summary = function(app, narrow)
      local cfg = app.cfg
      if config.isMain(cfg) then
        if narrow then return "MAIN BASE" end
        return ("MAIN BASE \"%s\""):format(util.shorten(cfg.stationName, 16))
      end
      if config.isMobile(cfg) then
        if narrow then return cfg.pairedBaseId and "MOBILE - paired" or "MOBILE" end
        return "MOBILE - " .. (config.pairedLabel(cfg) or "not paired")
      end
      return "STANDALONE"
    end,
    build = function(ctx)
      local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

      ctx.row("Version", function()
        local count = #modules.enabled(cfg)
        if ctx.isNarrow() then return "v" .. config.VERSION end
        return ("v%s   %d modules   computer %d"):format(config.VERSION, count,
          (os.getComputerID and os.getComputerID()) or 0)
      end, function()
        root:toast(("Radar Station v%s"):format(config.VERSION), "info")
      end, function() return theme.accent end)

      -- Applying a profile is destructive on purpose, so the only way in is
      -- the picker rather than a toggle that could be hit by accident.
      ctx.row("This station", function() return profiles.summary(cfg, ctx.isNarrow()) end,
        function()
          local entries = {}
          for _, entry in ipairs(profiles.LIST) do
            entries[#entries + 1] = {
              label = ctx.withHint(entry.label, entry.hint),
              value = entry.id,
            }
          end
          ctx.openPicker("APPLY A PROFILE", entries, cfg.profile, function(value)
            app:setProfile(value)
            root:toast("Applied " .. profiles.label(value), "success")
            ctx.rebuild()
          end)
        end, function() return cfg.profile and theme.accent or theme.dim end)

      -- Shown whatever the hints setting says: it is a warning, not a hint.
      ctx.note("Applying one OVERWRITES the settings it covers - tracking, the "
        .. "scope, poll rates and which modules are on. Everything stays "
        .. "editable afterwards.", true)
      ctx.spacer()

      -- network -------------------------------------------------------------
      -- Only the rows the chosen role actually uses are built, so the page
      -- does not grow a networking section for a station with no network.
      ctx.heading("NETWORK")

      ctx.row("Role", function() return config.roleLabel(cfg, ctx.isNarrow()) end,
        function()
          ctx.openPicker("STATION ROLE",
            ctx.entriesOf(config.ROLES,
              function(r) return ctx.withHint(r.label, r.hint) end,
              function(r) return r.id end),
            cfg.role,
            function(value)
              app:setRole(value)
              -- The rest of this group depends on the role, so it is rebuilt
              -- rather than left showing rows that no longer apply.
              ctx.rebuild()
            end)
        end, function() return cfg.role == "standalone" and theme.text or theme.accent end)

      if cfg.role == "standalone" then
        ctx.note("STANDALONE is the self-contained radar: it opens no modem "
          .. "and sends nothing.")
        ctx.note("A vehicle that cannot scan for itself needs a MAIN BASE on "
          .. "the ground and a MOBILE aboard.")
        ctx.spacer()
        return
      end

      ctx.row("Modem", function()
        if not app.kit.modem then return "not found" end
        return app.kit.modem.name .. (app.kit.modem.wireless and "  wireless" or "  wired")
      end, function()
        app:rescan()
        root:toast(app.kit.modem and ("Modem: " .. app.kit.modem.name)
          or "Still no modem", app.kit.modem and "success" or "warning")
      end, function() return app.kit.modem and theme.good or theme.warn end)

      ctx.note("An ender modem has no range limit and crosses dimensions.")

      if config.isMain(cfg) then
        local stationInput = ctx.input("Station name", {
          text = cfg.stationName,
          placeholder = "how mobiles see this base",
        })
        local function commitStationName(self)
          app:setStationName(self.text)
          self.text = cfg.stationName
        end
        stationInput:onEnter(commitStationName)
        stationInput:onBlur(commitStationName)

        ctx.row("Relay weather", function() return ctx.onOff(cfg.relayWeather) end,
          function() app:toggleRelayWeather() end,
          ctx.onOffColor(function() return cfg.relayWeather end))

        ctx.note("Also sends the environment, so a mobile's weather page works.")

        ctx.row("Broadcasting", function() return (app.link:summary(cfg)) end, function()
          app.link:attach(app.kit, cfg)
          app.link:announce(cfg)
          root:toast(app.link.open and "Announced on the network"
            or (app.link.error or "No modem"), app.link.open and "success" or "error")
        end, function() return app.link.open and theme.good or theme.warn end)
      end

      if config.isMobile(cfg) then
        ctx.row("Paired base", function()
          return config.pairedLabel(cfg) or "not paired - scan below"
        end, ctx.pickBase,
          function() return cfg.pairedBaseId and theme.text or theme.warn end)

        ctx.action("Scan for base stations", function()
          if not app.link.open then
            root:toast(app.link.error or "No modem attached", "error")
            return
          end
          root:toast("Listening for " .. linkLib.SCAN_SECONDS .. " seconds...", "info")
          -- Listening blocks, so it runs as a schedule and the UI stays live.
          basalt.schedule(function()
            sleep(linkLib.SCAN_SECONDS)
            ctx.pickBase()
          end)
        end)

        ctx.row("Link", function() return (app.link:summary(cfg)) end, function()
          app:checkLink()
          root:toast((app.link:summary(cfg)), app.link:status(cfg) and "warning" or "success")
        end, function()
          local _, healthy = app.link:summary(cfg)
          return healthy and theme.good or theme.warn
        end)

        ctx.note("A mobile needs no Player Detector and no GPS: the base reads "
          .. "the pilot by name, so it sees them in the air.")
      end
      ctx.spacer()
    end,
  },

  -- ------------------------------------------------------------ tracking ---
  {
    id = "tracking",
    title = "TRACKING",
    summary = function(app, narrow)
      local cfg = app.cfg
      if cfg.mode ~= "fixed" then
        if narrow then return "SELF" end
        return "SELF - " .. (cfg.myName or "no username set")
      end
      if not cfg.baseX then return "FIXED - base not set" end
      if narrow then return ("FIXED %d, %d"):format(cfg.baseX, cfg.baseZ or 0) end
      return ("FIXED   %d, %d, %d"):format(cfg.baseX, cfg.baseY or 0, cfg.baseZ or 0)
    end,
    build = function(ctx)
      local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

      local nameInput = ctx.input("Username", {
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

      ctx.note("Your own name is excluded from the radar. The scope's heading, "
        .. "SELF tracking and the whole flight page are read against it.")

      ctx.row("Mode", function()
        return cfg.mode == "fixed" and "FIXED - watch the base" or "SELF - watch you"
      end, function() app:toggleMode() end)

      -- A MOBILE decides this for itself. The main base relays raw positions
      -- and every station works out its own distances from them, so a pocket
      -- computer set to SELF measures from the pilot even though the base it
      -- is paired to is measuring from a fixed point hundreds of blocks away.
      if config.isMobile(cfg) then
        ctx.note("This station's own choice, not the base's. SELF measures "
          .. "from you, wherever the main base is.")
        if cfg.mode == "self" and not cfg.myName then
          ctx.note("SELF needs the username above, and it has to be one the "
            .. "main base can see.", true)
        end
      end

      ctx.row("Base", function()
        if not cfg.baseX then
          return ctx.isNarrow() and "not set - press to set"
            or "not set - press to use your position"
        end
        return ("%d, %d, %d"):format(cfg.baseX, cfg.baseY or 0, cfg.baseZ or 0)
      end, function()
        local ok, message = app:setBaseFromPosition()
        root:toast(message, ok and "success" or "error")
      end, function() return cfg.baseX and theme.text or theme.warn end)

      ctx.note("Press to snap the base to where you stand. The B key does the "
        .. "same thing.")

      ctx.coords("Base X Y Z", { "baseX", "baseY", "baseZ" }, function()
        app:saveConfig()
        if cfg.baseX and cfg.baseZ then
          root:toast(("Base %d, %d, %d"):format(cfg.baseX, cfg.baseY or 0,
            cfg.baseZ), "success")
        else
          root:toast("The base needs an X and a Z", "warning")
        end
      end)

      -- A MOBILE is told where its main base stands, so the coordinates above
      -- stop being something to keep in step by hand. Only worth a row on a
      -- station that is actually being fed them.
      if config.isMobile(cfg) then
        ctx.row("Follow base", function() return ctx.onOff(cfg.baseFollow) end, function()
          cfg.baseFollow = not cfg.baseFollow
          app:saveConfig()
        end, ctx.onOffColor(function() return cfg.baseFollow end))

        ctx.note("Take the base coordinates from the main base as it reports "
          .. "them, instead of keeping a copy here.")
      end
      ctx.spacer()
    end,
  },

  -- ------------------------------------------------------------ scanning ---
  {
    id = "scanning",
    title = "SCANNING",
    summary = function(app, narrow)
      local ignored = 0
      for _ in pairs(app.ignore) do ignored = ignored + 1 end
      if narrow then
        return ("%s   %ss"):format(config.rangeLabel(app.cfg),
          config.scanInterval(app.cfg))
      end
      return ("%s   every %ss%s"):format(config.rangeLabel(app.cfg),
        config.scanInterval(app.cfg),
        ignored > 0 and ("   %d ignored"):format(ignored) or "")
    end,
    build = function(ctx)
      local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

      ctx.row("Range", function() return config.rangeLabel(cfg) .. " blocks" end, function()
        ctx.openPicker("SCAN RANGE",
          ctx.entriesOf(config.RANGES, function(r) return r.label end),
          cfg.rangeIndex,
          function(value) app:setRangeIndex(value); ctx.refreshRows() end)
      end)

      ctx.row("Sweep every", function() return config.scanInterval(cfg) .. " seconds" end,
        function()
          ctx.openPicker("SCAN INTERVAL",
            ctx.entriesOf(config.SCAN_INTERVALS, function(s) return s .. " seconds" end),
            cfg.scanIndex,
            function(value)
              cfg.scanIndex = value
              app:saveConfig()
              ctx.refreshRows()
            end)
        end)

      ctx.row("Other worlds", function()
        return cfg.dimFilter and "hidden" or "shown"
      end, function()
        cfg.dimFilter = not cfg.dimFilter
        app:saveConfig()
      end)

      ctx.note("MAX asks for the largest radius the server permits. Every "
        .. "sweep is a server-thread call, so a slow one is the polite setting.")
      ctx.spacer()

      -- ignore list -----------------------------------------------------------
      ctx.heading("IGNORE LIST")

      local function ignoredNames()
        local names = {}
        for name in pairs(app.ignore) do names[#names + 1] = name end
        table.sort(names)
        return names
      end

      ctx.row("Ignored", function()
        local names = ignoredNames()
        if #names == 0 then return "nobody" end
        return ("%d: %s"):format(#names, table.concat(names, ", "))
      end, function()
        local names = ignoredNames()
        if #names == 0 then
          root:toast("The ignore list is empty", "info")
          return
        end
        ctx.openPicker("REMOVE FROM IGNORE LIST",
          ctx.entriesOf(names, function(n) return n end, function(n) return n end), nil,
          function(value)
            app:unignorePlayer(value)
            root:toast(value .. " will be tracked again", "success")
            ctx.refreshRows()
          end)
      end)

      ctx.action("Ignore an online player", function()
        local online = {}
        for _, name in ipairs(scan.onlinePlayers(app.kit)) do
          if name ~= cfg.myName and not app.ignore[name] then
            online[#online + 1] = name
          end
        end
        if #online == 0 then
          root:toast("Nobody else is online", "info")
          return
        end
        ctx.openPicker("IGNORE A PLAYER",
          ctx.entriesOf(online, function(n) return n end, function(n) return n end), nil,
          function(value)
            app:ignorePlayer(value)
            root:toast("Ignoring " .. value, "success")
            ctx.refreshRows()
          end)
      end)

      ctx.note("The N key ignores the nearest contact.")
      ctx.spacer()
    end,
  },

  -- --------------------------------------------------------------- scope ---
  {
    id = "scope",
    title = "SCOPE",
    summary = function(app, narrow)
      if narrow then
        return config.isUnlocked(app.cfg) and "unlocked" or "locked"
      end
      return config.orientationLabel(app.cfg, app.heading)
    end,
    build = function(ctx)
      local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

      ctx.row("Scope", function()
        return config.isUnlocked(cfg) and "UNLOCKED - follows you"
          or "LOCKED - fixed bearing"
      end, function()
        local unlocked = app:toggleOrientation()
        if unlocked and not app.heading then
          root:toast("Unlocked, but your heading is unreadable. Set a username.",
            "warning")
        end
      end, function() return config.isUnlocked(cfg) and theme.accent or theme.text end)

      ctx.note("Unlocking needs your username, so the radar can read your yaw. "
        .. "The L key does this too.")

      ctx.row("Bearing up", function() return config.rotationLabel(cfg) end, function()
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
        ctx.openPicker("BEARING AT THE TOP", entries, cfg.rotation, function(value)
          cfg.rotation = value
          app:saveConfig()
          ctx.refreshRows()
        end)
      end, function() return config.isUnlocked(cfg) and theme.line or theme.text end)

      ctx.note("Used while locked. Turns the picture only; bearings stay true.")

      ctx.row("Heading steps", function() return config.headingStepLabel(cfg) end, function()
        ctx.openPicker("HEADING STEPS",
          ctx.entriesOf(config.HEADING_STEPS,
            function(s) return s.label end, function(s) return s.value end),
          cfg.headingStep,
          function(value)
            cfg.headingStep = value
            app:readHeading()
            app:saveConfig()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Heading rate", function() return cfg.headingSeconds .. " seconds" end,
        function()
          ctx.openPicker("HEADING POLL RATE",
            ctx.entriesOf(config.HEADING_INTERVALS,
              function(v) return v .. " seconds" end, function(v) return v end),
            cfg.headingSeconds,
            function(value)
              cfg.headingSeconds = value
              app:saveConfig()
              ctx.refreshRows()
            end)
        end)

      ctx.row("Ease turns", function() return ctx.onOff(cfg.headingSmooth) end, function()
        cfg.headingSmooth = not cfg.headingSmooth
        app:readHeading()
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.headingSmooth end))

      ctx.note("Slide into a turn instead of jumping to it. Needs animation on.")

      -- Animation belongs to the scope more than to anything else -- it drives
      -- the sweep and the eased turn above -- but it also drives the sky, so it
      -- has to be reachable on a station with the weather module switched off.
      -- That is why it is here rather than with the weather settings.
      ctx.row("Animation", function() return ctx.onOff(cfg.animate) end, function()
        cfg.animate = not cfg.animate
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.animate end))

      ctx.note("Drives the radar sweep, eased turns, and the sky. Off is the "
        .. "quiet setting for a pocket computer.")

      ctx.row("Now facing", function()
        return config.orientationLabel(cfg, app.heading)
      end, function()
        app:readHeading()
        root:toast(app.heading and ("Heading " .. math.floor(app.heading) .. " deg")
          or "No heading - set your username", app.heading and "info" or "warning")
      end, function() return app.heading and theme.good or theme.dim end)
      ctx.spacer()
    end,
  },

  -- -------------------------------------------------------------- alerts ---
  {
    id = "alerts",
    title = "ALERTS",
    summary = function(app, narrow)
      local cfg = app.cfg
      if not cfg.alert then return "MUTED" end
      local channels = {}
      if cfg.sound.enabled and #app.kit.speakers > 0 then channels[#channels + 1] = "sound" end
      if cfg.flash then channels[#channels + 1] = "flash" end
      if cfg.toast then channels[#channels + 1] = "banner" end
      if cfg.rs.enabled then channels[#channels + 1] = "redstone" end
      if #channels == 0 then return "ON - no channels" end
      if narrow then
        return ("ON   %d channel%s"):format(#channels, #channels == 1 and "" or "s")
      end
      return "ON   " .. table.concat(channels, ", ")
    end,
    build = function(ctx)
      local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

      ctx.row("Master", function() return ctx.onOff(cfg.alert) end, function()
        app:toggleAlerts()
      end, ctx.onOffColor(function() return cfg.alert end))

      ctx.note("The A key mutes and unmutes. A muted station still writes "
        .. "everything down; it just does not shout.")

      -- Moved here from SCANNING in v8.5. It is an alert setting: it decides
      -- what is close enough to be worth shouting about, not what is scanned.
      ctx.row("Alert within", function()
        return config.alertRangeLabel(cfg) .. " blocks"
      end, function()
        ctx.openPicker("ALERT RANGE",
          ctx.entriesOf(config.RANGES, function(r) return r.label end),
          cfg.alertRangeIndex,
          function(value)
            cfg.alertRangeIndex = value
            app:saveConfig()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Screen flash", function() return ctx.onOff(cfg.flash) end, function()
        cfg.flash = not cfg.flash
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.flash end))

      ctx.row("Banner", function() return ctx.onOff(cfg.toast) end, function()
        cfg.toast = not cfg.toast
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.toast end))

      ctx.row("Unread chime", function() return ctx.onOff(cfg.chime) end, function()
        cfg.chime = not cfg.chime
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.chime end))

      ctx.note("One note when something goes in the alert log without setting "
        .. "the alarm off - an arrival outside the alert range, mostly.")
      ctx.spacer()

      -- sound -----------------------------------------------------------------
      ctx.heading("SOUND")

      ctx.row("Sound", function()
        if #app.kit.speakers == 0 then return "no speaker attached" end
        return ctx.onOff(cfg.sound.enabled)
      end, function()
        cfg.sound.enabled = not cfg.sound.enabled
        app:saveConfig()
      end, function()
        return (#app.kit.speakers > 0 and cfg.sound.enabled) and theme.good or theme.dim
      end)

      ctx.row("Alert sound", function() return config.sound(cfg).label end, function()
        ctx.openPicker("ALERT SOUND",
          ctx.entriesOf(config.SOUNDS, function(s) return s.label end),
          cfg.sound.index,
          function(value)
            cfg.sound.index = value
            app:saveConfig()
            app.alerts:play()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Volume", function() return ("%.2f"):format(cfg.sound.volume) end, function()
        ctx.openPicker("VOLUME",
          ctx.entriesOf({ 0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0 },
            function(v) return ("%.2f"):format(v) end, function(v) return v end),
          cfg.sound.volume,
          function(value)
            cfg.sound.volume = value
            app:saveConfig()
            app.alerts:play()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Pitch", function() return ("%.2f"):format(cfg.sound.pitch) end, function()
        ctx.openPicker("PITCH",
          ctx.entriesOf({ 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0 },
            function(v) return ("%.2f"):format(v) end, function(v) return v end),
          cfg.sound.pitch,
          function(value)
            cfg.sound.pitch = value
            app:saveConfig()
            app.alerts:play()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Repeats", function() return tostring(cfg.sound.repeats) end, function()
        ctx.openPicker("REPEAT COUNT",
          ctx.entriesOf({ 1, 2, 3, 4, 5 }, tostring, function(v) return v end),
          cfg.sound.repeats,
          function(value)
            cfg.sound.repeats = value
            app:saveConfig()
            ctx.refreshRows()
          end)
      end)

      ctx.action("Test the alert sound", function()
        if #app.kit.speakers == 0 then
          root:toast("No speaker on the network", "error")
        else
          app.alerts:play()
        end
      end)
      ctx.spacer()

      -- redstone --------------------------------------------------------------
      ctx.heading("REDSTONE OUTPUT")

      ctx.row("Output", function() return ctx.onOff(cfg.rs.enabled) end, function()
        cfg.rs.enabled = not cfg.rs.enabled
        app.alerts:invalidate()
        app.alerts:updateRedstone()
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.rs.enabled end))

      ctx.row("Side", function() return cfg.rs.side end, function()
        ctx.openPicker("OUTPUT SIDE",
          ctx.entriesOf(alertsLib.sides(), function(s) return s end, function(s) return s end),
          cfg.rs.side,
          function(value)
            -- Drop the old side before moving, or it stays latched on.
            pcall(redstone.setAnalogOutput, cfg.rs.side, 0)
            cfg.rs.side = value
            app.alerts:invalidate()
            app.alerts:updateRedstone()
            app:saveConfig()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Mode", function()
        local mode = config.redstoneMode(cfg)
        return ctx.withHint(mode.label, mode.hint)
      end, function()
        ctx.openPicker("OUTPUT MODE",
          ctx.entriesOf(config.RS_MODES,
            function(m) return ctx.withHint(m.label, m.hint) end,
            function(m) return m.id end),
          cfg.rs.mode,
          function(value)
            cfg.rs.mode = value
            app.alerts:invalidate()
            app.alerts:updateRedstone()
            app:saveConfig()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Pulse length", function() return cfg.rs.pulse .. " seconds" end, function()
        ctx.openPicker("PULSE LENGTH",
          ctx.entriesOf(config.RS_PULSE_OPTIONS,
            function(v) return v .. " seconds" end, function(v) return v end),
          cfg.rs.pulse,
          function(value)
            cfg.rs.pulse = value
            app:saveConfig()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Trigger range", function()
        return config.RANGES[cfg.rs.rangeIndex].label .. " blocks"
      end, function()
        ctx.openPicker("TRIGGER RANGE",
          ctx.entriesOf(config.RANGES, function(r) return r.label end),
          cfg.rs.rangeIndex,
          function(value)
            cfg.rs.rangeIndex = value
            app:saveConfig()
            ctx.refreshRows()
          end)
      end)

      ctx.row("Inverted", function() return ctx.onOff(cfg.rs.invert) end, function()
        cfg.rs.invert = not cfg.rs.invert
        app.alerts:invalidate()
        app.alerts:updateRedstone()
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.rs.invert end))

      ctx.note("Pulse, Hold and Analog read the contact list. A mode added by "
        .. "a module reads whatever that module measures.")

      ctx.action("Test pulse", function()
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
      ctx.spacer()
    end,
  },

  -- ------------------------------------------------------------ displays ---
  {
    id = "displays",
    title = "DISPLAYS",
    summary = function(app, narrow)
      local count = #app.kit.monitors
      if narrow then
        return ("%s   %d mon"):format(app.cfg.terminalPage, count)
      end
      return ("terminal: %s   %d monitor%s"):format(app.cfg.terminalPage,
        count, count == 1 and "" or "s")
    end,
    build = function(ctx)
      local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

      -- this page ------------------------------------------------------------
      ctx.heading("THIS PAGE")

      ctx.row("Layout", function()
        for _, entry in ipairs(view.LAYOUTS) do
          if entry.id == cfg.settingsLayout then
            if cfg.settingsLayout == "auto" then
              return ("auto - %s"):format(ctx.isNarrow() and "stacked" or "side by side")
            end
            return entry.label
          end
        end
        return cfg.settingsLayout
      end, function()
        ctx.openPicker("SETTINGS LAYOUT",
          ctx.entriesOf(view.LAYOUTS,
            function(e) return ctx.withHint(e.label, e.hint) end,
            function(e) return e.id end),
          cfg.settingsLayout,
          function(value)
            cfg.settingsLayout = value
            app:saveConfig()
            ctx.rebuild()
          end)
      end)

      ctx.note("Stacked puts each value on its own line, which is what a "
        .. "26-cell pocket screen needs.")

      ctx.row("Hints", function() return ctx.onOff(cfg.settingsHints) end, function()
        cfg.settingsHints = not cfg.settingsHints
        app:saveConfig()
        ctx.rebuild()
      end, ctx.onOffColor(function() return cfg.settingsHints end))

      -- Shown either way, or turning them off would hide the row that turns
      -- them back on from anyone who had forgotten where it was.
      ctx.note("The explanatory lines under each setting. Warnings are shown "
        .. "whatever this says.", true)
      ctx.spacer()

      -- screens ---------------------------------------------------------------
      ctx.heading("SCREENS")

      local pages = config.pages(cfg)
      local terminalPages = config.terminalPages(cfg)

      ctx.row("Terminal", function() return cfg.terminalPage end, function()
        ctx.openPicker("TERMINAL PAGE",
          ctx.entriesOf(terminalPages, function(p) return p end, function(p) return p end),
          cfg.terminalPage,
          function(value) root:setPage(value) end)
      end)

      ctx.row("Tap to change", function() return ctx.onOff(cfg.tapCycle) end, function()
        cfg.tapCycle = not cfg.tapCycle
        app:saveConfig()
      end, ctx.onOffColor(function() return cfg.tapCycle end))

      ctx.note("Right-click a monitor in game to move it to the next page. A "
        .. "page that wants the tap for itself gets it first.")

      if #app.kit.monitors == 0 then
        ctx.note("No monitors attached.", true)
      end
      for _, monitor in ipairs(app.kit.monitors) do
        local displayCfg = app:displayConfig(monitor.name)

        ctx.row(util.shorten(monitor.name, LABEL_WIDTH - 1), function()
          return ("%s   scale %.1f"):format(displayCfg.page, displayCfg.scale)
        end, function()
          ctx.openPicker("PAGE FOR " .. monitor.name,
            ctx.entriesOf(pages, function(p) return p end, function(p) return p end),
            displayCfg.page,
            function(value)
              displayCfg.page = value
              app:saveConfig()
              root:toast("Restart to apply monitor changes", "info")
              ctx.refreshRows()
            end)
        end)

        ctx.row("  text scale", function() return ("%.1f"):format(displayCfg.scale) end,
          function()
            ctx.openPicker("TEXT SCALE FOR " .. monitor.name,
              ctx.entriesOf({ 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0 },
                function(v) return ("%.1f"):format(v) end, function(v) return v end),
              displayCfg.scale,
              function(value)
                displayCfg.scale = value
                app:saveConfig()
                pcall(monitor.dev.setTextScale, value)
                ctx.refreshRows()
              end)
          end)

        ctx.row("  auto cycle", function()
          if not displayCfg.cycle then return "off" end
          return ("every %ds   %d pages"):format(
            displayCfg.cycleSeconds, #config.cyclePages(cfg, displayCfg))
        end, function()
          displayCfg.cycle = not displayCfg.cycle
          app:saveConfig()
        end, function() return displayCfg.cycle and theme.good or theme.dim end)

        ctx.row("  cycle every", function() return displayCfg.cycleSeconds .. " seconds" end,
          function()
            ctx.openPicker("CYCLE INTERVAL FOR " .. monitor.name,
              ctx.entriesOf(config.CYCLE_INTERVALS,
                function(v) return v .. " seconds" end, function(v) return v end),
              displayCfg.cycleSeconds,
              function(value)
                displayCfg.cycleSeconds = value
                app:saveConfig()
                ctx.refreshRows()
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
          ctx.openPicker("PAGES IN ROTATION: " .. monitor.name, entries, nil, function(page)
            if not page then ctx.refreshRows(); return end
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
            ctx.refreshRows()
            editRotation()
          end)
        end

        ctx.row("  cycle pages", function()
          local inRotation = config.cyclePages(cfg, displayCfg)
          if #inRotation == #pages then return "all pages" end
          return table.concat(inRotation, " ")
        end, editRotation)
      end

      ctx.action("Rescan peripherals", function()
        app:rescan()
        root:toast(("%d monitor(s), %d speaker(s)"):format(
          #app.kit.monitors, #app.kit.speakers), "info")
      end)

      ctx.note("Monitors added or removed need a restart to get their own page.")
      ctx.spacer()
    end,
  },

  -- --------------------------------------------------------------- pages ---
  -- The spine of the module system. Every module is one row, and pressing it
  -- opens that module's own screen -- where its ON/OFF switch and its settings
  -- are finally in the same place instead of a hundred rows apart.
  {
    id = "pages",
    title = "PAGES",
    summary = function(app)
      local all = modules.all()
      local on = #modules.enabled(app.cfg)
      return ("%d of %d on"):format(on, #all)
    end,
    build = function(ctx)
      local cfg = ctx.app.cfg

      for _, entry in ipairs(modules.all()) do
        local id = entry.id
        ctx.row(util.shorten(entry.title, LABEL_WIDTH - 1), function()
          if entry.core then return "always on" end
          return modules.isEnabled(cfg, id) and "ON" or "off"
        end, function()
          ctx.openGroup(MODULE_PREFIX .. id)
        end, function()
          if entry.core then return theme.dim end
          return modules.isEnabled(cfg, id) and theme.good or theme.dim
        end)
      end

      for _, failure in ipairs(modules.failures or {}) do
        ctx.note("! " .. util.shorten(failure.id .. ": " .. failure.error, 160), true)
      end

      ctx.note("Press one to switch it on or off and reach its settings. A "
        .. "module is one file in radar/modules/: drop one in and it is a "
        .. "page here after a restart.")
      ctx.spacer()
    end,
  },

  -- ------------------------------------------------------------ keyboard ---
  {
    id = "keyboard",
    title = "KEYBOARD",
    summary = function(_, narrow)
      return narrow and "shortcuts" or "shortcuts and monitor taps"
    end,
    build = function(ctx)
      -- Two descriptions per key. This is the one list on the page that must
      -- not be wrapped -- the run of spaces is what lines the descriptions up
      -- into a column, and note() rejoins wrapped text on single spaces -- so
      -- instead of wrapping, a narrow screen gets a shorter description that
      -- still fits. Always shown: this is the content of the group, not a hint.
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
        { "C",       "clear the alert log",           "clear the alerts" },
        { "Q",       "quit",                          "quit" },
      }
      for _, entry in ipairs(shortcuts) do
        if ctx.isNarrow() then
          ctx.note(util.fit(entry[1], 8) .. entry[3], true)
        else
          ctx.note(util.fit(entry[1], 9) .. entry[2], true)
        end
      end
      for _, entry in ipairs(modules.keys(ctx.app.cfg)) do
        if entry.action and entry.action.hint then ctx.note(entry.action.hint, true) end
      end
      ctx.spacer()

      ctx.heading("MONITOR TAPS")
      ctx.note("Right-click a monitor to move it to the next page.", true)
      ctx.note("A name on CONTACTS becomes the flight destination.", true)
      ctx.note("The destination on FLIGHT swaps HOME and the waypoint.", true)
      ctx.note("MARK on FLIGHT drops the waypoint where you are.", true)
      ctx.spacer()
    end,
  },
}

function view.groupById(id)
  for _, group in ipairs(view.GROUPS) do
    if group.id == id then return group end
  end
  return nil
end

--- The screen a module gets, reached from PAGES: its own switch, then whatever
--- its settings(ctx) builds. Made on demand rather than kept in GROUPS, since
--- which modules exist is decided at load time and can change at runtime.
function view.moduleGroup(entry)
  return {
    id = MODULE_PREFIX .. entry.id,
    title = entry.title,
    module = entry,
    build = function(ctx)
      local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

      ctx.row("Module", function()
        if entry.core then return "always on" end
        return modules.isEnabled(cfg, entry.id) and "ON" or "off"
      end, function()
        if entry.core then
          root:toast(entry.title .. " cannot be switched off", "info")
          return
        end
        app:toggleModule(entry.id)
        root:toast(entry.title .. (modules.isEnabled(cfg, entry.id) and " on" or " off"),
          "info")
        -- Its settings come and go with it, so the screen is rebuilt.
        ctx.rebuild()
      end, function()
        if entry.core then return theme.dim end
        return modules.isEnabled(cfg, entry.id) and theme.good or theme.dim
      end)

      -- Always shown: on a screen with one switch on it, the line saying what
      -- the switch is for is the content rather than a hint.
      if entry.summary then ctx.note(entry.summary, true) end
      ctx.spacer()

      if type(entry.settings) ~= "function" then return end
      if not modules.isEnabled(cfg, entry.id) then
        ctx.note("Switch it on to reach its settings.", true)
        return
      end

      -- A module that throws while building loses its section rather than the
      -- whole page.
      local ok, err = pcall(entry.settings, ctx)
      if not ok then
        ctx.heading(entry.title)
        ctx.note("This module's settings failed to build:", true)
        ctx.note(util.shorten(tostring(err), 46), true)
        ctx.spacer()
      end
    end,
  }
end

--- Resolves a group id, module screens included.
function view.resolveGroup(id)
  if type(id) ~= "string" then return nil end
  local moduleId = id:match("^" .. MODULE_PREFIX .. "(.+)$")
  if moduleId then
    local entry = modules.byId(moduleId)
    return entry and view.moduleGroup(entry) or nil
  end
  return view.groupById(id)
end

view.MODULE_PREFIX = MODULE_PREFIX

-- ------------------------------------------------------------------- page ---

function view.build(container, app, root)
  -- How wide the screen this page is being built for actually is. Set at the
  -- top of every build(), and read by row(), note() and the picker. A terminal
  -- cannot be resized while it is running, so deciding once per build is
  -- enough -- and build() re-runs whenever the group, the module set or the
  -- layout setting changes.
  local narrow = false
  local screenWidth = 51

  -- nil is the index; anything else is a group id.
  local openGroupId = nil

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
      -- Clipped to its column. A label longer than LABEL_WIDTH used to run
      -- under the button beside it -- "Relay to mobiles" came out as
      -- "Relay to mobil[ON".
      body:addLabel({
        x = 1, y = nextY, foreground = theme.dim,
        text = util.shorten(label, LABEL_WIDTH - 1),
      })
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

  --- Three coordinate boxes on one line, under their own label.
  ---
  --- Stacked, the label gets its own row and the boxes start hard left; side
  --- by side they sit in the value column. The old fixed offsets needed 41
  --- cells and ran off a pocket screen entirely.
  ---@param keys string[] Three config keys, x then y then z
  ---@param onCommit function called after any box is entered
  local function coords(label, keys, onCommit)
    body:addLabel({ x = 1, y = nextY, text = label, foreground = theme.dim })
    if narrow then nextY = nextY + 1 end

    local x = narrow and 1 or (LABEL_WIDTH + 1)
    local boxWidth = narrow and 7 or 8
    local gap = boxWidth + 1
    local boxes = {}

    --- Commits ALL THREE boxes, whichever one was left.
    ---
    --- Each box used to commit only itself, and only on Enter. Type into all
    --- three, press Enter once, and the other two kept their typing on screen
    --- while the settings kept their old values -- so a waypoint typed in full
    --- read back as "not set" under a toast saying it had been set. Reading
    --- every box on every commit is what makes what is on screen and what is
    --- stored the same thing.
    ---
    --- An empty box means nil, so a coordinate can be cleared as well as set.
    local function commit()
      local changed = false
      for index, key in ipairs(keys) do
        local value = tonumber(boxes[index] and boxes[index].text)
        local now = value and math.floor(value) or nil
        if app.cfg[key] ~= now then
          app.cfg[key] = now
          changed = true
        end
      end
      -- Only when something actually moved, or leaving a box you never typed
      -- in would announce a change that did not happen.
      if changed and onCommit then onCommit() end
      refreshRows()
    end

    for index, key in ipairs(keys) do
      boxes[index] = body:addInput({
        x = x + (index - 1) * gap, y = nextY,
        width = boxWidth, height = 1,
        text = tostring(app.cfg[key] or ""),
        placeholder = ({ "x", "y", "z" })[index],
        pattern = "[%d%-]",          -- Input tests each typed character

        background = theme.panel, foreground = theme.text,
        placeholderColor = theme.line,
      })
      -- On blur as well as Enter, so tabbing or clicking off a box counts.
      boxes[index]:onEnter(commit)
      boxes[index]:onBlur(commit)
    end
    nextY = nextY + 1
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

  --- Explanatory small print.
  ---
  --- Suppressed by the Hints setting UNLESS `always` is set, which is how a
  --- warning stays on the page for someone who has turned the hints off. There
  --- were 99 of these and 85 controls; hiding the ones that are merely helpful
  --- is most of what makes a group fit on a screen.
  ---
  --- Wrapped rather than clipped: a note cut off at twenty-five cells is worse
  --- than no note at all, because it reads as a sentence that means something
  --- other than what it says. A line that already fits is emitted untouched --
  --- util.wrap rejoins on single spaces, which would collapse the run of
  --- spaces the keyboard list uses to line its descriptions up into a column.
  local function note(text, always)
    if not always and not app.cfg.settingsHints then return end
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
  ---
  --- With no `valueOf` the value is the INDEX, which is what the settings that
  --- store an index into a list want. With one, its answer is used as it
  --- stands -- including `false`, which is a real value here: "no limit" on
  --- the autopilot's shut-off range is stored as false, and the old
  --- `valueOf(item, i) or i` turned it into the index instead, so picking
  --- "No limit" set the range to 6 blocks.
  local function entriesOf(list, labelOf, valueOf)
    local out = {}
    for i, item in ipairs(list) do
      local value = i
      if valueOf then value = valueOf(item, i) end
      out[i] = { label = labelOf(item, i), value = value }
    end
    return out
  end

  --- Opens a group, or the index when handed nil.
  local function openGroup(id)
    openGroupId = id
    -- A group taller than the screen would otherwise open part-scrolled, at
    -- whatever offset the previous one was left at.
    pcall(function() body.offsetY = 0 end)
    build()
  end

  --- What a module's settings() is handed: everything it needs to build a
  --- section that matches the rest of the page, and nothing else. A module
  --- cannot reach the row list or the layout cursor, so it cannot leave the
  --- page half built.
  local ctx = {
    app = app, root = root,
    heading = heading, row = row, action = action, note = note, spacer = spacer,
    input = input, coords = coords, withHint = withHint,
    openPicker = openPicker,
    refreshRows = function() refreshRows() end,
    entriesOf = entriesOf, onOff = onOff, onOffColor = onOffColor,
    body = body, LABEL_WIDTH = LABEL_WIDTH,
    rebuild = function() build() end,
    -- Read by a module that wants to lay something out itself. Both are
    -- refreshed before any module's settings() is called.
    isNarrow = function() return narrow end,
    screenWidth = function() return screenWidth end,
    -- Navigation, so a group can send you to another one.
    openGroup = openGroup,
    pickBase = openBasePicker,
  }

  -- ---------------------------------------------------------------- index ---

  local function buildIndex()
    heading(("SETTINGS   v%s"):format(config.VERSION))

    for _, group in ipairs(view.GROUPS) do
      local id = group.id
      row(group.title, function()
        local ok, text = pcall(group.summary, app, narrow)
        return (ok and type(text) == "string") and text or ""
      end, function() openGroup(id) end)
    end

    note("Press a group to open it. Everything is in one of these; nothing "
      .. "was removed when the page was split up.")
    spacer()

    action("Quit Radar Station", function()
      app:stop()
      basalt.stop()
    end, theme.alarm)
  end

  local function buildGroup(group)
    action("<  " .. group.title, function() openGroup(nil) end)
    spacer()
    local ok, err = pcall(group.build, ctx)
    if not ok then
      heading(group.title)
      note("This group failed to build:", true)
      note(util.shorten(tostring(err), 46), true)
      spacer()
    end
  end

  -- ---------------------------------------------------------------- build ---
  build = function()
    measure()
    rows, nextY = {}, 1
    local children = body:getChildren()
    for i = #children, 1, -1 do children[i]:destroy() end

    local group = openGroupId and view.resolveGroup(openGroupId) or nil
    -- A group whose module has just been switched off, or removed entirely,
    -- drops the operator back at the index rather than onto a blank screen.
    if openGroupId and not group then openGroupId = nil end

    if group then buildGroup(group) else buildIndex() end

    body:markDirty()
    refreshRows()
  end

  build()
  app:on("hardware", build)
  app:on("modules", build)

  return {
    refresh = refreshRows,
    hidden = function()
      picker.visible = false
      -- Coming back to settings starts at the index. The index is the map, and
      -- being dropped back into whichever group you left is disorienting.
      if openGroupId then openGroup(nil) end
    end,
    -- Named so the pairing flow, and the tests, can drive the page without a
    -- keyboard.
    pickBase = openBasePicker,
    openGroup = openGroup,
    currentGroup = function() return openGroupId end,
  }
end

return view
