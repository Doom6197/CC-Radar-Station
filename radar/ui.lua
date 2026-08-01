-- The Basalt shell: one root per screen, each with a header, a tab strip and
-- a lazily built page underneath.
--
-- Basalt routes keyboard and mouse to the terminal root and monitor_touch to
-- the matching monitor root, so every screen is independently navigable: the
-- terminal can show settings while one monitor runs the radar and another
-- watches the weather.

local basalt  = require("basalt")
local config  = require("radar.config")
local theme   = require("radar.theme")
local util    = require("radar.util")
local sky     = require("radar.sky")

local ui = {}

local VIEWS = {
  radar    = require("radar.views.radar"),
  contacts = require("radar.views.contacts"),
  weather  = require("radar.views.weather"),
  log      = require("radar.views.log"),
  status   = require("radar.views.status"),
  settings = require("radar.views.settings"),
}

local PAGE_META = {
  radar    = { title = "RADAR",    short = "RDR" },
  contacts = { title = "CONTACTS", short = "CON" },
  weather  = { title = "WEATHER",  short = "WX" },
  log      = { title = "LOG",      short = "LOG" },
  status   = { title = "STATUS",   short = "SYS" },
  settings = { title = "SETTINGS", short = "SET" },
}

local TERMINAL_PAGES = { "status", "radar", "contacts", "weather", "log", "settings" }

-- Elements that swallow typing, so global shortcuts must stand down.
local TYPING = { Input = true, TextBox = true, ComboBox = true }

-- --------------------------------------------------------------- controller ---

local Root = {}
Root.__index = Root

local function pageIndex(pages, id)
  for i, page in ipairs(pages) do
    if page == id then return i end
  end
  return nil
end

--- Chooses between full titles and three-letter codes, and lays out the spans.
local function tabLayout(pages, width)
  local full = 0
  for _, id in ipairs(pages) do full = full + #PAGE_META[id].title + 2 end

  local useShort = full > width
  local spans, x = {}, 1
  for i, id in ipairs(pages) do
    local meta = PAGE_META[id]
    local label = " " .. (useShort and meta.short or meta.title) .. " "
    spans[i] = { x1 = x, x2 = x + #label - 1, label = label, id = id }
    x = x + #label
  end
  return spans
end

function Root:hasTabs()
  return self.root.height >= 6 and self.root.width >= 16
end

function Root:setPage(id, remember)
  if not self.views[id] then
    local builder = VIEWS[id]
    if not builder then return end
    local container = self.content:addFrame({
      x = 1, y = 1,
      width = function(s) return s.parent.width end,
      height = function(s) return s.parent.height end,
      background = false,
      visible = false,
    })
    local view = builder.build(container, self.app, self)
    view.container = container
    self.views[id] = view
  end

  for viewId, view in pairs(self.views) do
    view.container.visible = (viewId == id)
  end

  local previous = self.page
  self.page = id
  if previous and previous ~= id and self.views[previous] and self.views[previous].hidden then
    self.views[previous].hidden()
  end
  if self.views[id].shown then self.views[id].shown() end

  if remember ~= false then
    if self.monitor then
      self.app:displayConfig(self.monitor.name).page = id
    else
      self.app.cfg.terminalPage = id
    end
    self.app:saveConfig()
  end

  self.tabs:markRenderDirty()
  self:refreshChrome()
  self:refreshView()
end

function Root:cyclePage(step)
  local index = pageIndex(self.pages, self.page) or 1
  local next = ((index - 1 + (step or 1)) % #self.pages) + 1
  self:setPage(self.pages[next])
end

function Root:refreshView()
  local view = self.views[self.page]
  if view and view.refresh then
    local ok, err = pcall(view.refresh)
    if not ok then self.app.viewError = tostring(err) end
  end
end

--- Rebuilds the one-line status readout in the header.
function Root:refreshChrome()
  local app = self.app
  local width = self.root.width

  self.title.text = width >= 24 and "RADAR STATION" or "RADAR"

  local parts = {}
  local count = #app.contacts
  if app.scanError then
    parts[#parts + 1] = "DETECTOR FAULT"
  elseif count > 0 then
    parts[#parts + 1] = count .. (count == 1 and " CONTACT" or " CONTACTS")
  else
    parts[#parts + 1] = "ALL CLEAR"
  end

  local snap = app:snapshot()
  if snap and snap.available and width >= 34 then
    parts[#parts + 1] = snap.clock .. " " .. sky.badge(snap.scene)
  end
  if not app.cfg.alert then parts[#parts + 1] = "MUTE" end
  if app.cfg.rs.enabled and width >= 44 then parts[#parts + 1] = "RS" end

  local text = table.concat(parts, "  ")
  local room = width - #self.title.text - 3
  if #text > room then text = text:sub(1, math.max(0, room)) end

  self.status.text = text
  self.status.x = math.max(1, width - #text)
  self.status.foreground = app.scanError and theme.alarm
    or (count > 0 and theme.warn or theme.dim)
end

function Root:flash(on)
  self.overlay.visible = on and true or false
end

function Root:toast(message, kind)
  if self.toaster then self.toaster:show(message, kind or "default", 4) end
end

-- ------------------------------------------------------------------- build ---

local function buildRoot(app, rootFrame, opts)
  local self = setmetatable({
    app = app,
    root = rootFrame,
    monitor = opts.monitor,
    isTerminal = opts.monitor == nil,
    pages = opts.pages,
    views = {},
  }, Root)

  rootFrame.background = theme.bg
  rootFrame.foreground = theme.text

  -- header ------------------------------------------------------------------
  local header = rootFrame:addFrame({
    x = 1, y = 1, height = 1,
    width = function(s) return s.parent.width end,
    background = theme.panel,
  })
  self.title = header:addLabel({ x = 2, y = 1, text = "RADAR STATION", foreground = theme.accent })
  self.status = header:addLabel({ x = 2, y = 1, text = "", foreground = theme.dim })

  -- tab strip ---------------------------------------------------------------
  self.tabs = rootFrame:addCanvas({
    x = 1, height = 1,
    y = function(s) return s.parent.height end,
    width = function(s) return s.parent.width end,
    background = theme.panel,
    visible = function(s) return s.parent.height >= 6 and s.parent.width >= 16 end,
  })
  self.tabs.draw = function(canvas, buf)
    local spans = tabLayout(self.pages, canvas.width)
    self.tabSpans = spans
    buf:fill(1, 1, canvas.width, 1, " ", theme.dim, theme.panel)
    for _, span in ipairs(spans) do
      local active = (span.id == self.page)
      buf:blit(span.x1, 1, span.label,
        active and theme.bg or theme.dim,
        active and theme.accent or theme.panel)
    end
  end
  self.tabs:onClick(function(_, _, x)
    for _, span in ipairs(self.tabSpans or {}) do
      if x >= span.x1 and x <= span.x2 then
        self:setPage(span.id)
        return
      end
    end
  end)

  -- content -----------------------------------------------------------------
  self.content = rootFrame:addFrame({
    x = 1, y = 2,
    width = function(s) return s.parent.width end,
    height = function(s)
      local reserved = (s.parent.height >= 6 and s.parent.width >= 16) and 2 or 1
      return math.max(1, s.parent.height - reserved)
    end,
    background = theme.bg,
  })
  -- Without a tab strip there is nowhere to press, so a tap anywhere on a
  -- monitor moves to the next page.
  self.content:onClick(function()
    if not self:hasTabs() then self:cyclePage(1) end
  end)

  -- alert overlay -----------------------------------------------------------
  self.overlay = rootFrame:addFrame({
    x = 1, y = 1, z = 500,
    width = function(s) return s.parent.width end,
    height = function(s) return s.parent.height end,
    background = theme.alarm,
    visible = false,
  })

  if self.isTerminal then
    self.toaster = rootFrame:addToast({
      maxWidth = function(s) return math.max(12, math.min(30, s.parent.width - 4)) end,
    })
    self.toaster.toastColors = {
      default = { bg = theme.panel, fg = theme.text },
      success = { bg = theme.good,  fg = theme.bg },
      error   = { bg = theme.alarm, fg = theme.bg },
      warning = { bg = theme.warn,  fg = theme.bg },
      info    = { bg = theme.accent, fg = theme.bg },
    }
  end

  return self
end

-- ------------------------------------------------------------------- keys ---

local function focusIsTyping(root)
  local focused = root.getFocused and root:getFocused()
  return focused ~= nil and TYPING[focused.__name] == true
end

function ui.registerKeys(app, roots, terminalRoot)
  local KEY_ACTIONS = {}
  local function terminal() return terminalRoot end

  KEY_ACTIONS[keys.up]    = function() app:rangeUp() end
  KEY_ACTIONS[keys.down]  = function() app:rangeDown() end
  KEY_ACTIONS[keys.left]  = function() terminal():cyclePage(-1) end
  KEY_ACTIONS[keys.right] = function() terminal():cyclePage(1) end
  KEY_ACTIONS[keys.r]     = function() app:rotate(45) end
  KEY_ACTIONS[keys.t]     = function() app:toggleMode() end
  KEY_ACTIONS[keys.a]     = function()
    app:toggleAlerts()
    terminal():toast(app.cfg.alert and "Alerts on" or "Alerts muted",
      app.cfg.alert and "success" or "warning")
  end
  KEY_ACTIONS[keys.p]     = function()
    if #app.kit.speakers == 0 then
      terminal():toast("No speaker on the network", "error")
    else
      app.alerts:play()
    end
  end
  KEY_ACTIONS[keys.n]     = function()
    local name = app:ignoreNearest()
    terminal():toast(name and ("Ignoring " .. name) or "No contact to ignore",
      name and "info" or "warning")
  end
  KEY_ACTIONS[keys.c]     = function()
    app:clearLog()
    terminal():toast("Log cleared", "info")
  end
  KEY_ACTIONS[keys.b]     = function()
    local ok, message = app:setBaseFromPosition()
    terminal():toast(message, ok and "success" or "error")
  end

  local pageKeys = {
    [keys.one] = "status", [keys.two] = "radar", [keys.three] = "contacts",
    [keys.four] = "weather", [keys.five] = "log", [keys.six] = "settings",
  }
  for key, page in pairs(pageKeys) do
    KEY_ACTIONS[key] = function() terminal():setPage(page) end
  end

  basalt.schedule(function()
    while true do
      local _, key = os.pullEvent("key")
      if not focusIsTyping(terminalRoot.root) then
        local action = KEY_ACTIONS[key]
        if key == keys.q then
          app:stop()
          basalt.stop()
        elseif action then
          local ok, err = pcall(action)
          if not ok then terminalRoot:toast("Key error: " .. tostring(err), "error") end
        end
      end
    end
  end)
end

-- ------------------------------------------------------------------ wiring ---

--- Builds every root and connects them to the application's events.
---@return table roots
---@return table terminalRoot
function ui.build(app)
  local roots = {}

  local terminalRoot = buildRoot(app, basalt.getMainFrame(), { pages = TERMINAL_PAGES })
  roots[#roots + 1] = terminalRoot

  for _, monitor in ipairs(app.kit.monitors) do
    local displayCfg = app:displayConfig(monitor.name)
    pcall(monitor.dev.setTextScale, displayCfg.scale)
    local ok, frame = pcall(basalt.createFrame, monitor.dev, monitor.name)
    if ok and frame then
      local controller = buildRoot(app, frame, { pages = config.PAGES, monitor = monitor })
      controller:setPage(displayCfg.page, false)
      roots[#roots + 1] = controller
    end
  end

  terminalRoot:setPage(app.cfg.terminalPage, false)

  local function refreshAll()
    for _, root in ipairs(roots) do
      root:refreshChrome()
      root:refreshView()
    end
  end

  app:on("scan", refreshAll)
  app:on("env", refreshAll)
  app:on("config", refreshAll)
  app:on("log", refreshAll)
  app:on("ignore", refreshAll)

  app:on("anim", function()
    for _, root in ipairs(roots) do
      local view = root.views[root.page]
      if view and view.animate then pcall(view.animate) end
    end
  end)

  app:on("contact", function(arrivals)
    if not app.cfg.toast or #arrivals == 0 then return end
    local first = arrivals[1]
    local extra = #arrivals > 1 and (" +" .. (#arrivals - 1) .. " more") or ""
    terminalRoot:toast(string.format("%s  %s %s%s",
      util.shorten(first.name, 14), util.distanceLabel(first.dist),
      first.dir, extra), "warning")
  end)

  app.alerts.onFlash = function()
    if not app.cfg.flash then return end
    basalt.schedule(function()
      for _ = 1, 2 do
        for _, root in ipairs(roots) do root:flash(true) end
        sleep(0.12)
        for _, root in ipairs(roots) do root:flash(false) end
        sleep(0.12)
      end
    end)
  end

  ui.registerKeys(app, roots, terminalRoot)
  refreshAll()
  return roots, terminalRoot
end

ui.PAGE_META = PAGE_META

return ui
