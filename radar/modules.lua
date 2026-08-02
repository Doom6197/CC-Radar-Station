-- The module registry: what a page is, and how one gets found.
--
-- A module is a single file in radar/modules/ that returns one descriptor
-- table. It owns a page, whatever settings that page needs, whatever hardware
-- it wants to claim, and whatever background work keeps it fed -- and nothing
-- outside the file needs editing to add one. Dropping a .lua file into
-- radar/modules/ on the computer adds a page the next time the station starts.
--
-- Every page ships as a module, including the ones that were built in before
-- v7, so there is one mechanism rather than a core set plus an add-on set that
-- drift apart.
--
--   DESCRIPTOR
--   ----------
--   id        string    unique; the page id, the settings key, the file name
--   title     string    tab label on a wide screen
--   short     string    three-letter tab label on a narrow one
--   order     number    position in the tab strip; built-ins leave gaps of 10
--   summary   string    one line, shown in the module picker
--
--   core      boolean   cannot be switched off (status and settings)
--   monitor   boolean   may be shown on a monitor; false = terminal only
--   default   boolean   enabled on a fresh install when no profile says
--                       otherwise. Defaults to true.
--
--   defaults  table     merged into the settings file, at the root
--   sanitise  function(cfg)          forces its own keys back into range
--   discover  function(kit)          claims peripherals off kit.peripherals
--   attach    function(app)          one-time setup; hangs state off app
--   start     function(app)          background loops, as Basalt schedules
--   settings  function(ctx)          its own section of the settings page
--   build     function(box, app, root) -> view    builds the page
--   keys      table     { [keys.x] = { hint = , run = function(app, root) } }
--
-- Everything except `id` is optional. A module with no `build` is a service
-- rather than a page: it can still claim hardware, add settings and run loops
-- without ever appearing in the tab strip.

local modules = {}

-- Loaded first, in this order, so the tab strip is stable whatever the disk
-- hands back. Anything else found in radar/modules/ follows them.
modules.BUILT_IN = {
  "status", "radar", "contacts", "weather", "power", "log", "settings",
}

modules.list  = {}     -- descriptors, in display order
modules.index = {}     -- id -> descriptor

-- Where load() looks for extra modules. radar.lua points this at the folder it
-- is running from, so the station finds its own modules whether it was started
-- by name, by path or from startup.
modules.dir = "radar/modules"

local DEFAULT_ORDER = 100

-- ------------------------------------------------------------- registering ---

--- Adds one descriptor. Re-registering an id replaces it, which is what lets a
--- pack override a shipped module by dropping a file of the same name in.
function modules.register(descriptor)
  if type(descriptor) ~= "table" or type(descriptor.id) ~= "string" then
    return nil, "a module must be a table with a string id"
  end

  descriptor.title   = descriptor.title or descriptor.id:upper()
  descriptor.short   = descriptor.short or descriptor.title:sub(1, 3):upper()
  descriptor.order   = tonumber(descriptor.order) or DEFAULT_ORDER
  descriptor.core    = descriptor.core == true
  descriptor.monitor = descriptor.monitor ~= false
  descriptor.default = descriptor.default ~= false
  descriptor.page    = type(descriptor.build) == "function"

  local existing = modules.index[descriptor.id]
  if existing then
    for i, entry in ipairs(modules.list) do
      if entry.id == descriptor.id then modules.list[i] = descriptor end
    end
  else
    modules.list[#modules.list + 1] = descriptor
  end
  modules.index[descriptor.id] = descriptor

  -- Stable: equal orders keep the order they were registered in, which is what
  -- keeps a third-party module from reshuffling the built-in tabs.
  for i = 1, #modules.list do modules.list[i]._seq = modules.list[i]._seq or i end
  table.sort(modules.list, function(a, b)
    if a.order == b.order then return a._seq < b._seq end
    return a.order < b.order
  end)

  return descriptor
end

-- ---------------------------------------------------------------- loading ---

local loaded = false

--- Every module id to load: the built-ins, then anything else on disk.
--- Built-ins come first and in their declared order so the tab strip is stable
--- whatever the disk hands back; a dropped-in file follows them, alphabetically.
---@return string[] ids
function modules.scan()
  local ids, seen = {}, {}
  for _, id in ipairs(modules.BUILT_IN) do
    ids[#ids + 1] = id
    seen[id] = true
  end

  -- fs only exists in game. On the desktop -- the preview renderer and the
  -- test harness -- the built-in list is the whole set, which is exactly what
  -- makes those runs deterministic.
  if type(fs) == "table" and type(fs.list) == "function" then
    local ok, entries = pcall(fs.list, modules.dir)
    if ok and type(entries) == "table" then
      table.sort(entries)
      for _, entry in ipairs(entries) do
        local id = entry:match("^(.+)%.lua$")
        if id and not seen[id] then
          ids[#ids + 1] = id
          seen[id] = true
        end
      end
    end
  end

  return ids
end

--- Requires every module file and registers what it returns.
--- Idempotent, and guarded against re-entry: a module file that requires
--- radar.config, which asks the registry for its defaults, must not set the
--- loader going a second time.
---@return table failures { { id = , error = } , ... }
function modules.load()
  if loaded then return modules.failures or {} end
  loaded = true

  local failures = {}
  for _, id in ipairs(modules.scan()) do
    local ok, result = pcall(require, "radar.modules." .. id)
    if not ok then
      failures[#failures + 1] = { id = id, error = tostring(result) }
    elseif type(result) == "table" then
      -- A module returning a descriptor is registered here; one that called
      -- modules.register() itself has already done it.
      if result.id and not modules.index[result.id] then
        modules.register(result)
      elseif not result.id and not modules.index[id] then
        result.id = id
        modules.register(result)
      end
    end
  end

  -- A broken third-party module must not take the station down with it, so the
  -- failure is collected and reported rather than thrown.
  modules.failures = failures
  return failures
end

function modules.all()
  modules.load()
  return modules.list
end

function modules.byId(id)
  modules.load()
  return modules.index[id]
end

-- ---------------------------------------------------------------- enabling ---
-- Disabled modules are stored as a set of what is left OUT, exactly as the
-- backdrop cycle and a monitor's page rotation are, so a module added in a
-- later version turns up rather than silently staying dark.

function modules.isEnabled(cfg, id)
  local entry = modules.byId(id)
  if not entry then return false end
  if entry.core then return true end
  local off = type(cfg) == "table" and cfg.modulesOff or nil
  return not (type(off) == "table" and off[id])
end

--- Every enabled module, in order.
function modules.enabled(cfg)
  local out = {}
  for _, entry in ipairs(modules.all()) do
    if modules.isEnabled(cfg, entry.id) then out[#out + 1] = entry end
  end
  return out
end

--- Page ids for the terminal: every enabled module that draws something.
function modules.pages(cfg)
  local out = {}
  for _, entry in ipairs(modules.enabled(cfg)) do
    if entry.page then out[#out + 1] = entry.id end
  end
  return out
end

--- Page ids a monitor may show. Settings is deliberately absent: a monitor has
--- no keyboard, so a page that is nothing but text inputs is no use on one.
function modules.monitorPages(cfg)
  local out = {}
  for _, entry in ipairs(modules.enabled(cfg)) do
    if entry.page and entry.monitor then out[#out + 1] = entry.id end
  end
  return out
end

function modules.isPage(cfg, id)
  local entry = modules.byId(id)
  return entry ~= nil and entry.page and modules.isEnabled(cfg, id)
end

-- ------------------------------------------------------------- delegation ---
-- Each of these walks the registry and lets every module have its say. The
-- callers -- config, hardware, app -- therefore never name a module.

--- Deep copy, so a module's declared defaults are a template rather than the
--- live settings table. Handing the descriptor's own table out would mean the
--- first station to change a setting silently rewrote the default for every
--- later call, and a value the operator had never seen would come back as
--- "the default" the next time anything asked.
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

--- Settings keys every module wants, merged into one table.
function modules.defaults()
  local out = {}
  for _, entry in ipairs(modules.all()) do
    if type(entry.defaults) == "table" then
      for key, value in pairs(entry.defaults) do out[key] = copy(value) end
    end
  end
  return out
end

modules.copy = copy

--- Lets every module force its own settings back into range.
function modules.sanitise(cfg)
  for _, entry in ipairs(modules.all()) do
    if type(entry.sanitise) == "function" then pcall(entry.sanitise, cfg) end
  end

  -- Only real, non-core module ids may sit in the disabled set.
  local off = {}
  if type(cfg.modulesOff) == "table" then
    for id, disabled in pairs(cfg.modulesOff) do
      local entry = modules.index[id]
      if disabled and entry and not entry.core then off[id] = true end
    end
  end
  cfg.modulesOff = off
  return cfg
end

--- Lets every module claim whatever peripherals it needs off the kit.
function modules.discover(kit)
  for _, entry in ipairs(modules.all()) do
    if type(entry.discover) == "function" then pcall(entry.discover, kit) end
  end
  return kit
end

--- One-time setup, after the app exists but before anything is drawn.
function modules.attach(app)
  for _, entry in ipairs(modules.all()) do
    if type(entry.attach) == "function" then
      local ok, err = pcall(entry.attach, app)
      if not ok then app.moduleError = entry.id .. ": " .. tostring(err) end
    end
  end
end

--- Starts one module's background loops, at most once for the life of the
--- station. Tracked on the app rather than on the descriptor, because the
--- descriptor is shared and the flag is not: a loop is bound to the app whose
--- `running` flag it watches.
---@return boolean started True when this call is what started it
function modules.startOne(app, id)
  local entry = modules.byId(id)
  if not entry or type(entry.start) ~= "function" then return false end
  if not app.startedModules then return false end
  if app.startedModules[id] then return false end
  if not modules.isEnabled(app.cfg, id) then return false end

  app.startedModules[id] = true
  local ok, err = pcall(entry.start, app)
  if not ok then app.moduleError = id .. ": " .. tostring(err) end
  return ok
end

--- Background loops. Called from app:start(), so basalt.schedule is available
--- and sleep() is legal inside whatever a module starts.
function modules.start(app)
  app.startedModules = app.startedModules or {}
  for _, entry in ipairs(modules.all()) do
    modules.startOne(app, entry.id)
  end
end

--- Extra keyboard shortcuts, module id kept with each so the help list can say
--- where a key came from.
function modules.keys(cfg)
  local out = {}
  for _, entry in ipairs(modules.enabled(cfg)) do
    if type(entry.keys) == "table" then
      for key, action in pairs(entry.keys) do
        out[#out + 1] = { key = key, action = action, module = entry.id }
      end
    end
  end
  return out
end

return modules
