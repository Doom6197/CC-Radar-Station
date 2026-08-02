--[[
  RADAR STATION v8  --  power client

  A small program for a computer that is wired to energy hardware but is not
  the main base. It reads whatever Energy Detectors and batteries it can find
  and broadcasts the readings over rednet; the main base collects them, adds
  them to its own, graphs the lot and relays the total to every mobile.

  Run one on each computer that has meters or batteries on it. There can be as
  many as you like -- the main base merges them by computer id, so a client
  that goes quiet drops out on its own without anything needing to be told.

    wget run https://raw.githubusercontent.com/Doom6197/CC-Radar-Station/main/install.lua
    powerclient
    powerclient "Reactor room"      -- with a name the main base will show

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

  Q or Ctrl-T stops it. Add --startup when installing to have it come back up
  with the chunk.
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

-- Kept in step with radar/modules/power.lua by hand, because a client is
-- deliberately not a radar install: it loads two modules and nothing else.
local PROTOCOL = "radar_power"

local SEND_SECONDS = 2
local ANNOUNCE_EVERY = 5          -- sends between full peripheral rescans

-- ------------------------------------------------------------------ setup ---

local argv = { ... }
local clientName = argv[1]
if type(clientName) ~= "string" or #clientName == 0 then
  clientName = "Power " .. tostring(os.getComputerID and os.getComputerID() or 0)
end
clientName = clientName:sub(1, 24)

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

local kit = hardware.discover()

if not kit.modem then
  fail("No modem attached.",
    "The power client reports over rednet, so it needs\n" ..
    "a modem. A wired one is fine if the main base is\n" ..
    "on the same cable network; otherwise use wireless\n" ..
    "or ender.")
  return
end

local ok, err = pcall(rednet.open, kit.modem.name)
if not ok then
  fail("Could not open the modem.", tostring(err))
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
--- of them counts as supply and which as demand is a decision the main base
--- makes, so it can be changed in one place rather than on every client.
local function readAll()
  local list = {}
  for _, source in ipairs(sources) do
    local entry = { n = source.name, m = source.meter and 1 or nil }

    if source.meter then
      entry.r = source._rate and select(2, pcall(source._rate)) or nil
      if type(entry.r) ~= "number" then entry.r = nil end
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

-- ----------------------------------------------------------------- screen ---

local sent, lastAt, lastError = 0, nil, nil

local function draw(readings)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)

  local width, height = term.getSize()

  colour(colors.yellow)
  print("POWER CLIENT  v8")
  colour(colors.lightGray)
  print(("-"):rep(math.min(width, 40)))

  colour(colors.white)
  print("Name    " .. clientName)
  print("Modem   " .. kit.modem.name ..
    (kit.modem.wireless and "  wireless" or "  wired"))

  colour(#sources > 0 and colors.lime or colors.orange)
  print(("Devices %d"):format(#sources))

  colour(colors.lightGray)
  print(("Sent    %d  every %ds"):format(sent, SEND_SECONDS))

  if lastError then
    colour(colors.red)
    print("Error   " .. tostring(lastError))
  end

  -- Every device, so a cable that has come loose is obvious from here rather
  -- than only from the main base.
  local row = select(2, term.getCursorPos()) + 1
  colour(colors.lightGray)
  term.setCursorPos(1, row)
  print(("-"):rep(math.min(width, 40)))

  for _, entry in ipairs(readings) do
    local _, y = term.getCursorPos()
    if y >= height then break end
    local bits = {}
    if entry.r then bits[#bits + 1] = power.format(entry.r) .. "/t" end
    if entry.s and entry.c and entry.c > 0 then
      bits[#bits + 1] = ("%d%%"):format(math.floor(entry.s / entry.c * 100 + 0.5))
    end
    if #bits == 0 then bits[1] = "no reading" end
    colour(colors.white)
    write(entry.n:sub(1, math.max(4, width - 16)))
    colour(#bits == 1 and bits[1] == "no reading" and colors.red or colors.lime)
    local text = table.concat(bits, "  ")
    term.setCursorPos(math.max(1, width - #text), select(2, term.getCursorPos()))
    print(text)
  end

  colour(colors.gray)
  term.setCursorPos(1, height)
  write("Q to stop")
  colour(colors.white)
end

-- ------------------------------------------------------------------ loops ---

local running = true

local function broadcast()
  local rounds = 0
  while running do
    rounds = rounds + 1
    if rounds % ANNOUNCE_EVERY == 0 then discover() end

    local readings = readAll()
    local posted, sendError = pcall(rednet.broadcast, {
      t = "pw",
      n = clientName,
      i = SEND_SECONDS,
      s = readings,
    }, PROTOCOL)

    if posted then
      sent = sent + 1
      lastAt = os.clock()
      lastError = nil
    else
      lastError = tostring(sendError)
    end

    draw(readings)
    sleep(SEND_SECONDS)
  end
end

local function keys()
  while running do
    local _, key = os.pullEvent("key")
    if key == keys.q then running = false end
  end
end

parallel.waitForAny(broadcast, keys)

-- --------------------------------------------------------------- shutdown ---

pcall(rednet.close, kit.modem.name)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Power client stopped. Run it again any time.")
