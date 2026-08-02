-- LOG module: detection history, plus the visitor tally derived from it.
-- Wide displays get both side by side; narrow ones get the history only.
--
-- The module also owns the HISTORY section of the settings page, since
-- clearing the log is the only thing there is to configure about it.

local theme = require("radar.theme")
local ui    = require("radar.ui")
local util  = require("radar.util")

local max = math.max

local view = {
  id = "log",
  title = "LOG",
  short = "LOG",
  order = 60,
  summary = "arrival history and a visitor tally",
}

local ZONE_COLORS = {
  CLOSE   = theme.alarm,
  MEDIUM  = theme.warn,
  FAR     = theme.accent,
  EXTREME = theme.dim,
}

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

    local entries = app.log.entries

    -- A 1x1 monitor gets who and when, with no heading and no rule: nine rows
    -- of history beats seven rows plus a title bar that repeats the tab.
    if ui.isTiny(w) then
      if #entries == 0 then
        buf:blit(1, 1, "Nothing yet.", theme.dim, theme.bg)
        if h >= 3 then
          buf:blit(1, 3, "Arrivals", theme.line, theme.bg)
          buf:blit(1, 4, "log here.", theme.line, theme.bg)
        end
        return
      end
      for index, entry in ipairs(entries) do
        if index > h then break end
        -- A timestamp is "D142 09:31"; the clock alone places an arrival well
        -- enough, and the day was costing five characters of the name.
        local stamp = tostring(entry.time or "")
        local when = stamp:match("(%d%d:%d%d)") or stamp:sub(1, 5)
        buf:blit(1, index, when, theme.line, theme.bg)
        buf:blit(7, index, util.shorten(entry.name, max(1, w - 7)),
          theme.text, theme.bg)
      end
      return
    end
    local twoPane = w >= 52
    local historyWidth = twoPane and (w - 24) or w

    buf:blit(2, 1, ("HISTORY (%d)"):format(#entries), theme.accent, theme.bg)
    buf:fill(1, 2, historyWidth, 1, "-", theme.line, theme.bg)

    if #entries == 0 then
      buf:blit(2, 4, "Nothing logged yet.", theme.dim, theme.bg)
      buf:blit(2, 5, "Arrivals are recorded automatically.", theme.line, theme.bg)
    else
      local showZone = historyWidth >= 44
      local nameWidth = util.clamp(historyWidth - 24, 6, 14)
      local row = 3
      for _, entry in ipairs(entries) do
        if row > h then break end
        buf:blit(2, row, util.fit(entry.time or "", 10), theme.line, theme.bg)
        buf:blit(13, row, util.shorten(entry.name, nameWidth), theme.text, theme.bg)
        local distX = 13 + nameWidth + 1
        buf:blit(distX, row, util.fit((entry.dist or 0) .. "m", 7, true),
          ZONE_COLORS[entry.zone] or theme.dim, theme.bg)
        buf:blit(distX + 8, row, util.fit(entry.dir or "", 3), theme.accent, theme.bg)
        if showZone then
          buf:blit(distX + 12, row, util.fit(entry.zone or "", 7),
            ZONE_COLORS[entry.zone] or theme.dim, theme.bg)
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

  return { refresh = function() canvas:markRenderDirty() end }
end

-- ---------------------------------------------------------------- settings ---

function view.settings(ctx)
  ctx.heading("HISTORY")
  ctx.row("Entries", function() return tostring(ctx.app.log:count()) end, function()
    ctx.app:clearLog()
    ctx.root:toast("Log cleared", "info")
  end)
  ctx.note("Press to clear. The C key does the same thing.")
  ctx.spacer()
end

return view
