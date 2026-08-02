--[[
  RADAR STATION v8  --  networked edition
  CC: Tweaked + Advanced Peripherals, Minecraft 1.21.1

  A player radar with a live weather and sky display and a power monitor,
  built on the Basalt 2.5 UI framework. Every page is a MODULE: one file in
  radar/modules/ that owns its page, its settings, its hardware and its
  background loops. Drop a file in that folder and the station has a new page.

  It runs in three places, and asks which on first boot:

    MAIN BASE       the master: detectors, monitors, chunk loaded
    POCKET          carried in hand, on the move
    AIRSHIP/VEHICLE aboard something that moves

  The last two are MOBILE: a modem and a screen, drawing what the main base
  sends them. See powerclient.lua for the third program in the set -- a
  computer that only reads energy hardware and reports it.

  ---------------------------------------------------------------------------
  HARDWARE
  ---------------------------------------------------------------------------
    REQUIRED
      Advanced Computer  (advanced, for colour)
      Player Detector    (Advanced Peripherals) adjacent, or on a wired modem
                         network shared with the computer.
                         NOT needed by a MOBILE -- it is fed by the main base
                         and carries no detector at all.

    OPTIONAL
      Environment Detector (Advanced Peripherals)
                         unlocks the WEATHER page: live sky, biome scenery,
                         time of day, moon phase and light levels
      Energy Detector    (Advanced Peripherals) inline in a cable, plus any
                         directly wrappable battery -- unlocks the POWER page
      Wireless or ender modem
                         needed by the MAIN BASE and MOBILE roles. Ender is
                         the one to use: no range limit, and it crosses
                         dimensions.
      Advanced Monitor(s)
                         any size; each monitor shows its own page
      Speaker(s)         every speaker on the network plays the alert
      Any redstone contraption on a side of the computer

  ---------------------------------------------------------------------------
  INSTALL
  ---------------------------------------------------------------------------
    wget run https://raw.githubusercontent.com/Doom6197/CC-Radar-Station/main/install.lua

    That fetches every file and offers to install Basalt 2.5 too. Add
    --startup to launch the radar on boot. Then:

      radar
      radar 120 64 -340       -- with base coordinates

    By hand: install Basalt with
      wget run https://basalt.madefor.cc/2.5/install.lua minified
    then copy radar.lua and the radar/ folder next to basalt.lua.

    Settings from every earlier version are imported automatically on first
    run, and an upgrade never sees the first-boot profile chooser: the
    settings already on disk are that answer.

  ---------------------------------------------------------------------------
  KEYS
  ---------------------------------------------------------------------------
    1..9       jump to a page, in tab-strip order
    Left/Right previous / next page
    Up/Down    scan range up / down
    R          rotate the picture 45 degrees
    L          lock / unlock the scope orientation
    T          toggle FIXED / SELF tracking
    A          mute or unmute alerts
    P          test the alert sound
    N          ignore the nearest contact
    B          set the base to your current position
    C          clear the alert log
    Q          quit

    Mouse and monitor taps work everywhere. Pressing a name on the CONTACTS
    page makes them the flight destination, and pressing the destination on
    the FLIGHT page puts it back to HOME. Anywhere else, a monitor tap moves
    it to the next page, and a monitor can cycle its pages on a timer -- both
    are set up under Settings / Displays.

  ---------------------------------------------------------------------------
  NOTES
  ---------------------------------------------------------------------------
    MODULES are switched on and off under Settings / Modules. Turning one off
    removes its page, its settings section and its background polling, so a
    pocket computer is not paying for a power page it has nothing to wire to.

    PROFILES are a set of defaults, applied once. Nothing keeps enforcing one:
    after it has been applied every setting it touched is an ordinary setting.
    Change or reapply one under Settings / Profile.

    ROTATION only turns the picture, so a monitor can hang on any wall with
    "up" matching the way you face. Distances and the N/NE/E labels stay true
    compass bearings.

    ORIENTATION can instead be UNLOCKED, so the scope turns with you and the
    top of the picture is whatever you are looking at. That reads your yaw,
    which needs your username set. Press L, or use Settings / Orientation.

    SCENERY on the weather page comes from the biome the Environment Detector
    reports. A pack whose biome the station reads wrongly can force one under
    Settings / Environment / Scenery.

    BACKDROPS replace that picture with one chosen by hand, which owes nothing
    to the weather, the biome or the hour, and needs no Environment Detector
    at all. See Settings / Backdrop.

    POWER reads an Energy Detector for rate and any wrappable battery for
    stored and capacity, and graphs the last few minutes. A low buffer fires
    the ordinary alert channels, and Redstone Output / Mode / Buffer maps
    1-15 to how full the bank is.

    FIXED vs SELF: getPlayersInRange() is always centred on the Player
    Detector BLOCK. FIXED changes only what distances are measured FROM, so
    put the detector at the base and point the base coordinates at it.

    ROLES. A ship assembled by Create: Aeronautics is a contraption rather
    than world blocks, so getPlayersInRange() aboard one returns nothing while
    it flies, and there is nowhere to bolt a detector to a pocket computer at
    all. getPlayerPos(name) is an entity lookup and keeps working, so the MAIN
    BASE on the ground -- in SELF mode, centred on you -- sees everyone around
    you wherever you are, and relays that over rednet to every MOBILE. A
    MOBILE needs only a modem: no Player Detector, no GPS. Pick the role and
    pair the two under Settings / Link. STANDALONE is the fallback for a
    computer with no modem, and never touches the network.

    POWER CLIENTS. Run powerclient on any computer wired to Energy Detectors
    or batteries and it broadcasts what it reads. The MAIN BASE merges every
    client with its own hardware, graphs the total, and relays it onward, so a
    pocket computer has the power page with nothing plugged into it.

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
  print("Radar Station v8 needs Basalt 2.5.")
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
local modules  = require("radar.modules")
local setup    = require("radar.setup")
local ui       = require("radar.ui")

-- Where the registry scans for extra modules. Resolved from the folder this
-- program was launched from, so an install under /apps finds its own modules
-- rather than another copy's at the root.
modules.dir = fs.combine(programDir, "radar/modules")

local argv = { ... }

local app = App.new()

-- A computer with no settings of any vintage is a new install, and the one
-- thing it cannot work out for itself is what it is bolted to. Everything
-- after this is ordinary settings, changeable at any time.
if app.fresh then
  local chosen = setup.run(app.cfg, app.kit)
  config.sanitise(app.cfg)
  config.saveConfig(app.cfg)
  app.link:attach(app.kit, app.cfg)
  app.profileChosen = chosen
end

-- Coordinates on the command line win over anything on disk.
if argv[1] and tonumber(argv[1]) then
  app.cfg.mode = "fixed"
  app.cfg.baseX = math.floor(tonumber(argv[1]))
  app.cfg.baseY = math.floor(tonumber(argv[2]) or app.cfg.baseY or 64)
  app.cfg.baseZ = math.floor(tonumber(argv[3]) or app.cfg.baseZ or 0)
  config.saveConfig(app.cfg)
end

-- A MOBILE draws what the main base relays and needs no detector of its own,
-- so the hard stop below only applies to a station that scans for itself.
if not app.kit.detector and not config.isMobile(app.cfg) then
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
  print("A radar on a ship or a pocket computer wants")
  print("the MOBILE role instead - see Settings / Link.")
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

if app.profileChosen then
  terminalRoot:toast("Set up as " .. require("radar.profiles").label(app.profileChosen),
    "success")
elseif app.imported then
  terminalRoot:toast("Imported settings from an earlier version", "info")
end

-- A module that failed to load is reported rather than swallowed: a page
-- quietly missing is a far more confusing thing to debug than a red banner.
for _, failure in ipairs(modules.failures or {}) do
  terminalRoot:toast("Module " .. failure.id .. " failed to load", "error")
end

if not app.kit.env and not config.isMobile(app.cfg) then
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
