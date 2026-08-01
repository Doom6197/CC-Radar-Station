-- The weather page: a live sky over a readout of everything the Environment
-- Detector knows.
--
-- The picture is generated from the current snapshot rather than picked from a
-- set of stock images, so the sun climbs, the moon shows its real phase, the
-- palette shifts through dawn/day/dusk/night, and rain, snow, thunder, the
-- Nether and the End each get their own treatment.

local pixel  = require("radar.pixel")
local glyphs = require("radar.glyphs")
local sky    = require("radar.sky")
local theme  = require("radar.theme")
local util   = require("radar.util")

local view = {}

-- Sky palette slots, mirrored from radar.sky.
local BODY, LAND_SHADE = 4, 9

local floor, max = math.floor, math.max

--- Rows reserved at the bottom for the readout. Small screens give it up
--- entirely and let the artwork fill the display.
local function readoutRows(height)
  if height >= 13 then return 7 end
  if height >= 10 then return 5 end
  if height >= 8 then return 3 end
  return 0
end

local function sceneHeight(height)
  return max(1, height - readoutRows(height))
end

--- "LABEL value", clipped to the column width.
local function field(buf, x, y, width, label, value, valueColor)
  if width < 6 then return end
  buf:blit(x, y, label, theme.dim, theme.bg)
  local vx = x + #label + 1
  local room = width - #label - 1
  if room > 0 then
    buf:blit(vx, y, util.shorten(tostring(value), room), valueColor or theme.text, theme.bg)
  end
end

function view.build(container, app)
  local grid = pixel.new(1, 1, theme.skies.day)
  local releaseAnimation = nil

  -- ------------------------------------------------------------ the sky ---
  local scene = container:addCanvas({
    x = 1, y = 1,
    width = function(s) return s.parent.width end,
    height = function(s) return sceneHeight(s.parent.height) end,
    background = theme.bg,
  })

  scene.draw = function(self, buf)
    local snap = app:snapshot()
    local cellW, cellH = self.width, self.height
    if cellW < 2 or cellH < 1 then return end

    if not snap or not snap.available then
      buf:fill(1, 1, cellW, cellH, " ", theme.dim, theme.panel)
      local lines = {
        "No Environment Detector",
        "",
        "Place an Advanced Peripherals",
        "Environment Detector next to this",
        "computer, or on the same wired",
        "modem network, then press O to",
        "rescan.",
      }
      if snap and snap.reason == "disabled" then
        lines[1] = "Environment polling is off"
        lines[3] = "Turn it back on in Settings."
        for i = 4, #lines do lines[i] = "" end
      end
      for i, line in ipairs(lines) do
        if i <= cellH then
          buf:blit(2, i, util.shorten(line, cellW - 2),
            i == 1 and theme.warn or theme.dim, theme.panel)
        end
      end
      return
    end

    local sceneData = snap.scene
    grid:resize(cellW, cellH)
    grid:setPalette(sceneData.palette)
    sky.paint(grid, sceneData, app.cfg.animate and app.anim or 0)

    -- Big clock burned into the artwork, with a shadow so it survives a
    -- bright noon sky as readily as a dark one.
    if cellW >= 18 and cellH >= 5 then
      local scale = (cellW >= 30 and cellH >= 8) and 2 or 1
      glyphs.drawShadowed(grid, 3, 3, snap.clock, BODY, LAND_SHADE, scale)
    end

    grid:blitTo(buf, 1, 1)

    -- Caption along the bottom, over the dark ground silhouette, where it
    -- neither fights the clock nor covers the sky.
    local title = sceneData.title or ""
    if cellW >= 12 and cellH >= 3 then
      local subtitle = sceneData.subtitle or ""
      local showSubtitle = #subtitle > 0 and cellW >= 24 and cellH >= 5
      buf:blit(max(1, cellW - #title), cellH - (showSubtitle and 1 or 0),
        title, theme.text, false)
      if showSubtitle then
        buf:blit(max(1, cellW - #subtitle), cellH, subtitle, theme.dim, false)
      end
    end
  end

  -- ------------------------------------------------------- the readout ---
  local readout = container:addCanvas({
    x = 1,
    y = function(s) return sceneHeight(s.parent.height) + 1 end,
    width = function(s) return s.parent.width end,
    height = function(s) return max(1, readoutRows(s.parent.height)) end,
    visible = function(s) return readoutRows(s.parent.height) > 0 end,
    background = theme.bg,
  })

  readout.draw = function(self, buf)
    local snap = app:snapshot()
    local w, h = self.width, self.height
    buf:fill(1, 1, w, h, " ", theme.dim, theme.bg)
    if not snap or not snap.available then
      buf:blit(2, 1, util.shorten("Environment data unavailable", w - 2), theme.dim, theme.bg)
      return
    end

    local sceneData = snap.scene or {}
    local twoColumn = w >= 42
    local colW = twoColumn and floor((w - 3) / 2) or (w - 2)
    local leftX, rightX = 2, 2 + colW + 1

    -- Headline row: clock, in-game day, and the weather in one glance.
    local headline = string.format("%s   Day %d", snap.clock, snap.day or 0)
    buf:blit(2, 1, headline, theme.text, theme.bg)
    local badge = sky.badge(sceneData)
    buf:blit(max(1, w - #badge), 1, badge,
      (sceneData.weather == "storm" and theme.alarm)
      or (sceneData.weather ~= "clear" and theme.warn)
      or theme.accent, theme.bg)

    if h < 2 then return end
    buf:fill(1, 2, w, 1, "-", theme.line, theme.bg)

    local left, right = {}, {}
    local function push(list, label, value, color)
      list[#list + 1] = { label = label, value = value, color = color }
    end

    push(left, "SKY ", sceneData.title or "-", theme.text)
    if snap.kind == "overworld" then
      push(left, "MOON", snap.moonName or "-", theme.text)
    else
      push(left, "DIM ", snap.dimensionName or "-", theme.text)
    end
    push(left, "BIOM", snap.biomeName or "-", theme.text)
    -- What the artwork below is actually drawing, which is not always what
    -- the biome is called: an unrecognised modded biome falls back, and the
    -- scenery can be forced outright from the settings page.
    push(left, "GRND", (sceneData.groundLabel or "-")
      .. (sceneData.groundForced and "  (forced)" or ""),
      sceneData.groundForced and theme.warn or theme.dim)

    push(right, "LGHT", string.format("sky %s  blk %s",
      snap.skyLight or "?", snap.blockLight or "?"), theme.text)
    push(right, "SUN ", (snap.dayLight or 0) .. "/15", theme.text)
    push(right, "SLIM", snap.slimeChunk and "slime chunk" or "no",
      snap.slimeChunk and theme.good or theme.dim)

    local rows = h - 2
    if twoColumn then
      for i = 1, math.min(rows, math.max(#left, #right)) do
        if left[i] then field(buf, leftX, 2 + i, colW, left[i].label, left[i].value, left[i].color) end
        if right[i] then field(buf, rightX, 2 + i, colW, right[i].label, right[i].value, right[i].color) end
      end
    else
      local merged = {}
      for _, entry in ipairs(left) do merged[#merged + 1] = entry end
      for _, entry in ipairs(right) do merged[#merged + 1] = entry end
      for i = 1, math.min(rows, #merged) do
        field(buf, leftX, 2 + i, colW, merged[i].label, merged[i].value, merged[i].color)
      end
    end
  end

  local function markDirty()
    scene:markRenderDirty()
    readout:markRenderDirty()
  end

  return {
    refresh = markDirty,
    animate = markDirty,
    shown = function()
      if not releaseAnimation then releaseAnimation = app:requestAnimation() end
    end,
    hidden = function()
      if releaseAnimation then releaseAnimation(); releaseAnimation = nil end
    end,
  }
end

view.readoutRows = readoutRows
view.sceneHeight = sceneHeight

return view
