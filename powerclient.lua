--[[
  RADAR STATION v8  --  power client

  A small program for a computer that is wired to energy hardware but is not
  the main base. It reads whatever Energy Detectors and batteries it can find
  and sends the readings to ONE main base; that base collects them, adds them
  to its own, graphs the lot and relays the total to every mobile.

  Run one on each computer that has meters or batteries on it. There can be as
  many as you like -- the main base merges them by computer id, so a client
  that goes quiet drops out on its own without anything needing to be told.

    wget run https://raw.githubusercontent.com/Doom6197/CC-Radar-Station/main/install.lua --client
    powerclient
    powerclient "Reactor room"      -- with a name the main base will show

  It remembers its name and which base it reports to, so both are set once.
  Press R to rename it and B to point it at a different base.

  ---------------------------------------------------------------------------
  WHY IT PAIRS
  ---------------------------------------------------------------------------
  On a shared server there may be several unrelated main bases, each with
  their own clients. A client that shouted its readings to the whole world
  would have everybody's power mixed into everybody's graph. So on first run
  it listens for main bases announcing themselves, asks which one is yours,
  and from then on addresses that computer directly -- nobody else receives
  it. "Any main base" is offered as well, for a single-player world where
  there is nothing to collide with.

  ---------------------------------------------------------------------------
  HARDWARE
  ---------------------------------------------------------------------------
    A modem                (wireless or ender to reach a base across the world,
                            wired if the base is on the same cable network)
    At least one of:
      Energy Detector      (Advanced Peripherals) inline in a cable -- rate
      Any wrappable battery -- induction matrix, energy cell, flux point:
                            stored and capacity

  This computer needs no Player Detector, no monitor and no Basalt: it is a
  sensor, not a screen. It draws a plain status readout on the terminal so you
  can see at a glance that it is being heard.

  Q stops it. Add --client when installing to have it come back up with the
  chunk.
]]

local programPath = shell and shell.getRunningProgram() or "powerclient.lua"
local programDir = fs.getDir(programPath)
package.path = table.concat({
  "/" .. fs.combine(programDir, "?.lua"),
  "/" .. fs.combine(programDir, "?/init.lua"),
  package.path,
}, ";")

local hardware = require("radar.hardware")
local power    = require("radar.power")

-- Kept in step with radar/modules/power.lua and radar/link.lua by hand,
-- because a client is deliberately not a radar install: it loads two modules
-- and nothing else.
local PROTOCOL = "radar_power"
local HELLO    = "radar_link_hello"

local SETTINGS_FILE = "powerclient.cfg"

local SEND_SECONDS = 2
local RESCAN_EVERY = 5            -- sends between full peripheral rescans
local LISTEN_SECONDS = 5          -- how long to hunt for main bases

-- ---------------------------------------------------------------- settings ---

local settings = {
  name = nil,
  baseId = nil,                   -- nil AND paired == false means "not asked yet"
  baseName = nil,
  paired = false,                 -- true once the operator has chosen
}

local function load()
  if not fs.exists(SETTINGS_FILE) then return end
  local handle = fs.open(SETTINGS_FILE, "r")
  if not handle then return end
  local raw = handle.readAll()
  handle.close()
  local ok, data = pcall(textutils.unserialize, raw)
  if not ok or type(data) ~= "table" then return end

  if type(data.name) == "string" and #data.name > 0 then
    settings.name = data.name:sub(1, 24)
  end
  settings.baseId = tonumber(data.baseId) and math.floor(data.baseId) or nil
  if type(data.baseName) == "string" and #data.baseName > 0 then
    settings.baseName = data.baseName
  end
  settings.paired = data.paired == true
end

local function save()
  local handle = fs.open(SETTINGS_FILE, "w")
  if not handle then return false end
  handle.write(textutils.serialize(settings))
  handle.close()
  return true
end

load()

local function colour(c)
  if term.isColor() then term.setTextColor(c) end
end

local function fail(message, detail)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  colour(colors.red)
  print(message)
  colour(colors.lightGray)
  if detail then print(detail) end
  colour(colors.white)
end

-- A name on the command line is a deliberate rename, so it is written down
-- rather than lasting only until the next restart.
local argv = { ... }
if type(argv[1]) == "string" and #argv[1] > 0 then
  local wanted = argv[1]:sub(1, 24)
  if wanted ~= settings.name then
    settings.name = wanted
    save()
  end
end
if not settings.name then
  settings.name = "Power " .. tostring(os.getComputerID and os.getComputerID() or 0)
end

-- ------------------------------------------------------------------ modem ---

local kit = hardware.discover()

if not kit.modem then
  fail("No modem attached.",
    "The power client reports over rednet, so it needs\n" ..
    "a modem. A wired one is fine if the main base is\n" ..
    "on the same cable network; otherwise use wireless\n" ..
    "or ender.")
  return
end

local opened, openError = pcall(rednet.open, kit.modem.name)
if not opened then
  fail("Could not open the modem.", tostring(openError))
  return
end

-- ---------------------------------------------------------------- sources ---

local sources = {}

--- Rebuilds the source list. Called on a slow cadence as well as at startup,
--- so a battery added to the wired network later is picked up without anyone
--- restarting the client.
local function discover()
  kit = hardware.discover()
  sources = {}
  for _, entry in ipairs(kit.peripherals or {}) do
    local source = power.describe(entry.name, entry.dev, entry.type)
    if source then sources[#sources + 1] = source end
  end
  return #sources
end

discover()

--- Reads every source and builds the payload. Only raw readings travel: which
--- of them counts as supply and which as demand, and what unit each is quoting
--- in, are decisions the main base makes -- so they can be changed in one
--- place rather than on every client computer.
local function readAll()
  local list = {}
  for _, source in ipairs(sources) do
    local entry = {
      n = source.name,
      m = source.meter and 1 or nil,
      -- What the peripheral's own methods suggest it is quoting. Mekanism
      -- answers in Joules whatever the client displays, and the base is where
      -- that gets converted -- this is only the opening guess.
      u = (source.guessedUnit == "j") and "j" or nil,
    }

    if source.meter then
      local rate = source._rate and select(2, pcall(source._rate)) or nil
      entry.r = type(rate) == "number" and rate or nil
      local limit = source._limitGet and select(2, pcall(source._limitGet)) or nil
      entry.l = type(limit) == "number" and limit or nil
    end

    if source.store then
      local held = source._stored and select(2, pcall(source._stored)) or nil
      local total = source._capacity and select(2, pcall(source._capacity)) or nil
      entry.s = type(held) == "number" and held or nil
      entry.c = type(total) == "number" and total or nil

      local input = source._input and select(2, pcall(source._input)) or nil
      local output = source._output and select(2, pcall(source._output)) or nil
      entry.i = type(input) == "number" and input or nil
      entry.o = type(output) == "number" and output or nil
    end

    list[#list + 1] = entry
  end
  return list
end

-- ---------------------------------------------------------------- pairing ---
-- Main bases announce themselves every few seconds on the HELLO protocol
-- whether or not anyone is listening, so finding them needs no handshake.

local heardAt = {}                -- base id -> os.clock() of its last beacon

--- Collects every main base that announces itself within `seconds`.
---@return table list { { id = , name = } , ... } sorted by name
local function listen(seconds)
  local found = {}
  local deadline = os.clock() + (seconds or LISTEN_SECONDS)
  repeat
    local left = deadline - os.clock()
    if left <= 0 then break end
    local id, message, protocol = rednet.receive(HELLO, left)
    if id and protocol == HELLO and type(message) == "table" and message.t == "h" then
      found[id] = type(message.n) == "string" and message.n or ("Computer " .. id)
      heardAt[id] = os.clock()
    end
  until false

  local list = {}
  for id, name in pairs(found) do list[#list + 1] = { id = id, name = name } end
  table.sort(list, function(a, b)
    if a.name == b.name then return a.id < b.id end
    return a.name < b.name
  end)
  return list
end

--- Asks which main base this client reports to. Blocking, and deliberately so:
--- there is nothing useful to do until it is answered.
---@return boolean chosen
local function chooseBase()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  colour(colors.yellow)
  print("POWER CLIENT  --  which main base?")
  colour(colors.lightGray)
  print(("-"):rep(40))
  print("Listening for " .. LISTEN_SECONDS .. " seconds...")
  colour(colors.white)

  local found = listen(LISTEN_SECONDS)

  print("")
  if #found == 0 then
    colour(colors.orange)
    print("No main base heard.")
    colour(colors.lightGray)
    print("Start the radar on your base computer and set")
    print("Settings / Link / Role to MAIN BASE, then press")
    print("R here to look again.")
    colour(colors.white)
    return false
  end

  for index, base in ipairs(found) do
    print(("  %d  %s   (id %d)"):format(index, base.name, base.id))
  end
  print(("  %d  Any main base   (broadcast to all)"):format(#found + 1))
  print("")
  colour(colors.lightGray)
  write("Choose 1-" .. (#found + 1) .. ": ")
  colour(colors.white)

  local answer = tonumber(read())
  if not answer then return false end

  if answer == #found + 1 then
    -- Explicitly unpaired. Fine on a world with one base; on a shared server
    -- it is how everybody's readings end up in everybody's graph.
    settings.baseId, settings.baseName = nil, nil
    settings.paired = true
  else
    local base = found[answer]
    if not base then return false end
    settings.baseId, settings.baseName = base.id, base.name
    settings.paired = true
  end
  save()
  return true
end

if not settings.paired then chooseBase() end

-- ----------------------------------------------------------------- screen ---

local sent, lastError = 0, nil
local editing = false

local function baseLabel()
  if not settings.paired then return "not chosen" end
  if not settings.baseId then return "any (broadcast)" end
  return ("%s  id %d"):format(settings.baseName or "?", settings.baseId)
end

--- Whether the paired base has been heard from lately, so a client that is
--- shouting into a void says so rather than looking healthy.
local function baseAlive()
  if not settings.baseId then return nil end
  local at = heardAt[settings.baseId]
  if not at then return false end
  return (os.clock() - at) < 30
end

local function draw(readings)
  if editing then return end

  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)

  local width, height = term.getSize()

  colour(colors.yellow)
  print("POWER CLIENT  v8")
  colour(colors.lightGray)
  print(("-"):rep(math.min(width, 40)))

  colour(colors.white)
  print("Name    " .. settings.name)

  local alive = baseAlive()
  colour(alive == false and colors.orange or colors.white)
  print("Base    " .. baseLabel())

  colour(colors.lightGray)
  print("Modem   " .. kit.modem.name ..
    (kit.modem.wireless and "  wireless" or "  wired"))

  colour(#sources > 0 and colors.lime or colors.orange)
  print(("Devices %d"):format(#sources))

  colour(colors.lightGray)
  print(("Sent    %d  every %ds"):format(sent, SEND_SECONDS))

  if alive == false then
    colour(colors.orange)
    print("        that base has not been heard lately")
  end
  if lastError then
    colour(colors.red)
    print("Error   " .. tostring(lastError))
  end

  colour(colors.lightGray)
  print(("-"):rep(math.min(width, 40)))

  -- Every device, so a cable that has come loose is obvious from here rather
  -- than only from the main base.
  for _, entry in ipairs(readings) do
    local _, y = term.getCursorPos()
    if y >= height then break end
    local bits = {}
    if entry.r then bits[#bits + 1] = power.format(entry.r) .. "/t" end
    if entry.s and entry.c and entry.c > 0 then
      bits[#bits + 1] = ("%d%%"):format(math.floor(entry.s / entry.c * 100 + 0.5))
    end
    if entry.u == "j" then bits[#bits + 1] = "J" end
    local missing = #bits == 0
    if missing then bits[1] = "no reading" end

    colour(colors.white)
    write(entry.n:sub(1, math.max(4, width - 18)))
    colour(missing and colors.red or colors.lime)
    local text = table.concat(bits, "  ")
    term.setCursorPos(math.max(1, width - #text), select(2, term.getCursorPos()))
    print(text)
  end

  colour(colors.gray)
  term.setCursorPos(1, height)
  write("R rename   B base   Q quit")
  colour(colors.white)
end

-- ------------------------------------------------------------------ loops ---

local running = true

local function post(readings)
  local payload = {
    t = "pw",
    n = settings.name,
    i = SEND_SECONDS,
    -- Which base this was meant for. Addressing already scopes it, but a
    -- broadcast client on a busy server is one setting away, and this lets a
    -- base ignore readings that were never meant for it.
    b = settings.baseId,
    s = readings,
  }

  if settings.baseId then
    return pcall(rednet.send, settings.baseId, payload, PROTOCOL)
  end
  return pcall(rednet.broadcast, payload, PROTOCOL)
end

local function broadcast()
  local rounds = 0
  while running do
    rounds = rounds + 1
    if rounds % RESCAN_EVERY == 0 then discover() end

    local readings = readAll()
    local posted, sendError = post(readings)

    if posted then
      sent = sent + 1
      lastError = nil
    else
      lastError = tostring(sendError)
    end

    draw(readings)
    sleep(SEND_SECONDS)
  end
end

--- Keeps the "is my base alive" flag honest, and picks up a rename at the far
--- end. Beacons arrive whether or not this client is paired.
local function beacons()
  while running do
    local id, message, protocol = rednet.receive(HELLO, 5)
    if id and protocol == HELLO and type(message) == "table" and message.t == "h" then
      heardAt[id] = os.clock()
      if id == settings.baseId and type(message.n) == "string"
         and message.n ~= settings.baseName then
        settings.baseName = message.n
        save()
      end
    end
  end
end

local function rename()
  editing = true
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  colour(colors.yellow)
  print("POWER CLIENT  --  rename")
  colour(colors.lightGray)
  print(("-"):rep(40))
  print("This is the name the main base shows against")
  print("these readings. Enter to keep it.")
  print("")
  colour(colors.white)
  write("Name: ")

  local answer = read(nil, nil, nil, settings.name)
  if type(answer) == "string" then
    answer = answer:match("^%s*(.-)%s*$")
    if #answer > 0 then
      settings.name = answer:sub(1, 24)
      save()
    end
  end
  editing = false
end

local function controls()
  while running do
    local _, key = os.pullEvent("key")
    if key == keys.q then
      running = false
    elseif key == keys.r then
      rename()
    elseif key == keys.b then
      editing = true
      chooseBase()
      editing = false
    end
  end
end

parallel.waitForAny(broadcast, beacons, controls)

-- --------------------------------------------------------------- shutdown ---

pcall(rednet.close, kit.modem.name)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Power client stopped. Run it again any time.")
