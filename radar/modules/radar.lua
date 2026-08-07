-- RADAR module: the scope, a sweeping polar plot of every contact.
--
-- Drawn at sub-pixel resolution, so the range rings are genuinely round and a
-- blip lands within a third of a character cell of its true bearing. The whole
-- picture is one Canvas: a single draw callback, no per-blip elements.

local pixel = require("radar.pixel")
local theme = require("radar.theme")
local ui    = require("radar.ui")
local util  = require("radar.util")
local config = require("radar.config")

local view = {
  id = "radar",
  title = "RADAR",
  short = "RDR",
  order = 20,
  summary = "the polar scope, with range rings and a live sweep",
}

-- Palette indices for the scope.
local BG, RING, TRAIL, SWEEP, CLOSE, MEDIUM, FAINT, HIGH, BRIGHT = 1, 2, 3, 4, 5, 6, 7, 8, 9

local PALETTE = {
  theme.tones.bg,
  theme.tones.line,
  theme.tones.panel,
  theme.tones.accent,
  theme.tones.alarm,
  theme.tones.warn,
  theme.tones.dim,
  theme.tones.good,
  theme.tones.text,
}

local floor, min, max = math.floor, math.min, math.max

--- Blip colour: height above or below the centre wins over distance, since
--- "someone is on the roof" matters more than "someone is 90 blocks away".
local function blipIndex(contact)
  if contact.dy > 4 then return HIGH end
  if contact.dist <= 50 then return CLOSE end
  if contact.dist <= 150 then return MEDIUM end
  if contact.dist <= 300 then return SWEEP end
  return FAINT
end

--- Plot radius in blocks. A fixed range plots to its own edge; MAX grows to
--- fit the furthest contact so the scope never looks empty.
local function plotRadius(app)
  local radius = config.range(app.cfg)
  if config.rangeLabel(app.cfg) == "MAX" then
    radius = 64
    for _, contact in ipairs(app.contacts) do
      if contact.dist > radius then radius = contact.dist end
    end
    radius = radius * 1.2
  end
  return radius > 0 and radius or 64
end

function view.build(container, app)
  local grid = pixel.new(1, 1, PALETTE)
  local releaseAnimation = nil

  local canvas = container:addCanvas({
    x = 1, y = 1,
    width = function(s) return s.parent.width end,
    height = function(s) return s.parent.height end,
    background = theme.bg,
  })

  canvas.draw = function(self, buf)
    local cellW, cellH = self.width, self.height
    if cellW < 4 or cellH < 3 then return end

    grid:resize(cellW, cellH)
    grid:clear(BG)

    local w, h = grid.w, grid.h
    local cx, cy = w / 2, h / 2
    -- Two cells of headroom at the top for the range readout.
    local radiusPx = max(3, min(w / 2 - 2, h / 2 - 4))
    local blocks = plotRadius(app)
    local scale = radiusPx / blocks

    -- Range rings and cross hairs.
    for _, fraction in ipairs({ 0.34, 0.67, 1.0 }) do
      grid:dashedRing(cx, cy, radiusPx * fraction, RING, 4, 3)
    end
    for i = -radiusPx, radiusPx, 3 do
      grid:set(cx + i, cy, RING)
      grid:set(cx, cy + i, RING)
    end

    -- Sweep: a fading wedge behind a bright leading edge.
    if app.cfg.animate then
      local lead = (app.anim * 72) % 360
      for back = 1, 7 do
        local angle = math.rad(lead - back * 7 - 90)
        grid:line(cx, cy,
          cx + math.cos(angle) * radiusPx,
          cy + math.sin(angle) * radiusPx, TRAIL)
      end
      local angle = math.rad(lead - 90)
      grid:line(cx, cy, cx + math.cos(angle) * radiusPx, cy + math.sin(angle) * radiusPx, SWEEP)
    end

    -- Centre marker: you, or the base you are watching.
    grid:hline(cx - 2, cx + 2, cy, BRIGHT)
    grid:vline(cx, cy - 2, cy + 2, BRIGHT)

    -- Lubber line: with the orientation unlocked the top of the scope is
    -- wherever the operator is looking, so it needs marking. A fixed scope
    -- gets no line, because the compass letters already say which way is up.
    local unlocked = config.isUnlocked(app.cfg)
    if unlocked and app.heading then
      grid:vline(cx, cy - radiusPx - 2, cy - radiusPx + 1, BRIGHT)
      grid:hline(cx - 1, cx + 1, cy - radiusPx, BRIGHT)
    end

    local rotation = app:rotation()

    -- Contacts given a symbol of their own. Collected here and drawn in the
    -- text pass below, because a character has to go into the CELL buffer --
    -- the sub-pixel grid has no idea what a letter is -- and the grid is
    -- blitted over the top of anything written before it.
    local marks = {}

    -- Contacts, furthest first so the nearest wins the pixel.
    for i = #app.contacts, 1, -1 do
      local contact = app.contacts[i]
      local rx, rz = util.rotateXZ(contact.dx, contact.dz, rotation)
      local px, py = cx + rx * scale, cy + rz * scale
      -- Clamp anything past the edge onto the rim rather than dropping it.
      local dx, dy = px - cx, py - cy
      local reach = math.sqrt(dx * dx + dy * dy)
      local offRim = reach > radiusPx
      if offRim and reach > 0 then
        px, py = cx + dx / reach * radiusPx, cy + dy / reach * radiusPx
      end

      local index = blipIndex(contact)
      local symbol = config.iconFor(app.cfg, contact.name)

      if symbol then
        -- No disc under it: the character replaces its whole cell, so a blip
        -- drawn as well would only be the parts of it that stuck out.
        marks[#marks + 1] = { px = px, py = py, symbol = symbol, index = index }
        -- The nearest still gets its ring, which sits a cell clear of the
        -- character rather than under it.
        if i == 1 and not offRim then grid:ring(px, py, 3, index) end
      elseif offRim then
        grid:set(px, py, index)
      else
        grid:disc(px, py, 1.2, index)
        if i == 1 then grid:ring(px, py, 3, index) end
      end
    end

    grid:blitTo(buf, 1, 1)

    -- Text goes on last, straight into the buffer, so it stays crisp.
    local function cellOf(px, py)
      return util.clamp(floor(px / 2) + 1, 1, cellW), util.clamp(floor(py / 3) + 1, 1, cellH)
    end

    -- The named contacts, in the same colour their blip would have been: the
    -- symbol says WHO, and the colour goes on saying how close.
    for _, mark in ipairs(marks) do
      local tx, ty = cellOf(mark.px, mark.py)
      buf:blit(tx, ty, mark.symbol, PALETTE[mark.index].c, theme.bg)
    end

    -- Compass letters just outside the outer ring.
    local bearings = cellW >= 34
      and { 0, 45, 90, 135, 180, 225, 270, 315 } or { 0, 90, 180, 270 }
    for _, bearing in ipairs(bearings) do
      local sx, sy = util.bearingToScreen(bearing, rotation)
      local label = util.DIR_NAMES[floor(bearing / 45) + 1]
      local tx, ty = cellOf(cx + sx * (radiusPx + 3), cy + sy * (radiusPx + 3))
      tx = util.clamp(tx - floor(#label / 2), 1, cellW - #label + 1)
      buf:blit(tx, ty, label, theme.dim, theme.bg)
    end

    -- Range readout, top left.
    --
    -- Not on a 1x1 monitor. Two of the nine rows there went on "1k SHIP" and
    -- "1000m rings", which is a fifth of the screen spent on two settings that
    -- do not change on their own -- and both of them sat over the top left
    -- quarter of the picture the screen exists to show. Every larger display
    -- has the rows to spare and keeps them.
    if not ui.isTiny(cellW) then
      local ring = util.round(blocks)
      buf:blit(1, 1, config.rangeLabel(app.cfg) .. "  " ..
        config.modeLabel(app.cfg, true), theme.dim, theme.bg)
      buf:blit(1, 2, ring .. "m ring", theme.line, theme.bg)
    end

    -- Nearest contact, top right.
    local nearest = app.contacts[1]
    if nearest and cellW >= 24 then
      local text = string.format("%s %s %s",
        util.shorten(nearest.name, 10), util.distanceLabel(nearest.dist), nearest.dir)
      buf:blit(max(1, cellW - #text + 1), 1, text, nearest.zoneColor, theme.bg)
    end

    -- Orientation readout, bottom right. An unlocked scope always says so,
    -- because "which way is up" is no longer something you can assume.
    local text, color
    if unlocked then
      if app.heading then
        -- app.heading, not app:rotation(). The rotation is the EASED value the
        -- picture is drawn at, which lags on purpose and never quite settles
        -- while the source moves -- so reporting it here had this page and the
        -- flight page showing different numbers under the same three letters.
        -- One heading, one meaning: where the tracking mode says the nose is.
        text, color = ("HDG %03d"):format(util.round(app.heading) % 360), theme.accent
      else
        text, color = "HDG --", theme.warn
      end
    elseif app.cfg.rotation ~= 0 then
      text, color = app.cfg.rotation .. " deg", theme.line
    end
    if text then
      buf:blit(max(1, cellW - #text + 1), cellH, text, color, theme.bg)
    end

    if app.scanError then
      buf:blit(1, cellH, util.shorten(app.scanError, cellW), theme.alarm, theme.bg)
    end
  end

  return {
    refresh = function() canvas:markRenderDirty() end,
    animate = function() canvas:markRenderDirty() end,
    shown = function()
      if not releaseAnimation then releaseAnimation = app:requestAnimation() end
    end,
    hidden = function()
      if releaseAnimation then releaseAnimation(); releaseAnimation = nil end
    end,
  }
end

return view
