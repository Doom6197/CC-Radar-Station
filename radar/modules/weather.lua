-- WEATHER module: a live sky over a readout of everything the Environment
-- Detector knows.
--
-- The picture is generated from the current snapshot rather than picked from a
-- set of stock images, so the sun climbs, the moon shows its real phase, the
-- palette shifts through dawn/day/dusk/night, and rain, snow, thunder, the
-- Nether and the End each get their own treatment.
--
-- This module owns everything about backdrops: the settings, the cycle, the
-- timer that walks it and the two settings sections that drive it. None of
-- that is in radar/app.lua or radar/config.lua any more, because nothing but
-- this page has ever cared about it -- and an install with the weather module
-- switched off should not be carrying a backdrop cycle around.

local backdrops = require("radar.backdrops")
local biomes = require("radar.biomes")
local pixel  = require("radar.pixel")
local glyphs = require("radar.glyphs")
local sky    = require("radar.sky")
local theme  = require("radar.theme")
local util   = require("radar.util")

local view = {
  id = "weather",
  title = "WEATHER",
  short = "WX",
  order = 40,
  summary = "live sky, biome scenery, clock, moon phase and backdrops",
}

-- Sky palette slots, mirrored from radar.sky.
local BODY, LAND_SHADE = 4, 9

local floor, max = math.floor, math.max

-- ------------------------------------------------------------- the settings ---

-- How long the page holds a backdrop before changing to the next. Slower at
-- the top end than a monitor's page rotation: a picture you are looking at
-- wants longer than a page you are glancing at.
view.BACKDROP_INTERVALS = { 10, 15, 30, 60, 120, 300, 600, 900, 1800 }

-- A backdrop is a place plus a sky, and the two are chosen separately: keep
-- the place and let the sky run live, and the picture follows the real hour
-- and the real weather.
view.BACKDROP_SKIES = {
  { id = "picture", label = "From the picture",
    hint = "the hour and weather it was drawn with" },
  { id = "live",    label = "Live",
    hint = "the real hour, weather and sun" },
}

view.defaults = {
  biomeScene = "auto",                 -- scenery, or a forced profile id

  -- "live" draws the real sky, "cycle" walks the chosen set on a timer,
  -- anything else is one radar.backdrops id.
  backdrop        = "live",
  backdropSky     = "picture",         -- or "live": follow the real sky
  backdropSeconds = 60,
  backdropSkip    = {},                -- backdrops left OUT of the cycle
}

--- Nearest legal entry of a plain array of numbers.
local function snapToNumber(list, value, fallback)
  value = tonumber(value)
  if not value then return fallback end
  local best, bestGap = fallback, math.huge
  for _, entry in ipairs(list) do
    local gap = math.abs(entry - value)
    if gap < bestGap then best, bestGap = entry, gap end
  end
  return best
end

local function hasId(list, id)
  for _, entry in ipairs(list) do
    if entry.id == id then return true end
  end
  return false
end

function view.sanitise(cfg)
  if cfg.biomeScene ~= "auto" and not biomes.PROFILES[cfg.biomeScene] then
    cfg.biomeScene = "auto"
  end

  -- A settings file written before v6 has no backdrop at all, and must come
  -- out of here drawing the live sky exactly as it did.
  if cfg.backdrop ~= "live" and cfg.backdrop ~= "cycle"
     and not backdrops.byId(cfg.backdrop) then
    cfg.backdrop = "live"
  end
  cfg.backdropSeconds = snapToNumber(view.BACKDROP_INTERVALS, cfg.backdropSeconds, 60)
  if not hasId(view.BACKDROP_SKIES, cfg.backdropSky) then
    cfg.backdropSky = "picture"
  end

  -- Only real backdrop ids may sit in the skip set, and it may never cover
  -- every picture: a cycle with nothing in it would leave the page blank.
  local skipped, kept = {}, 0
  if type(cfg.backdropSkip) == "table" then
    for id, on in pairs(cfg.backdropSkip) do
      if on and backdrops.byId(id) then skipped[id] = true end
    end
  end
  for _, id in ipairs(backdrops.ids()) do
    if not skipped[id] then kept = kept + 1 end
  end
  cfg.backdropSkip = kept > 0 and skipped or {}
end

--- One line describing where a backdrop's sky comes from.
---@param short? boolean Drop the hint, for a screen with no room for it
function view.skyLabel(cfg, short)
  for _, entry in ipairs(view.BACKDROP_SKIES) do
    if entry.id == cfg.backdropSky then
      if short then return entry.label end
      return entry.label .. " - " .. entry.hint
    end
  end
  return cfg.backdropSky
end

-- ------------------------------------------------------------- the backdrop ---
-- The page can draw a chosen picture instead of the live sky, and can walk a
-- set of them on a timer. Only the artwork is replaced: the readout under it
-- and the badge in the header keep reporting the real snapshot, so a
-- decorative sky never misrepresents the weather.

local Backdrop = {}
Backdrop.__index = Backdrop

function Backdrop.new(app)
  return setmetatable({
    app = app,
    index = 1,      -- position in the cycle
    at = 0,         -- when the current picture went up
  }, Backdrop)
end

--- The backdrop that should be on screen, or nil while the page is live.
function Backdrop:id()
  local cfg = self.app.cfg
  local choice = cfg.backdrop
  if choice == "live" then return nil end
  if choice ~= "cycle" then
    return backdrops.byId(choice) and choice or nil
  end
  local rotation = backdrops.rotation(cfg)
  return rotation[((self.index or 1) - 1) % #rotation + 1]
end

--- The scene the page paints: a backdrop when one is chosen, the live sky
--- otherwise, and nil when there is neither. A backdrop set to a live sky
--- keeps only its ground and takes the hour and the weather from the detector.
function Backdrop:scene()
  local id = self:id()
  if id then
    return backdrops.scene(id, self.app.env.snapshot, backdrops.isLiveSky(self.app.cfg))
  end
  local snap = self.app.env.snapshot
  return (snap and snap.available) and snap.scene or nil
end

--- Moves the cycle on by one and gives the new picture a full interval.
---@return boolean changed
function Backdrop:next(now)
  if self.app.cfg.backdrop ~= "cycle" then return false end
  local rotation = backdrops.rotation(self.app.cfg)
  self.index = ((self.index or 1) % #rotation) + 1
  self.at = now or os.clock()
  self.app:emit("backdrop")
  return true
end

--- Checks whether the interval has elapsed. The deadline is compared rather
--- than slept on, so shortening the interval takes effect straight away.
---@return boolean changed
function Backdrop:tick(now)
  if self.app.cfg.backdrop ~= "cycle" then
    self.at = now
    return false
  end
  if now - (self.at or 0) < self.app.cfg.backdropSeconds then return false end
  return self:next(now)
end

function Backdrop:set(choice)
  self.app.cfg.backdrop = choice
  self.at = os.clock()
  if choice ~= "cycle" then self.index = 1 end
  self.app:saveConfig()
  self.app:emit("backdrop")
end

--- Switches a backdrop between the sky it was drawn with and the real one.
--- The cycle is rewound with it: the two modes walk different rotations,
--- because under a live sky the presets that differ only by hour collapse
--- into one another.
function Backdrop:setSky(mode)
  self.app.cfg.backdropSky = mode
  self.index = 1
  self.at = os.clock()
  self.app:saveConfig()
  self.app:emit("backdrop")
end

view.Backdrop = Backdrop

function view.attach(app)
  app.backdrop = app.backdrop or Backdrop.new(app)
end

--- The backdrop cycle. Half-second granularity is ample for an interval
--- measured in tens of seconds, and it costs nothing at all while the page is
--- live or holding one picture.
function view.start(app)
  local basalt = require("basalt")
  local modules = require("radar.modules")
  basalt.schedule(function()
    while app.running do
      sleep(0.5)
      if modules.isEnabled(app.cfg, "weather") then
        pcall(app.backdrop.tick, app.backdrop, os.clock())
      end
    end
  end)
end

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
    -- A chosen backdrop wins over the live sky, and needs no detector at all --
    -- which is the point of it on a ship, where a detector reports nothing.
    local sceneData = app.backdrop:scene()
    local cellW, cellH = self.width, self.height
    if cellW < 2 or cellH < 1 then return end

    if not sceneData then
      buf:fill(1, 1, cellW, cellH, " ", theme.dim, theme.panel)
      local lines = {
        "No Environment Detector",
        "",
        "Place an Advanced Peripherals",
        "Environment Detector next to this",
        "computer, or on the same wired",
        "modem network, then press O to",
        "rescan.",
        "",
        "Or pick a backdrop under",
        "Settings / Backdrop, which needs",
        "no detector at all.",
      }
      if snap and snap.reason == "disabled" then
        lines[1] = "Environment polling is off"
        lines[3] = "Turn it back on in Settings."
        for i = 4, 7 do lines[i] = "" end
      end
      for i, line in ipairs(lines) do
        if i <= cellH then
          buf:blit(2, i, util.shorten(line, cellW - 2),
            i == 1 and theme.warn or theme.dim, theme.panel)
        end
      end
      return
    end

    grid:resize(cellW, cellH)
    grid:setPalette(sceneData.palette)
    sky.paint(grid, sceneData, app.cfg.animate and app.anim or 0)

    -- Big clock burned into the artwork, with a shadow so it survives a
    -- bright noon sky as readily as a dark one. The time is always the real
    -- one, so a backdrop with no detector behind it shows no clock.
    if snap and snap.available and cellW >= 18 and cellH >= 5 then
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

-- ---------------------------------------------------------------- settings ---
-- Two sections: what the LIVE page draws, and what a chosen picture replaces
-- it with. Both belong to this page, so both live here rather than in the
-- settings module, and both disappear along with the page when the module is
-- switched off.

function view.settings(ctx)
  local app, root, cfg = ctx.app, ctx.root, ctx.app.cfg

  -- environment ---------------------------------------------------------------
  ctx.heading("ENVIRONMENT")

  ctx.row("Detector", function()
    return app.kit.env and ("attached: " .. app.kit.envName) or "not found"
  end, function()
    app:rescan()
    root:toast(app.kit.env and "Environment Detector found"
      or "Still no Environment Detector", app.kit.env and "success" or "warning")
  end, function() return app.kit.env and theme.good or theme.warn end)

  ctx.row("Polling", function() return ctx.onOff(cfg.env) end, function()
    cfg.env = not cfg.env
    app:saveConfig()
    if cfg.env then app:pollEnvironment(true) end
  end, ctx.onOffColor(function() return cfg.env end))

  ctx.row("Poll every", function() return cfg.envSeconds .. " seconds" end, function()
    ctx.openPicker("ENVIRONMENT POLL RATE",
      ctx.entriesOf({ 1, 2, 5, 10, 30 },
        function(v) return v .. " seconds" end, function(v) return v end),
      cfg.envSeconds,
      function(value)
        cfg.envSeconds = value
        app:saveConfig()
        ctx.refreshRows()
      end)
  end)

  ctx.row("Scenery", function()
    if cfg.biomeScene == "auto" then
      local snap = app:snapshot()
      local live = snap and snap.scene and snap.scene.groundLabel
      return live and ("auto - " .. live) or "auto - follows the biome"
    end
    return "forced - " .. biomes.label(cfg.biomeScene)
  end, function()
    local entries = { { label = "Auto - follow the biome", value = "auto" } }
    for _, id in ipairs(biomes.ids()) do
      entries[#entries + 1] = { label = biomes.label(id), value = id }
    end
    ctx.openPicker("WEATHER PAGE SCENERY", entries, cfg.biomeScene, function(value)
      cfg.biomeScene = value
      app:saveConfig()
      app:pollEnvironment(true)
      ctx.refreshRows()
    end)
  end, function()
    -- A chosen backdrop replaces the whole picture, so the live scenery
    -- setting has nothing to act on until the page goes back to live.
    if cfg.backdrop ~= "live" then return theme.line end
    return cfg.biomeScene == "auto" and theme.text or theme.accent
  end)

  ctx.note("The ground the weather page draws. Force one if your pack "
    .. "reports a biome the station does not recognise.")
  ctx.spacer()

  -- backdrop ------------------------------------------------------------------
  -- A picture chosen by hand rather than read off the detector. On a pack
  -- where every dimension is floating islands -- and on a ship, where a
  -- detector riding a contraption reports nothing at all -- the live sky is
  -- often either wrong or missing.
  ctx.heading("BACKDROP")

  ctx.row("Picture", function()
    if cfg.backdrop == "live" then return "live - draws the real sky" end
    if cfg.backdrop == "cycle" then
      local current = app.backdrop:id()
      return ("cycle - %d, now %s"):format(#backdrops.rotation(cfg),
        current and backdrops.label(current) or "?")
    end
    return backdrops.label(cfg.backdrop)
  end, function()
    local entries = {
      { label = "Live - draw the real sky", value = "live" },
      { label = "Cycle - change on a timer", value = "cycle" },
    }
    for _, id in ipairs(backdrops.ids()) do
      entries[#entries + 1] = { label = backdrops.label(id), value = id }
    end
    ctx.openPicker("WEATHER PAGE BACKDROP", entries, cfg.backdrop, function(value)
      app.backdrop:set(value)
      ctx.refreshRows()
    end)
  end, function() return cfg.backdrop == "live" and theme.text or theme.accent end)

  ctx.note("A picture that ignores the weather and the biome. Works with "
    .. "no Environment Detector at all.")

  ctx.row("Sky", function() return view.skyLabel(cfg, ctx.isNarrow()) end, function()
    ctx.openPicker("BACKDROP SKY",
      ctx.entriesOf(view.BACKDROP_SKIES,
        function(s) return ctx.withHint(s.label, s.hint) end,
        function(s) return s.id end),
      cfg.backdropSky,
      function(value)
        app.backdrop:setSky(value)
        ctx.refreshRows()
      end)
  end, function()
    if cfg.backdrop == "live" then return theme.line end
    return backdrops.isLiveSky(cfg) and theme.accent or theme.text
  end)

  ctx.note("Live keeps the picture but takes the hour, the weather and the "
    .. "sun from the detector - so the airships fly through the real dusk "
    .. "and the real rain.")

  ctx.row("Change every", function()
    local seconds = cfg.backdropSeconds
    if seconds >= 60 then return ("%g minutes"):format(seconds / 60) end
    return seconds .. " seconds"
  end, function()
    ctx.openPicker("BACKDROP CHANGE INTERVAL",
      ctx.entriesOf(view.BACKDROP_INTERVALS, function(v)
        if v >= 60 then return ("%g minutes"):format(v / 60) end
        return v .. " seconds"
      end, function(v) return v end),
      cfg.backdropSeconds,
      function(value)
        cfg.backdropSeconds = value
        app.backdrop.at = os.clock()
        app:saveConfig()
        ctx.refreshRows()
      end)
  end, function() return cfg.backdrop == "cycle" and theme.text or theme.line end)

  -- The cycle is a set rather than a single choice, so the picker toggles one
  -- picture and opens itself again for the next.
  local function editBackdrops()
    local entries = {}
    for _, id in ipairs(backdrops.ids()) do
      entries[#entries + 1] = {
        label = (cfg.backdropSkip[id] and "[ ] " or "[x] ") .. backdrops.label(id),
        value = id,
      }
    end
    entries[#entries + 1] = { label = "-- done --", value = false }
    ctx.openPicker("PICTURES IN THE CYCLE", entries, nil, function(id)
      if not id then ctx.refreshRows(); return end
      local skip = cfg.backdropSkip
      skip[id] = (not skip[id]) or nil
      -- Refuse to empty the cycle: backdrops.rotation papers over an empty set
      -- by handing back one picture, so the count has to be taken from the
      -- skip list itself.
      local remaining = 0
      for _, other in ipairs(backdrops.ids()) do
        if not skip[other] then remaining = remaining + 1 end
      end
      if remaining == 0 then
        skip[id] = nil
        root:toast("At least one picture has to stay in the cycle", "warning")
      end
      app:saveConfig()
      ctx.refreshRows()
      editBackdrops()
    end)
  end

  ctx.row("In the cycle", function()
    local rotation = backdrops.rotation(cfg)
    if #rotation == backdrops.count() then
      return ("all %d pictures"):format(#rotation)
    end
    return ("%d of %d pictures"):format(#rotation, backdrops.count())
  end, editBackdrops,
    function() return cfg.backdrop == "cycle" and theme.text or theme.line end)

  ctx.action("Show the next picture now", function()
    if cfg.backdrop ~= "cycle" then
      root:toast("Set the picture to Cycle first", "info")
      return
    end
    app.backdrop:next()
    root:toast(backdrops.label(app.backdrop:id()), "info")
  end)
  ctx.spacer()
end

view.readoutRows = readoutRows
view.sceneHeight = sceneHeight

return view
