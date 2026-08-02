--[[
  RADAR STATION v6  --  Basalt edition
  CC: Tweaked + Advanced Peripherals, Minecraft 1.21.1

  A player radar with a live weather and sky display, built on the Basalt 2.5
  UI framework, that can also run as a paired BASE on the ground and SHIP in
  the air.

  ---------------------------------------------------------------------------
  HARDWARE
  ---------------------------------------------------------------------------
    REQUIRED
      Advanced Computer  (advanced, for colour)
      Player Detector    (Advanced Peripherals) adjacent, or on a wired modem
                         network shared with the computer.
                         NOT needed in the SHIP role -- a ship is fed by its
                         base and carries no detector at all.

    OPTIONAL
      Environment Detector (Advanced Peripherals)
                         unlocks the WEATHER page: live sky, biome scenery,
                         time of day, moon phase and light levels
      Wireless or ender modem
                         needed by the BASE and SHIP roles. Ender is the one
                         to use: no range limit, and it crosses dimensions.
      Advanced Monitor(s)
                         any size; each monitor shows its own page
      Speaker(s)         every speaker on the network plays the alert
      Any redstone contraption on a side of the computer

  ---------------------------------------------------------------------------
  INSTALL
  ---------------------------------------------------------------------------
    wget run https://raw.githubusercontent.com/Doom6197/cc-radar-station/main/install.lua

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
    L          lock / unlock the scope orientation
    T          toggle FIXED / SELF tracking
    A          mute or unmute alerts
    P          test the alert sound
    N          ignore the nearest contact
    B          set the base to your current position
    C          clear the log
    Q          quit

    Mouse and monitor taps work everywhere. Right-clicking a monitor moves it
    to the next page, and a monitor can cycle its pages on a timer -- both are
    set up under Settings / Displays.

  ---------------------------------------------------------------------------
  NOTES
  ---------------------------------------------------------------------------
    ROTATION only turns the picture, so a monitor can hang on any wall with
    "up" matching the way you face. Distances and the N/NE/E labels stay true
    compass bearings.

    ORIENTATION can instead be UNLOCKED, so the scope turns with you and the
    top of the picture is whatever you are looking at. That reads your yaw,
    which needs your username set. Press L, or use Settings / Orientation.

    SCENERY on the weather page comes from the biome the Environment Detector
    reports: terrain, plants and colours all follow it, and the Nether and the
    End vary by sub-biome too. A pack whose biome the station reads wrongly
    can force one under Settings / Environment / Scenery.

    BACKDROPS replace that picture with one chosen by hand -- floating isles,
    a cloud sea, an airship under way -- which owes nothing to the weather,
    the biome or the hour, and needs no Environment Detector at all. Pick one,
    or set it to cycle through a chosen set on a timer, under
    Settings / Backdrop. The readout below the picture and the badge in the
    header keep reporting the real sky either way.

    FIXED vs SELF: getPlayersInRange() is always centred on the Player
    Detector BLOCK. FIXED changes only what distances are measured FROM, so
    put the detector at the base and point the base coordinates at it.

    ROLES. A ship assembled by Create: Aeronautics is a contraption rather
    than world blocks, so getPlayersInRange() aboard one returns nothing while
    it flies. getPlayerPos(name) is an entity lookup and keeps working, so a
    BASE on the ground -- in SELF mode, centred on the pilot -- sees everyone
    around them wherever they are, and relays that over rednet to a SHIP.
    A SHIP needs only a modem: no Player Detector, no GPS. Pick the role and
    pair the two under Settings / Link. STATION is the default and never
    touches the network.

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
  print("Radar Station v6 needs Basalt 2.5.")
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

-- A SHIP draws what its base relays and needs no detector of its own, so the
-- hard stop below only applies to a station that has to do its own scanning.
if not app.kit.detector and not config.isShip(app.cfg) then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("No Player Detector found.")
  print("")
  print("Place an Advanced Peripherals Player Detector")
  print("next to this computer, or connect one with a")
  print("wired modem, then run radar again.")
  print("")
  print("A radar aboard a Create: Aeronautics ship wants")
  print("the SHIP role instead - see Settings / Link.")
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
if not app.kit.env and not config.isShip(app.cfg) then
  terminalRoot:toast("No Environment Detector - weather page is idle", "warning")
end
if config.usesNetwork(app.cfg) then
  local summary, healthy = app.link:summary(app.cfg)
  terminalRoot:toast(summary, healthy and "info" or "warning")
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
