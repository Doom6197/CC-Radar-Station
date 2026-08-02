-- STATUS module: the dashboard. Station configuration, hardware, environment
-- and traffic on one screen. The default terminal page.
--
-- Core, so it cannot be switched off: it is the page that tells you why
-- anything else is not working, which makes it a poor candidate for being
-- turned off by accident.

local config  = require("radar.config")
local logbook = require("radar.logbook")
local sky     = require("radar.sky")
local theme   = require("radar.theme")
local ui      = require("radar.ui")
local util    = require("radar.util")

local view = {
  id = "status",
  title = "STATUS",
  short = "SYS",
  order = 10,
  core = true,
  summary = "everything at a glance; always available",
}

local max, floor = math.max, math.floor

-- ------------------------------------------------------------------ vitals ---
-- What the dashboard comes down to on a screen with nine rows: is the station
-- working, and is anything wrong. Everything on the full page that is really
-- a SETTING -- the range, the tracking mode, which bearing is up -- is left
-- out, because none of it changes on its own and none of it is a surprise.

--- @return table[] { { label, value, colour } , ... }
local function vitals(app)
  local cfg = app.cfg
  local out = {}
  local function push(label, value, colour)
    out[#out + 1] = { label = label, value = value, colour = colour or theme.text }
  end

  -- Whatever is broken goes first, because that is the reason to look.
  if app.scanError then
    push("FAULT", util.shorten(app.scanError, 10), theme.alarm)
  end

  if config.usesNetwork(cfg) then
    local summary, healthy = app.link:summary(cfg)
    -- The full sentence never fits; what matters is whether it is up.
    local text = healthy and (config.isMobile(cfg)
      and util.shorten(config.pairedLabel(cfg) or "ok", 9) or "ok") or "DOWN"
    push("LINK", text, healthy and theme.good or theme.alarm)
  end

  local count = #app.contacts
  push("CONTACT", tostring(count), count > 0 and theme.warn or theme.dim)

  -- Only when there is something waiting. A row reading "UNREAD 0" would be
  -- one of nine spending itself on the absence of news.
  local unread = app.log:unread()
  if unread > 0 then push("UNREAD", tostring(unread), theme.accent) end

  -- Speed only where the flight page is on. On a fixed base it would report
  -- the operator walking around, which is noise dressed as an instrument.
  local flying = require("radar.modules").isEnabled(cfg, "flight")
  if flying and app.flight and app.flight.position then
    local model = app.flight
    push("SPD", require("radar.flight").formatSpeed(model.speed),
      model.moving and theme.good or theme.dim)
    push("ALT", tostring(floor(model.position.y)), theme.text)
  elseif app.myPos then
    push("ALT", tostring(floor(app.myPos.y)), theme.text)
  end

  if app.power and app.power.available and app.power.percent then
    push("PWR", ("%d%%"):format(util.round(app.power.percent)),
      app.power.low and theme.alarm or theme.good)
  end

  local snap = app:snapshot()
  if snap and snap.available then
    push("TIME", snap.clock, theme.text)
  end

  push("ALERTS", cfg.alert and "on" or "MUTE",
    cfg.alert and theme.good or theme.warn)

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

    -- A 1x1 monitor gets the vitals and nothing else. The full dashboard at
    -- this size left five characters for every value, which turned "AIRSHIP /
    -- VEHICLE" into "AIRS" and "tracking you" into "trac".
    if ui.isTiny(w) then
      local rows = vitals(app)
      for index, row in ipairs(rows) do
        if index > h then break end
        buf:blit(1, index, util.shorten(row.label, 7), theme.dim, theme.bg)
        local value = util.shorten(row.value, max(1, w - 8))
        buf:blit(max(1, w - #value), index, value, row.colour, theme.bg)
      end
      return
    end

    local twoColumn = w >= 50
    local colW = twoColumn and floor((w - 3) / 2) or (w - 2)
    local leftX = 2
    local rightX = twoColumn and (leftX + colW + 1) or leftX

    -- A cursor per column, so sections stack without hand-counting rows.
    local ly, ry = 1, 1

    local function heading(x, y, text)
      if y > h then return y end
      buf:blit(x, y, text, theme.accent, theme.bg)
      if y + 1 <= h then buf:fill(x, y + 1, colW, 1, "-", theme.line, theme.bg) end
      return y + 2
    end

    local function row(x, y, label, value, color)
      if y > h then return y end
      buf:blit(x, y, util.fit(label, 8), theme.dim, theme.bg)
      buf:blit(x + 9, y, util.shorten(value, max(1, colW - 9)), color or theme.text, theme.bg)
      return y + 1
    end

    -- ------------------------------------------------------------ station ---
    ly = heading(leftX, ly, "STATION")

    ly = row(leftX, ly, "Profile", config.profileLabel(app.cfg),
      app.cfg.profile and theme.text or theme.dim)

    if app.cfg.mode == "fixed" and app.cfg.baseX then
      ly = row(leftX, ly, "Base", ("%d, %d, %d"):format(
        app.cfg.baseX, app.cfg.baseY or 0, app.cfg.baseZ or 0), theme.good)
    else
      ly = row(leftX, ly, "Base", app.cfg.mode == "fixed"
        and "not set - press B" or "tracking you", theme.warn)
    end

    if app.myPos then
      local you = ("%d, %d, %d"):format(
        floor(app.myPos.x), floor(app.myPos.y), floor(app.myPos.z))
      if app.cfg.mode == "fixed" and app.cfg.baseX then
        local dx = app.myPos.x - app.cfg.baseX
        local dz = app.myPos.z - app.cfg.baseZ
        you = you .. ("  (%s)"):format(util.distanceLabel(math.sqrt(dx * dx + dz * dz)))
      end
      ly = row(leftX, ly, "You", you)
    else
      ly = row(leftX, ly, "You", app.cfg.myName
        and "offline or out of range" or "no username set", theme.dim)
    end

    ly = row(leftX, ly, "Range", config.rangeLabel(app.cfg) ..
      "   every " .. config.scanInterval(app.cfg) .. "s")
    ly = row(leftX, ly, "Scope", config.orientationLabel(app.cfg, app.heading),
      config.isUnlocked(app.cfg)
        and (app.heading and theme.accent or theme.warn)
        or theme.text)
    ly = row(leftX, ly, "Alerts", (app.cfg.alert and "on" or "MUTED") ..
      "  within " .. config.alertRangeLabel(app.cfg),
      app.cfg.alert and theme.good or theme.warn)
    ly = row(leftX, ly, "Sound", #app.kit.speakers == 0 and "no speaker"
      or ((app.cfg.sound.enabled and "on  " or "off ") .. config.sound(app.cfg).label),
      (#app.kit.speakers > 0 and app.cfg.sound.enabled) and theme.good or theme.dim)
    ly = row(leftX, ly, "Redstone", app.cfg.rs.enabled
      and ("%s  %s  level %d"):format(app.cfg.rs.side, app.cfg.rs.mode, app.alerts:level())
      or "disabled",
      app.cfg.rs.enabled and theme.good or theme.dim)
    ly = row(leftX, ly, "Hardware", ("%d mon  %d spk  %s"):format(
      #app.kit.monitors, #app.kit.speakers,
      app.kit.env and "env ok" or "no env"),
      app.kit.env and theme.text or theme.warn)

    -- A stand-alone station has no link to report, and saying so every time
    -- would only take a row away from everything that does matter.
    if config.usesNetwork(app.cfg) then
      local summary, healthy = app.link:summary(app.cfg)
      ly = row(leftX, ly, "Link", summary, healthy and theme.good or theme.warn)
    end

    -- The power module hangs its state here when it is enabled. Reading it
    -- through a plain nil check rather than requiring the module keeps this
    -- page working on an install where power has been switched off, or where
    -- the file was never downloaded at all.
    if app.power and app.power.available then
      local net = app.power.formatSigned(app.power.net) .. "/t"
      ly = row(leftX, ly, "Power",
        app.power.percent
          and ("%d%%   %s"):format(util.round(app.power.percent), net)
          or net,
        app.power.low and theme.alarm
        or (app.power.net < 0 and theme.warn or theme.good))
    end

    if app.scanError then
      ly = row(leftX, ly, "Fault", app.scanError, theme.alarm)
    end

    -- -------------------------------------------------------- environment ---
    if not twoColumn then ry = ly + 1 end
    local snap = app:snapshot()
    ry = heading(rightX, ry, "ENVIRONMENT")
    if snap and snap.available then
      local scene = snap.scene or {}
      ry = row(rightX, ry, "Time", ("%s   Day %d"):format(snap.clock, snap.day or 0))
      ry = row(rightX, ry, "Sky", scene.title or "-",
        scene.weather == "storm" and theme.alarm
        or (scene.weather ~= "clear" and theme.warn or theme.accent))
      if snap.kind == "overworld" then
        ry = row(rightX, ry, "Moon", snap.moonName or "-")
      end
      ry = row(rightX, ry, "Biome", snap.biomeName or "-")
      ry = row(rightX, ry, "Ground", (scene.groundLabel or "-")
        .. (scene.groundForced and "  (forced)" or ""),
        scene.groundForced and theme.warn or theme.dim)
      ry = row(rightX, ry, "Light", ("sky %s   block %s"):format(
        snap.skyLight or "?", snap.blockLight or "?"))
    else
      ry = row(rightX, ry, "Detector", "not attached", theme.warn)
      ry = row(rightX, ry, "", "add an Environment Detector", theme.dim)
    end

    -- ----------------------------------------------------------- contacts ---
    ry = ry + 1
    ry = heading(rightX, ry, ("CONTACTS (%d)"):format(#app.contacts))
    if #app.contacts == 0 then
      ry = row(rightX, ry, "", "all clear", theme.dim)
    else
      for i, contact in ipairs(app.contacts) do
        if i > 4 or ry > h then break end
        if ry <= h then
          buf:blit(rightX, ry, util.shorten(contact.name, 12), theme.text, theme.bg)
          buf:blit(rightX + 13, ry, util.fit(util.distanceLabel(contact.dist), 6, true),
            contact.zoneColor, theme.bg)
          buf:blit(rightX + 20, ry, contact.dir, theme.accent, theme.bg)
          ry = ry + 1
        end
      end
      if #app.contacts > 4 then
        ry = row(rightX, ry, "", ("+%d more"):format(#app.contacts - 4), theme.dim)
      end
    end

    -- --------------------------------------------------------- recent log ---
    -- The log fills whatever is left: under the station column when there are
    -- two columns, under everything else when there is one.
    local logX = leftX
    local logY = twoColumn and (ly + 1) or (ry + 1)
    if logY <= h - 1 then
      local unread = app.log:unread()
      logY = heading(logX, logY, unread > 0
        and ("RECENT (%d)   %d new"):format(app.log:count(), unread)
        or ("RECENT (%d)"):format(app.log:count()))
      if app.log:count() == 0 then
        buf:blit(logX, logY, "(empty)", theme.dim, theme.bg)
      else
        for _, entry in ipairs(app.log.entries) do
          if logY > h then break end
          buf:blit(logX, logY, util.fit(entry.time or "", 10),
            entry.seen and theme.line or theme.accent, theme.bg)
          if logbook.isContact(entry) then
            buf:blit(logX + 11, logY, util.shorten(entry.name or "?", 12),
              theme.dim, theme.bg)
            buf:blit(logX + 24, logY, (entry.dist or 0) .. "m", theme.line, theme.bg)
          else
            -- An alarm -- the power buffer running low -- has no distance and
            -- no bearing, so it takes the rest of the line.
            buf:blit(logX + 11, logY, util.shorten(entry.text or "alarm",
              max(1, colW - 12)), theme.alarm, theme.bg)
          end
          logY = logY + 1
        end
      end
    end

    -- Footer hint, only where there is room for it.
    if h >= 8 and w >= 40 then
      local hint = "1-6 pages   M settings   H help   Q quit"
      buf:blit(max(1, w - #hint), h, util.shorten(hint, w - 1), theme.line, theme.bg)
    end

    -- Keep the weather badge visible even here.
    if snap and snap.available and w >= 30 then
      local badge = sky.badge(snap.scene)
      buf:blit(max(1, w - #badge), 1, badge, theme.accent, theme.bg)
    end
  end

  return { refresh = function() canvas:markRenderDirty() end }
end

return view
