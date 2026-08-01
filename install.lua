--[[
  RADAR STATION v4  --  installer

  Run this on a CC: Tweaked computer:

    wget run https://raw.githubusercontent.com/JeffDoom/cc-radar-station/main/install.lua

  It fetches the file list from manifest.txt, downloads everything into memory,
  and only then writes to disk -- so a dropped connection leaves the computer
  exactly as it was rather than half installed. Running it again updates in
  place.

  Options (all optional, in any order):

    <owner>/<repo>   install from a different repository or fork
    <branch>         install from a branch other than main
    --dir <path>     install somewhere other than the current directory
    --no-basalt      skip the Basalt check
    --startup        also write a startup file that launches the radar

  Examples:

    wget run <url>                       -- normal install
    wget run <url> --startup             -- and start on boot
    wget run <url> someone/their-fork    -- from a fork
    wget run <url> dev --dir /apps       -- dev branch into /apps
]]

local DEFAULT_REPO   = "JeffDoom/cc-radar-station"
local DEFAULT_BRANCH = "main"
local BASALT_URL     = "https://basalt.madefor.cc/2.5/install.lua"

-- ------------------------------------------------------------- arguments ---

local options = {
  repo = DEFAULT_REPO,
  branch = DEFAULT_BRANCH,
  dir = shell and shell.dir() or "",
  basalt = true,
  startup = false,
}

do
  local argv = { ... }
  local index = 1
  while index <= #argv do
    local arg = argv[index]
    if arg == "--dir" then
      index = index + 1
      options.dir = argv[index] or options.dir
    elseif arg == "--no-basalt" then
      options.basalt = false
    elseif arg == "--startup" then
      options.startup = true
    elseif arg:find("/", 1, true) then
      options.repo = arg
    elseif not arg:match("^%-%-") then
      options.branch = arg
    end
    index = index + 1
  end
end

local BASE = ("https://raw.githubusercontent.com/%s/%s/"):format(options.repo, options.branch)

-- --------------------------------------------------------------- printing ---

local function say(text, color)
  if term.isColor() then term.setTextColor(color or colors.white) end
  print(text)
  if term.isColor() then term.setTextColor(colors.white) end
end

local function fail(text, detail)
  say("")
  say("Install failed: " .. text, colors.red)
  if detail then say(detail, colors.lightGray) end
  say("Nothing was written.", colors.lightGray)
  error("", 0)
end

--- One-line progress bar that redraws in place.
local function progress(done, total, label)
  local width = term.getSize()
  local _, y = term.getCursorPos()
  term.setCursorPos(1, y)
  term.clearLine()
  local barWidth = math.max(4, math.min(20, width - 26))
  local filled = math.floor(barWidth * done / math.max(1, total) + 0.5)
  if term.isColor() then term.setTextColor(colors.lightGray) end
  term.write("[" .. string.rep("=", filled) .. string.rep(" ", barWidth - filled) .. "] ")
  if term.isColor() then term.setTextColor(colors.white) end
  term.write(label:sub(1, math.max(0, width - barWidth - 4)))
  term.setCursorPos(1, y)
end

-- --------------------------------------------------------------- download ---

if not http then
  fail("the HTTP API is disabled on this computer.",
    "Enable http in the CC: Tweaked server config, then try again.")
end

--- Fetches a URL and returns its body, or nil plus a reason.
local function fetch(path)
  -- Bust the raw.githubusercontent CDN cache so an update installs the file
  -- that was just pushed rather than one up to five minutes old.
  local url = BASE .. path .. "?cc=" .. tostring(os.epoch("utc"))
  local response, reason = http.get(url, { ["Cache-Control"] = "no-cache" })
  if not response then return nil, reason or "no response" end
  local body = response.readAll()
  response.close()
  if not body or #body == 0 then return nil, "empty file" end
  return body
end

say("Radar Station v4 installer", colors.yellow)
say("  from " .. options.repo .. " (" .. options.branch .. ")", colors.lightGray)
say("  into " .. (options.dir == "" and "/" or "/" .. options.dir), colors.lightGray)
say("")

local manifest, manifestError = fetch("manifest.txt")
if not manifest then
  fail("could not read manifest.txt", "" ..
    "Checked " .. BASE .. "manifest.txt\n" ..
    "(" .. tostring(manifestError) .. ")\n" ..
    "If your GitHub username is not JeffDoom, pass your own:\n" ..
    "  wget run <url> yourname/cc-radar-station")
end

local files = {}
for line in manifest:gmatch("[^\r\n]+") do
  local path = line:match("^%s*(.-)%s*$")
  if #path > 0 and path:sub(1, 1) ~= "#" then
    files[#files + 1] = path
  end
end
if #files == 0 then fail("manifest.txt lists no files.") end

-- Everything is downloaded before anything is written.
local contents = {}
for index, path in ipairs(files) do
  progress(index - 1, #files, path)
  local body, reason = fetch(path)
  if not body then
    print("")
    fail("could not download " .. path, "(" .. tostring(reason) .. ")")
  end
  contents[path] = body
end
progress(#files, #files, "downloaded " .. #files .. " files")
print("")

-- ------------------------------------------------------------------ write ---

for _, path in ipairs(files) do
  local target = fs.combine(options.dir, path)
  local parent = fs.getDir(target)
  if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
  local handle = fs.open(target, "w")
  if not handle then fail("could not write " .. target, "Is the disk full or read only?") end
  handle.write(contents[path])
  handle.close()
end

say("Installed " .. #files .. " files.", colors.lime)

-- ----------------------------------------------------------------- basalt ---

local basaltPath = fs.combine(options.dir, "basalt.lua")
if options.basalt and not fs.exists(basaltPath) then
  say("")
  say("Basalt 2.5 is not installed here, and the radar needs it.", colors.orange)
  write("Install it now? [Y/n] ")
  local answer = read()
  if answer == nil or answer == "" or answer:lower():sub(1, 1) == "y" then
    -- The Basalt installer writes into the current directory, so run it from
    -- the target directory and put it back afterwards.
    local previous = shell.dir()
    shell.setDir(options.dir)
    shell.run("wget", "run", BASALT_URL, "minified")
    shell.setDir(previous)

    if fs.exists(basaltPath) then
      say("Basalt installed.", colors.lime)
    else
      say("Basalt does not seem to have installed. Run this yourself:", colors.red)
      say("  wget run " .. BASALT_URL .. " minified", colors.lightGray)
    end
  else
    say("Skipped. Install it before running the radar:", colors.lightGray)
    say("  wget run " .. BASALT_URL .. " minified", colors.lightGray)
  end
end

-- ---------------------------------------------------------------- startup ---

if options.startup then
  local launcher = "/" .. fs.combine(options.dir, "radar")
  local handle = fs.open("/startup.lua", "w")
  if handle then
    handle.write(('shell.run("%s")\n'):format(launcher))
    handle.close()
    say("")
    say("startup.lua will launch the radar on boot.", colors.lime)
  else
    say("Could not write /startup.lua.", colors.red)
  end
end

-- ------------------------------------------------------------------- done ---

say("")
say("Done. Start it with:", colors.yellow)
if options.dir == "" then
  say("  radar", colors.white)
else
  say("  " .. fs.combine(options.dir, "radar"), colors.white)
end
say("")
say("Or pass your base coordinates straight in:", colors.lightGray)
say("  radar 120 64 -340", colors.lightGray)
