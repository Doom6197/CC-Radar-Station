-- CONTACTS module: every detected player, nearest first.
--
-- Columns are added as the display gets wider rather than truncated, so the
-- same page is readable on a 15-cell pocket screen and on a 5x5 monitor.

local config  = require("radar.config")
local modules = require("radar.modules")
local theme   = require("radar.theme")
local ui      = require("radar.ui")
local util    = require("radar.util")

local view = {
  id = "contacts",
  title = "CONTACTS",
  short = "CON",
  order = 30,
  summary = "the contact table: distance, bearing, altitude, health",
}

local max = math.max

--- Signed height difference, coloured so "above you" and "below you" read at
--- a glance.
local function heightTag(dy)
  local rounded = util.round(dy)
  if rounded > 3 then return "+" .. rounded, theme.good end
  if rounded < -3 then return tostring(rounded), theme.warn end
  return "  0", theme.dim
end

--- Every name worth offering an icon to: whoever is in range now, whoever has
--- been logged, and anyone already given one.
---
--- That last source is what matters: a symbol set for somebody who has since
--- logged off would otherwise be unreachable, so the only way to change it
--- would be to wait for them to come back.
local function knownNames(app)
  local seen, names = {}, {}
  local function add(name)
    if type(name) == "string" and #name > 0 and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  for _, contact in ipairs(app.contacts) do add(contact.name) end
  for name in pairs(app.cfg.icons or {}) do add(name) end
  for _, row in ipairs(app.log:stats()) do add(row.name) end
  table.sort(names)
  return names
end

--- A five-cell health bar, painted as coloured cells rather than characters so
--- it does not depend on which block glyphs a font happens to have.
local function healthBar(buf, x, y, health, maxHealth)
  if not health or not maxHealth or maxHealth <= 0 then
    buf:blit(x, y, "  -  ", theme.line, theme.bg)
    return
  end
  local fraction = util.clamp(health / maxHealth, 0, 1)
  local filled = util.clamp(util.round(fraction * 5), 0, 5)
  local color = fraction < 0.4 and theme.alarm or (fraction < 0.75 and theme.warn or theme.good)
  if filled > 0 then buf:fill(x, y, filled, 1, " ", theme.bg, color) end
  if filled < 5 then buf:fill(x + filled, y, 5 - filled, 1, " ", theme.bg, theme.line) end
end

function view.build(container, app, root)
  -- Which screen row is which contact, rebuilt on every draw. The list scrolls
  -- nothing and sorts by distance, so the row a name is on changes constantly
  -- -- recording it as it is drawn is the only way a tap can name the right
  -- player rather than the one who was there a sweep ago.
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

    -- A 1x1 monitor gets names and distances and nothing else. The column
    -- headers alone came to "CONTACTDIST" at this width, and the empty-state
    -- sentence was cut mid-word.
    if ui.isTiny(w) then
      if app.scanError then
        for index, line in ipairs(util.wrap(app.scanError, w)) do
          if index > h then break end
          buf:blit(1, index, line, theme.alarm, theme.bg)
        end
        return
      end

      if #app.contacts == 0 then
        buf:blit(1, 1, "All clear.", theme.dim, theme.bg)
        if h >= 3 then
          buf:blit(1, 3, "Watching", theme.line, theme.bg)
          buf:blit(1, 4, config.modeLabel(app.cfg, true):lower() .. ".",
            theme.line, theme.bg)
        end
        return
      end

      for index, contact in ipairs(app.contacts) do
        if index > h then break end
        if index == h and index < #app.contacts then
          buf:blit(1, index, ("+%d more"):format(#app.contacts - index + 1),
            theme.dim, theme.bg)
          break
        end
        local distance = util.distanceLabel(contact.dist)
        -- Name from the left, distance hard right: the two things worth
        -- knowing, with the gap between them taking the truncation.
        buf:blit(1, index, util.shorten(contact.name, max(1, w - #distance - 1)),
          theme.text, theme.bg)
        buf:blit(max(1, w - #distance), index, distance, contact.zoneColor, theme.bg)
        hits[index] = contact.name
      end
      return
    end

    -- Column budget, widest first.
    local showDir     = w >= 22
    local showHeight  = w >= 30
    local showZone    = w >= 40
    local showCoords  = w >= 56
    local showHealth  = w >= 68

    local nameWidth = util.clamp(w - 12, 6, 16)
    local x = { name = 2 }
    x.dist   = x.name + nameWidth + 1
    x.dir    = x.dist + 7
    x.height = x.dir + 4
    x.zone   = x.height + 5
    x.coords = x.zone + 8
    x.health = x.coords + 17

    -- Header
    buf:blit(x.name, 1, "CONTACT", theme.dim, theme.bg)
    buf:blit(x.dist, 1, "DIST", theme.dim, theme.bg)
    if showDir then buf:blit(x.dir, 1, "BRG", theme.dim, theme.bg) end
    if showHeight then buf:blit(x.height, 1, "ALT", theme.dim, theme.bg) end
    if showZone then buf:blit(x.zone, 1, "BAND", theme.dim, theme.bg) end
    if showCoords then buf:blit(x.coords, 1, "POSITION", theme.dim, theme.bg) end
    if showHealth then buf:blit(x.health, 1, "HP", theme.dim, theme.bg) end
    buf:fill(1, 2, w, 1, "-", theme.line, theme.bg)

    if app.scanError then
      buf:blit(2, 4, util.shorten(app.scanError, w - 2), theme.alarm, theme.bg)
      return
    end

    if #app.contacts == 0 then
      buf:blit(2, 4, "No players detected.", theme.dim, theme.bg)
      local hint = "Watching: " .. config.modeLabel(app.cfg)
      buf:blit(2, 5, util.shorten(hint, w - 2), theme.line, theme.bg)
      return
    end

    -- One row is held back for the footer on anything but a tiny screen.
    local hasFooter = h >= 6
    local lastRow = h - (hasFooter and 1 or 0)
    local row = 3

    for i, contact in ipairs(app.contacts) do
      if row > lastRow then break end
      if row == lastRow and i < #app.contacts then
        buf:blit(2, row, ("+%d more"):format(#app.contacts - i + 1), theme.dim, theme.bg)
        break
      end

      -- The nearest contact gets a marker so it is obvious which one the
      -- radar HUD and the N shortcut are talking about.
      if i == 1 then buf:blit(1, row, ">", contact.zoneColor, theme.bg) end
      buf:blit(x.name, row, util.shorten(contact.name, nameWidth), theme.text, theme.bg)
      buf:blit(x.dist, row, util.fit(util.distanceLabel(contact.dist), 6, true),
        contact.zoneColor, theme.bg)

      if showDir then buf:blit(x.dir, row, util.fit(contact.dir, 3), theme.accent, theme.bg) end
      if showHeight then
        local tag, color = heightTag(contact.dy)
        buf:blit(x.height, row, util.fit(tag, 4), color, theme.bg)
      end
      if showZone then
        buf:blit(x.zone, row, util.fit(contact.zone, 7), contact.zoneColor, theme.bg)
      end
      if showCoords then
        buf:blit(x.coords, row, util.fit(("%d %d %d"):format(
          math.floor(contact.x), math.floor(contact.y), math.floor(contact.z)), 16),
          theme.dim, theme.bg)
      end
      if showHealth then
        healthBar(buf, x.health, row, contact.health, contact.maxHealth)
      end

      hits[row] = contact.name
      row = row + 1
    end

    -- Footer: what the numbers are measured from.
    if hasFooter then
      local centre = app.centre
      local from = centre
        and ("from %d, %d, %d"):format(math.floor(centre.x),
          math.floor(centre.y or 0), math.floor(centre.z))
        or "no centre set"
      local footer = ("%d in range   %s"):format(#app.contacts, from)
      buf:blit(2, h, util.shorten(footer, max(1, w - 2)), theme.line, theme.bg)
    end
  end

  return {
    refresh = function() canvas:markRenderDirty() end,

    --- Pressing a name aims the flight panel at that player, and keeps aiming
    --- at them as they move -- picking a chase target off a list you are
    --- already reading beats typing their name into a picker.
    ---
    --- With no flight page installed there is nothing a tap could mean, so it
    --- is left alone and the screen moves on to the next page as usual.
    touch = function(_, y)
      local name = hits[y]
      if not name then return false end
      if not app.setFlightTarget or not modules.isEnabled(app.cfg, "flight") then
        return false
      end
      if app.setFlightTarget("contact:" .. name) then
        if root then root:toast("Following " .. util.shorten(name, 14), "success") end
      elseif root then
        root:toast("Already following " .. util.shorten(name, 14), "info")
      end
      return true
    end,
  }
end

-- ---------------------------------------------------------------- settings ---

--- Who gets drawn as what.
---
--- It lives with CONTACTS rather than with the scope because the question is
--- about a PERSON, not about the picture: the list of names is here, and this
--- is the page you are already looking at when you decide that one of them is
--- worth telling apart from the rest.
function view.settings(ctx)
  local app, root = ctx.app, ctx.root
  local cfg = app.cfg

  ctx.heading("SCOPE ICONS")

  --- Second picker: which symbol, for the name just chosen.
  local function editIcon(name)
    local entries = {}
    for _, entry in ipairs(config.ICONS) do
      entries[#entries + 1] = {
        label = ctx.withHint(config.iconLabel(entry), entry.hint),
        value = entry.id,
      }
    end
    ctx.openPicker("ICON FOR " .. util.shorten(name, 14), entries,
      cfg.icons[name] or "dot", function(id)
        -- The default is stored as absence, so the table only ever holds the
        -- handful of names that were actually given something.
        cfg.icons[name] = (id ~= "dot") and id or nil
        app:saveConfig()
        local symbol = config.iconFor(cfg, name)
        root:toast(symbol
          and ("%s is now %s"):format(util.shorten(name, 12), symbol)
          or ("%s is a plain blip again"):format(util.shorten(name, 12)), "success")
        ctx.refreshRows()
      end)
  end

  ctx.row("Icons", function()
    local named = 0
    for _ in pairs(cfg.icons) do named = named + 1 end
    if named == 0 then return "everyone is a dot" end
    if ctx.isNarrow() then return ("%d named"):format(named) end

    -- The symbols themselves, which is the fastest way to see what is set.
    local shown = {}
    for name in pairs(cfg.icons) do
      shown[#shown + 1] = config.iconFor(cfg, name) or "?"
    end
    table.sort(shown)
    return ("%d named   %s"):format(named, table.concat(shown, " "))
  end, function()
    local names = knownNames(app)
    if #names == 0 then
      root:toast("Nobody has been detected yet", "info")
      return
    end
    local entries = {}
    for _, name in ipairs(names) do
      entries[#entries + 1] = {
        label = ("%s  %s"):format(config.iconFor(cfg, name) or ".",
          util.shorten(name, 18)),
        value = name,
      }
    end
    ctx.openPicker("PICK A CONTACT", entries, nil, editIcon)
  end, function() return next(cfg.icons) and theme.accent or theme.dim end)

  ctx.note("Press a name to give them a symbol of their own. The scope draws "
    .. "that instead of a blip, still coloured by how close they are, so the "
    .. "picture says who as well as where.")
  ctx.note("Anyone detected once is on the list, whether or not they are in "
    .. "range now.")

  ctx.action("Everyone back to plain blips", function()
    local named = 0
    for _ in pairs(cfg.icons) do named = named + 1 end
    if named == 0 then
      root:toast("Nothing to clear", "info")
      return
    end
    cfg.icons = {}
    app:saveConfig()
    root:toast(("Cleared %d icon%s"):format(named, named == 1 and "" or "s"), "info")
    ctx.refreshRows()
  end)

  ctx.spacer()
end

return view
