-- ALERTS module: everything the station has had to tell you, newest first.
--
-- Until v8.4 this was the LOG page and listed arrivals only. A contact walking
-- into range is not the only thing worth recording, though -- a power buffer
-- running low is the other one -- and having to look in two places to find out
-- what happened while you were away is exactly the failure a log page exists
-- to prevent. So it takes both, and is named for what it is.
--
-- Unread entries are counted in every screen's header. Opening this page ON
-- THE TERMINAL dismisses them; a monitor showing the page does not, because a
-- monitor cycling through its pages would otherwise clear the marker with
-- nobody in the room.
--
-- Wide displays get the visitor tally beside the history; narrow ones get the
-- history alone. The module also owns the ALERT LOG section of the settings
-- page, since clearing and dismissing are the only things there are to
-- configure about it.

local logbook = require("radar.logbook")
local theme   = require("radar.theme")
local ui      = require("radar.ui")
local util    = require("radar.util")

local max = math.max

local view = {
  id = "alerts",
  title = "ALERTS",
  short = "ALT",
  order = 60,
  summary = "arrivals, alarms and a visitor tally",
}

local ZONE_COLORS = {
  CLOSE   = theme.alarm,
  MEDIUM  = theme.warn,
  FAR     = theme.accent,
  EXTREME = theme.dim,
}

--- The colour an entry's distance or text is drawn in.
local function colorOf(entry)
  if not logbook.isContact(entry) then return theme.alarm end
  return ZONE_COLORS[entry.zone] or theme.dim
end

--- What an entry says, in one line, for a screen with no room for columns.
local function summaryOf(entry, width)
  if logbook.isContact(entry) then
    return util.shorten(entry.name or "?", max(1, width))
  end
  return util.shorten(entry.text or "alarm", max(1, width))
end

function view.build(container, app, root)
  local canvas = container:addCanvas({
    x = 1, y = 1,
    width = function(s) return s.parent.width end,
    height = function(s) return s.parent.height end,
    background = theme.bg,
  })

  canvas.draw = function(self, buf)
    local w, h = self.width, self.height
    buf:fill(1, 1, w, h, " ", theme.text, theme.bg)

    local entries = app.log.entries

    -- A 1x1 monitor gets what and when, with no heading and no rule: nine rows
    -- of history beats seven rows plus a title bar that repeats the tab.
    if ui.isTiny(w) then
      if #entries == 0 then
        buf:blit(1, 1, "Nothing yet.", theme.dim, theme.bg)
        if h >= 3 then
          buf:blit(1, 3, "Arrivals", theme.line, theme.bg)
          buf:blit(1, 4, "and alarms", theme.line, theme.bg)
          buf:blit(1, 5, "log here.", theme.line, theme.bg)
        end
        return
      end
      for index, entry in ipairs(entries) do
        if index > h then break end
        -- A timestamp is "D142 09:31"; the clock alone places an entry well
        -- enough, and the day was costing five characters of the text.
        local stamp = tostring(entry.time or "")
        local when = stamp:match("(%d%d:%d%d)") or stamp:sub(1, 5)
        buf:blit(1, index, when, entry.seen and theme.line or theme.accent, theme.bg)
        buf:blit(7, index, summaryOf(entry, w - 7), colorOf(entry), theme.bg)
      end
      return
    end
    local twoPane = w >= 52
    local historyWidth = twoPane and (w - 24) or w

    local unread = app.log:unread()
    local title = ("ALERTS (%d)"):format(#entries)
    if unread > 0 then title = title .. ("   %d new"):format(unread) end
    buf:blit(2, 1, title, theme.accent, theme.bg)
    buf:fill(1, 2, historyWidth, 1, "-", theme.line, theme.bg)

    if #entries == 0 then
      buf:blit(2, 4, "Nothing logged yet.", theme.dim, theme.bg)
      buf:blit(2, 5, "Arrivals and alarms are recorded automatically.",
        theme.line, theme.bg)
    else
      local showZone = historyWidth >= 44
      local nameWidth = util.clamp(historyWidth - 24, 6, 14)
      local row = 3
      for _, entry in ipairs(entries) do
        if row > h then break end
        buf:blit(2, row, util.fit(entry.time or "", 10),
          entry.seen and theme.line or theme.accent, theme.bg)

        if logbook.isContact(entry) then
          buf:blit(13, row, util.shorten(entry.name or "?", nameWidth),
            theme.text, theme.bg)
          local distX = 13 + nameWidth + 1
          buf:blit(distX, row, util.fit((entry.dist or 0) .. "m", 7, true),
            colorOf(entry), theme.bg)
          buf:blit(distX + 8, row, util.fit(entry.dir or "", 3), theme.accent, theme.bg)
          if showZone then
            buf:blit(distX + 12, row, util.fit(entry.zone or "", 7),
              colorOf(entry), theme.bg)
          end
        else
          -- An alarm has no distance and no bearing, so it gets the whole row
          -- rather than being squeezed into the name column.
          buf:blit(13, row, util.shorten(entry.text or "alarm",
            max(1, historyWidth - 13)), theme.alarm, theme.bg)
        end
        row = row + 1
      end
    end

    if not twoPane then return end

    -- Visitor tally on the right.
    local x = historyWidth + 2
    buf:fill(x - 1, 1, 1, h, " ", theme.line, theme.line)
    buf:blit(x + 1, 1, "TOP VISITORS", theme.accent, theme.bg)
    buf:fill(x + 1, 2, w - x, 1, "-", theme.line, theme.bg)

    local stats = app.log:stats()
    if #stats == 0 then
      buf:blit(x + 1, 4, "(none yet)", theme.dim, theme.bg)
      return
    end
    local row = 3
    for _, entry in ipairs(stats) do
      if row > h then break end
      buf:blit(x + 1, row, util.shorten(entry.name, 13), theme.text, theme.bg)
      buf:blit(x + 15, row, util.fit("x" .. entry.count, 5, true), theme.warn, theme.bg)
      row = row + 1
    end
  end

  return {
    refresh = function() canvas:markRenderDirty() end,
    -- Looking at the page IS the dismissal. Only on the terminal: a monitor
    -- walking its rotation would otherwise clear the marker unattended.
    shown = function()
      if root and root.isTerminal then app:markAlertsRead() end
    end,
  }
end

-- ---------------------------------------------------------------- settings ---

function view.settings(ctx)
  ctx.heading("ALERT LOG")

  ctx.row("Entries", function()
    local total = ctx.app.log:count()
    local unread = ctx.app.log:unread()
    if unread > 0 then return ("%d   %d unread"):format(total, unread) end
    return tostring(total)
  end, function()
    ctx.app:clearLog()
    ctx.root:toast("Alerts cleared", "info")
  end, function()
    return ctx.app.log:unread() > 0 and theme.accent or theme.text
  end)

  ctx.note("Press to clear. The C key does the same thing.")

  ctx.action("Dismiss unread alerts", function()
    local cleared = ctx.app:markAlertsRead()
    ctx.root:toast(cleared > 0 and ("%d dismissed"):format(cleared)
      or "Nothing unread", cleared > 0 and "success" or "info")
  end)

  ctx.note("Opening the ALERTS page on this terminal does the same thing.")
  ctx.spacer()
end

view.colorOf = colorOf
view.summaryOf = summaryOf

return view
