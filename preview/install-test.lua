-- Exercises install.lua against a mocked CC: Tweaked, serving the real
-- repository files off disk. Desktop only.
--
--   lua preview/install-test.lua .

local PROJ = (...) or "."

------------------------------------------------------------------ CC mocks --

colors = { white = 1, orange = 2, yellow = 16, red = 16384, lime = 32,
           lightGray = 256, gray = 128, black = 32768 }

local OUTPUT = {}
local function record(text) OUTPUT[#OUTPUT + 1] = tostring(text) end

local realPrint = print
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  record(table.concat(parts, "\t"))
end
function write(text) record(text) end

local READ_ANSWERS = {}
function read() return table.remove(READ_ANSWERS, 1) or "" end

term = {
  isColor = function() return false end,
  getSize = function() return 51, 19 end,
  getCursorPos = function() return 1, 1 end,
  setCursorPos = function() end,
  clearLine = function() end,
  write = function(text) record(text) end,
  setTextColor = function() end,
}

os.epoch = function() return 1234567890 end

-- In-memory filesystem -------------------------------------------------------

local DISK, DIRS = {}, { [""] = true }

fs = {
  combine = function(a, b)
    a = tostring(a or ""):gsub("^/+", ""):gsub("/+$", "")
    b = tostring(b or ""):gsub("^/+", "")
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
  end,
  getDir = function(path)
    return (tostring(path):match("^(.*)/[^/]*$")) or ""
  end,
  exists = function(path)
    path = tostring(path):gsub("^/+", "")
    return DISK[path] ~= nil or DIRS[path] == true
  end,
  makeDir = function(path)
    path = tostring(path):gsub("^/+", "")
    local build = nil
    for part in path:gmatch("[^/]+") do
      build = build and (build .. "/" .. part) or part
      DIRS[build] = true
    end
  end,
  open = function(path, mode)
    path = tostring(path):gsub("^/+", "")
    if mode:sub(1, 1) == "r" then
      if not DISK[path] then return nil end
      return { readAll = function() return DISK[path] end, close = function() end }
    end
    local buffer = {}
    return {
      write = function(text) buffer[#buffer + 1] = text end,
      close = function() DISK[path] = table.concat(buffer) end,
    }
  end,
}

-- Shell ----------------------------------------------------------------------

local CWD = ""
local SHELL_RUNS = {}
shell = {
  dir = function() return CWD end,
  setDir = function(path) CWD = tostring(path):gsub("^/+", "") end,
  run = function(...) SHELL_RUNS[#SHELL_RUNS + 1] = table.concat({ ... }, " ") end,
}

-- HTTP, serving the repository off disk ---------------------------------------

local SERVE_PREFIX = "https://raw.githubusercontent.com/Doom6197/CC-Radar-Station/main/"
local MISSING = {}

http = {
  get = function(url)
    local path = url:match("^" .. SERVE_PREFIX:gsub("%p", "%%%0") .. "(.-)%?") or
                 url:match("^" .. SERVE_PREFIX:gsub("%p", "%%%0") .. "(.*)$")
    if not path then return nil, "404: unknown repository or branch" end
    if MISSING[path] then return nil, "404: Not Found" end
    local file = io.open(PROJ .. "/" .. path, "rb")
    if not file then return nil, "404: Not Found" end
    local body = file:read("*a")
    file:close()
    return { readAll = function() return body end, close = function() end }
  end,
}

--------------------------------------------------------------------- tests --

local failures, checks = {}, 0
local function check(name, fn)
  checks = checks + 1
  local ok, err = pcall(fn)
  if not ok then failures[#failures + 1] = name .. "  ->  " .. tostring(err) end
end

local function reset()
  DISK, DIRS = {}, { [""] = true }
  OUTPUT, SHELL_RUNS, READ_ANSWERS, MISSING = {}, {}, {}, {}
  CWD = ""
end

local function runInstaller(...)
  local chunk = assert(loadfile(PROJ .. "/install.lua"))
  return pcall(chunk, ...)
end

local function manifestPaths()
  local file = assert(io.open(PROJ .. "/manifest.txt", "r"))
  local text = file:read("*a")
  file:close()
  local paths = {}
  for line in text:gmatch("[^\r\n]+") do
    local path = line:match("^%s*(.-)%s*$")
    if #path > 0 and path:sub(1, 1) ~= "#" then paths[#paths + 1] = path end
  end
  return paths
end

local PATHS = manifestPaths()

check("manifest lists the real files", function()
  assert(#PATHS >= 20, "at least twenty files, got " .. #PATHS)
  for _, path in ipairs(PATHS) do
    local file = io.open(PROJ .. "/" .. path, "r")
    assert(file, "manifest lists a file that does not exist: " .. path)
    file:close()
  end
end)

check("every project lua file is in the manifest", function()
  local listed = {}
  for _, path in ipairs(PATHS) do listed[path] = true end
  -- Walk what the installer must deliver: radar.lua plus radar/**.lua
  assert(listed["radar.lua"], "radar.lua is listed")
  local expected = {
    "radar/app.lua", "radar/ui.lua", "radar/config.lua", "radar/hardware.lua",
    "radar/scan.lua", "radar/environment.lua", "radar/alerts.lua",
    "radar/autopilot.lua", "radar/backdrops.lua", "radar/link.lua",
    "radar/logbook.lua",
    "radar/theme.lua", "radar/pixel.lua", "radar/chart.lua",
    "radar/glyphs.lua", "radar/sky.lua", "radar/util.lua",
    "radar/modules.lua", "radar/power.lua", "radar/profiles.lua",
    "radar/setup.lua",
    "radar/modules/status.lua", "radar/modules/radar.lua",
    "radar/modules/contacts.lua", "radar/modules/weather.lua",
    "radar/modules/alerts.lua", "radar/modules/settings.lua",
    "radar/modules/power.lua",
  }
  for _, path in ipairs(expected) do
    assert(listed[path], "manifest is missing " .. path)
  end
end)

-- A module the installer does not fetch is a page that silently does not
-- exist, which is the single easiest thing to get wrong when adding one --
-- so the registry's own built-in list is checked against the manifest rather
-- than against a second hand-written list that could drift from it.
check("every built-in module is in the manifest", function()
  local listed = {}
  for _, path in ipairs(PATHS) do listed[path] = true end

  local source = assert(io.open(PROJ .. "/radar/modules.lua", "r"))
  local text = source:read("*a")
  source:close()

  local block = text:match("BUILT_IN%s*=%s*{(.-)}")
  assert(block, "modules.lua declares a BUILT_IN list")

  local count = 0
  for id in block:gmatch('"([%w_%-]+)"') do
    count = count + 1
    assert(listed["radar/modules/" .. id .. ".lua"],
      "manifest is missing built-in module " .. id)
  end
  assert(count >= 7, "found the whole built-in list, got " .. count)
end)

check("every module file on disk is in the manifest", function()
  local listed = {}
  for _, path in ipairs(PATHS) do listed[path] = true end

  -- No directory listing in plain Lua, so the shipped set is walked by name:
  -- anything present on disk but unlisted would never reach the computer.
  local names = { "status", "radar", "contacts", "weather", "power", "alerts",
                  "flight", "settings" }
  for _, name in ipairs(names) do
    local path = "radar/modules/" .. name .. ".lua"
    local file = io.open(PROJ .. "/" .. path, "r")
    if file then
      file:close()
      assert(listed[path], path .. " exists but is not in the manifest")
    end
  end
end)

check("default install writes every file", function()
  reset()
  READ_ANSWERS = { "n" }                       -- decline the Basalt install
  local ok, err = runInstaller()
  assert(ok, "installer ran: " .. tostring(err))
  for _, path in ipairs(PATHS) do
    assert(DISK[path], "wrote " .. path)
    assert(#DISK[path] > 0, path .. " is not empty")
  end
  local source = assert(io.open(PROJ .. "/radar/sky.lua", "rb"))
  local expected = source:read("*a")
  source:close()
  assert(DISK["radar/sky.lua"] == expected, "content matches the source byte for byte")
  assert(DISK["startup.lua"] == nil, "no startup file unless asked")
end)

check("--dir installs into a subdirectory", function()
  reset()
  READ_ANSWERS = { "n" }
  local ok, err = runInstaller("--dir", "apps/radar")
  assert(ok, "installer ran: " .. tostring(err))
  assert(DISK["apps/radar/radar.lua"], "entry point placed under the target dir")
  assert(DISK["apps/radar/radar/modules/weather.lua"], "nested files follow the target dir")
  assert(DISK["radar.lua"] == nil, "nothing written at the root")
end)

check("--startup writes a launcher", function()
  reset()
  READ_ANSWERS = { "n" }
  local ok = runInstaller("--startup", "--no-basalt")
  assert(ok, "installer ran")
  assert(DISK["startup.lua"], "startup written")
  assert(DISK["startup.lua"]:find("radar", 1, true), "startup launches the radar")
end)

check("--startup points into the target directory", function()
  reset()
  local ok = runInstaller("--startup", "--no-basalt", "--dir", "apps")
  assert(ok, "installer ran")
  assert(DISK["startup.lua"]:find("apps/radar", 1, true),
    "startup points at the install dir, got " .. tostring(DISK["startup.lua"]))
end)

check("--client sets a power client up as a sensor", function()
  reset()
  local ok, err = runInstaller("--client")
  assert(ok, "installer ran: " .. tostring(err))

  -- The whole point of a client computer: it boots into the sensor, not the
  -- radar, and it never asks about a UI framework it has no use for.
  assert(DISK["startup.lua"], "a startup file was written without asking for one")
  assert(DISK["startup.lua"]:find("powerclient", 1, true),
    "which launches the client, got " .. tostring(DISK["startup.lua"]))
  assert(not DISK["startup.lua"]:find('"/radar"', 1, true), "and not the radar")
  assert(#SHELL_RUNS == 0, "Basalt was not offered")

  -- It still gets the whole install: the client reads radar/power.lua and
  -- radar/hardware.lua, and a half install would be a puzzle to debug.
  assert(DISK["powerclient.lua"], "the client program was written")
  assert(DISK["radar/power.lua"], "and the module it reads energy through")
  assert(DISK["radar/hardware.lua"], "and the one it finds peripherals with")

  local text = table.concat(OUTPUT, "\n")
  assert(text:find("powerclient", 1, true), "and it says what to run")

  -- Without --client the startup is the radar, as it always was.
  reset()
  runInstaller("--startup", "--no-basalt")
  assert(DISK["startup.lua"]:find("radar", 1, true), "the default is unchanged")
  assert(not DISK["startup.lua"]:find("powerclient", 1, true), "and is not the client")
end)

check("basalt is offered when missing and accepted", function()
  reset()
  READ_ANSWERS = { "y" }
  local ok = runInstaller()
  assert(ok, "installer ran")
  assert(#SHELL_RUNS == 1, "one shell command, got " .. #SHELL_RUNS)
  assert(SHELL_RUNS[1]:find("basalt.madefor.cc/2.5/install.lua", 1, true),
    "ran the Basalt installer, got " .. SHELL_RUNS[1])
  assert(SHELL_RUNS[1]:find("minified", 1, true), "asked for the minified build")
end)

check("basalt is skipped when already present", function()
  reset()
  DISK["basalt.lua"] = "-- already here"
  local ok = runInstaller()
  assert(ok, "installer ran")
  assert(#SHELL_RUNS == 0, "did not reinstall Basalt")
end)

check("--no-basalt skips the check entirely", function()
  reset()
  local ok = runInstaller("--no-basalt")
  assert(ok, "installer ran")
  assert(#SHELL_RUNS == 0, "no Basalt install attempted")
end)

check("a failed download writes nothing", function()
  reset()
  READ_ANSWERS = { "n" }
  MISSING["radar/sky.lua"] = true
  local ok = runInstaller()
  assert(not ok, "installer aborted")
  local wrote = 0
  for _ in pairs(DISK) do wrote = wrote + 1 end
  assert(wrote == 0, "nothing was written, found " .. wrote .. " files")
  local text = table.concat(OUTPUT, "\n")
  assert(text:find("radar/sky.lua", 1, true), "named the file that failed")
end)

check("a missing manifest explains itself", function()
  reset()
  MISSING["manifest.txt"] = true
  local ok = runInstaller()
  assert(not ok, "installer aborted")
  local text = table.concat(OUTPUT, "\n")
  assert(text:find("manifest.txt", 1, true), "mentioned the manifest")
  assert(text:find("yourname/CC%-Radar%-Station"), "explained the owner override")
end)

check("an unknown repository fails clearly", function()
  reset()
  local ok = runInstaller("someone/other-fork")
  assert(not ok, "installer aborted")
  local text = table.concat(OUTPUT, "\n")
  assert(text:find("someone/other%-fork"), "reported the repository it tried")
end)

check("branch and repo arguments are parsed", function()
  reset()
  READ_ANSWERS = { "n" }
  -- The mock only serves main from Doom6197/CC-Radar-Station, so passing them
  -- explicitly must resolve to exactly the same URLs as the defaults.
  local ok, err = runInstaller("Doom6197/CC-Radar-Station", "main")
  assert(ok, "explicit repo and branch install: " .. tostring(err))
  assert(DISK["radar.lua"], "installed")
end)

--------------------------------------------------------------------- report --

realPrint(("%d checks, %d failures"):format(checks, #failures))
for _, failure in ipairs(failures) do realPrint("  FAIL " .. failure) end
if #failures > 0 then os.exit(1) end
