-- The dashboard: station configuration, hardware, environment and traffic on
-- one screen. This is the default terminal page.

local config = require("radar.config")
local sky    = require("radar.sky")
local theme  = require("radar.theme")
local util   = require("radar.util")

local view = {}

local max, floor = math.max, math.floor

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
      logY = heading(logX, logY, ("RECENT (%d)"):format(app.log:count()))
      if app.log:count() == 0 then
        buf:blit(logX, logY, "(empty)", theme.dim, theme.bg)
      else
        for _, entry in ipairs(app.log.entries) do
          if logY > h then break end
          buf:blit(logX, logY, util.fit(entry.time or "", 10), theme.line, theme.bg)
          buf:blit(logX + 11, logY, util.shorten(entry.name, 12), theme.dim, theme.bg)
          buf:blit(logX + 24, logY, (entry.dist or 0) .. "m", theme.line, theme.bg)
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
