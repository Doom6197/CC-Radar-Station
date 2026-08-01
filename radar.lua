--[[
  RADAR STATION v4  --  Basalt edition
  CC: Tweaked + Advanced Peripherals, Minecraft 1.21.1

  A stationary player radar with a live weather and sky display, built on the
  Basalt 2.5 UI framework.

  ---------------------------------------------------------------------------
  HARDWARE
  ---------------------------------------------------------------------------
    REQUIRED
      Advanced Computer  (advanced, for colour)
      Player Detector    (Advanced Peripherals) adjacent, or on a wired modem
                         network shared with the computer

    OPTIONAL
      Environment Detector (Advanced Peripherals)
                         unlocks the WEATHER page: live sky, time of day,
                         moon phase, biome and light levels
      Advanced Monitor(s)
                         any size; each monitor shows its own page
      Speaker(s)         every speaker on the network plays the alert
      Any redstone contraption on a side of the computer

  ---------------------------------------------------------------------------
  INSTALL
  ---------------------------------------------------------------------------
    wget run https://raw.githubusercontent.com/JeffDoom/cc-radar-station/main/install.lua

    That fetches every file and offers to install Basalt 2.5 too. Add
    --startup to launch the radar on boot. Then:

      radar
      radar 120 64 -340       -- with base coordinates

    By hand: install Basalt with
      wget run https://basalt.madefor.cc/2.5/install.lua minified
    then copy radar.lua and the radar/ folder next to basalt.lua.

    Settings, log and ignore list from Radar Station v3 (and from the older
    pocket build) are imported automatically on first run.

  ---------------------------------------------------------------------------
  KEYS
  ---------------------------------------------------------------------------
    1..6       jump to Status / Radar / Contacts / Weather / Log / Settings
    Left/Right previous / next page
    Up/Down    scan range up / down
    R          rotate the picture 45 degrees
    T          toggle FIXED / SELF tracking
    A          mute or unmute alerts
    P          test the alert sound
    N          ignore the nearest contact
    B          set the base to your current position
    C          clear the log
    Q          quit

    Mouse and monitor taps work everywhere. Tapping a monitor that is too
    small for a tab strip moves it to the next page.

  ---------------------------------------------------------------------------
  NOTES
  ---------------------------------------------------------------------------
    ROTATION only turns the picture, so a monitor can hang on any wall with
    "up" matching the way you face. Distances and the N/NE/E labels stay true
    compass bearings.

    FIXED vs SELF: getPlayersInRange() is always centred on the Player
    Detector BLOCK. FIXED changes only what distances are measured FROM, so
    put the detector at the base and point the base coordinates at it.

    MAX RANGE is capped by the server's "playerDetMaxRange" setting in
    advancedperipherals-server.toml. Set it to -1 for no limit.
]]

-- Modules live in radar/ next to this file. Resolving the path from the
-- running program rather than the shell's working directory means the station
-- starts the same whether it is launched by name, by path or from startup.
local programPath = shell and shell.getRunningProgram() or "radar.lua"
local programDir = fs.getDir(programPath)
local function localPath(pattern)
  return "/" .. fs.combine(programDir, pattern)
end
package.path = table.concat({
  localPath("?.lua"),
  localPath("?/init.lua"),
  package.path,
}, ";")

local ok, basalt = pcall(require, "basalt")
if not ok then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Radar Station v4 needs Basalt 2.5.")
  print("")
  print("Install it next to this program with:")
  print("  wget run https://basalt.madefor.cc/2.5/install.lua minified")
  print("")
  print("(" .. tostring(basalt) .. ")")
  return
end

local App      = require("radar.app")
local config   = require("radar.config")
local hardware = require("radar.hardware")
local ui       = require("radar.ui")

local argv = { ... }

local app = App.new()

-- Coordinates on the command line win over anything on disk.
if argv[1] and tonumber(argv[1]) then
  app.cfg.mode = "fixed"
  app.cfg.baseX = math.floor(tonumber(argv[1]))
  app.cfg.baseY = math.floor(tonumber(argv[2]) or app.cfg.baseY or 64)
  app.cfg.baseZ = math.floor(tonumber(argv[3]) or app.cfg.baseZ or 0)
  config.saveConfig(app.cfg)
end

if not app.kit.detector then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("No Player Detector found.")
  print("")
  print("Place an Advanced Peripherals Player Detector")
  print("next to this computer, or connect one with a")
  print("wired modem, then run radar again.")
  return
end

-- A brand new station has no idea where it is. Rather than a blocking wizard,
-- fall back to the detector's own position and let the operator adjust it on
-- the Settings page.
if not app.cfg.baseX then
  local placed = app:setBaseFromPosition()
  if not placed then
    app.cfg.baseX, app.cfg.baseY, app.cfg.baseZ = 0, 64, 0
    config.saveConfig(app.cfg)
  end
end

for _, monitor in ipairs(app.kit.monitors) do app:displayConfig(monitor.name) end
config.saveConfig(app.cfg)

local roots, terminalRoot = ui.build(app)
app:start()

if app.imported then
  terminalRoot:toast("Imported settings from an earlier version", "info")
end
if not app.kit.env then
  terminalRoot:toast("No Environment Detector - weather page is idle", "warning")
end

basalt.run()

-- ------------------------------------------------------------- shutdown ---

app:stop()
app.alerts:shutdown()
config.saveConfig(app.cfg)

for _, root in ipairs(roots) do
  if root.monitor then hardware.release(root.monitor, "Radar offline.") end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Radar Station stopped. Run it again any time.")
