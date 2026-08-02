-- First-boot setup: pick a profile, and say who you are.
--
-- This runs on the raw terminal before Basalt starts, for two reasons. The
-- profile decides which modules exist, and modules decide what the Basalt tree
-- is built out of, so the answer has to be in hand before there is a tree to
-- build. And it is the one screen that has to work on absolutely anything --
-- including a 26x20 pocket computer with no colour -- which is easier to
-- guarantee with term.write than with a layout engine.
--
-- It appears exactly once, on a computer with no settings file. An upgrade
-- from an earlier version never sees it: those settings are already the
-- operator's answer to the same question, and overwriting them with a profile
-- would be a poor way to say hello.

local profiles = require("radar.profiles")

local setup = {}

local function isColour()
  local ok, colour = pcall(term.isColor)
  return ok and colour
end

local function paint(fg, bg)
  if not isColour() then return end
  if fg then pcall(term.setTextColor, fg) end
  if bg then pcall(term.setBackgroundColor, bg) end
end

local function at(x, y, text, fg)
  local width = term.getSize()
  if x > width then return end
  paint(fg or colors.white)
  term.setCursorPos(x, y)
  term.write(tostring(text):sub(1, width - x + 1))
end

--- Wraps text to a width without breaking words. A local copy rather than
--- radar.util's, so this screen still draws if a later module fails to load.
local function wrap(text, width)
  local lines, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if #line == 0 then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else lines[#lines + 1] = line; line = word end
  end
  if #line > 0 then lines[#lines + 1] = line end
  return lines
end

-- ------------------------------------------------------------ the chooser ---

--- Offers the profile list until one is accepted.
---@param suggested string Profile id to start on
---@return string id
function setup.chooseProfile(suggested)
  local list = profiles.LIST
  local selected = 1
  for i, entry in ipairs(list) do
    if entry.id == suggested then selected = i end
  end

  -- Where each row landed, so a click can be turned back into a choice.
  local rows = {}

  local function draw()
    local width, height = term.getSize()
    paint(colors.white, colors.black)
    term.clear()

    local wide = width >= 34
    local y = 1

    at(1, y, "RADAR STATION v8", colors.yellow); y = y + 1
    at(1, y, ("-"):rep(math.min(width, 40)), colors.gray); y = y + 2

    at(1, y, "Where is this computer?", colors.white); y = y + 2

    rows = {}
    for i, entry in ipairs(list) do
      local active = (i == selected)
      at(1, y, active and ">" or " ", colors.cyan)
      at(3, y, i .. "  " .. entry.label, active and colors.cyan or colors.white)
      rows[#rows + 1] = { y = y, index = i }
      y = y + 1
      if wide then
        at(6, y, entry.hint, colors.gray)
        rows[#rows + 1] = { y = y, index = i }
        y = y + 1
      end
    end

    y = y + 1

    -- The blurb takes whatever is left, minus the footer.
    local room = height - y - 1
    if room > 0 then
      local shown = 0
      for _, line in ipairs(list[selected].blurb) do
        if shown >= room then break end
        if #line == 0 then
          y = y + 1; shown = shown + 1
        else
          for _, wrapped in ipairs(wrap(line, width - 2)) do
            if shown >= room then break end
            at(2, y, wrapped, colors.lightGray)
            y = y + 1; shown = shown + 1
          end
        end
      end
    end

    local footer = wide and "Up/Down or 1-3 choose    Enter accept"
                        or "Up/Dn or 1-3   Enter ok"
    at(1, height, footer, colors.gray)
    paint(colors.white, colors.black)
  end

  while true do
    draw()
    local event, a, _, clickY = os.pullEvent()

    if event == "key" then
      if a == keys.up then
        selected = ((selected - 2) % #list) + 1
      elseif a == keys.down then
        selected = (selected % #list) + 1
      elseif a == keys.enter or a == keys.numPadEnter then
        return list[selected].id
      end
    elseif event == "char" then
      local index = tonumber(a)
      if index and list[index] then
        -- A number key is unambiguous: it chooses AND accepts, so the whole
        -- screen is one keystroke for anyone who already knows the answer.
        return list[index].id
      end
    elseif event == "mouse_click" or event == "monitor_touch" then
      for _, row in ipairs(rows) do
        if row.y == clickY then
          if selected == row.index then return list[row.index].id end
          selected = row.index
        end
      end
    end
  end
end

-- ----------------------------------------------------------- the username ---

--- Asks for the operator's Minecraft name. Optional, and skipping it is a
--- perfectly good answer -- but SELF tracking and an unlocked scope both read
--- your own position, so a station without one quietly cannot do either.
---@return string|nil name
function setup.askName(profileId)
  local width, height = term.getSize()
  paint(colors.white, colors.black)
  term.clear()

  local y = 1
  at(1, y, "RADAR STATION v8", colors.yellow); y = y + 1
  at(1, y, ("-"):rep(math.min(width, 40)), colors.gray); y = y + 2

  at(1, y, "Your Minecraft username?", colors.white); y = y + 2

  local needsIt = (profileId == "pocket" or profileId == "vehicle")
  local lines = needsIt
    and {
      "This profile centres the radar on you and",
      "turns the scope with your heading. Both",
      "read your own position, so both need this.",
      "",
      "Exact and case sensitive.",
    }
    or {
      "Used to keep you off your own radar, and",
      "for SELF tracking and heading-up later.",
      "",
      "Exact and case sensitive. Optional -- press",
      "Enter to skip and set it in Settings.",
    }

  for _, line in ipairs(lines) do
    if y >= height - 2 then break end
    for _, wrapped in ipairs(wrap(line, width - 2)) do
      at(2, y, wrapped, colors.lightGray); y = y + 1
    end
    if #line == 0 then y = y + 1 - 1 end
  end

  y = math.min(y + 1, height - 1)
  at(1, y, "Name: ", colors.cyan)
  term.setCursorPos(7, y)
  paint(colors.white, colors.black)

  local ok, name = pcall(read)
  if not ok then return nil end
  name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
  return #name > 0 and name or nil
end

-- ------------------------------------------------------------------- done ---

--- Runs the whole first-boot flow and writes the result into cfg.
---@param cfg table Settings, freshly defaulted
---@param kit table Hardware, so a vehicle with no detector becomes a SHIP
---@return string profileId
function setup.run(cfg, kit)
  local suggested = profiles.suggest(kit)
  local id = setup.chooseProfile(suggested)

  local name = setup.askName(id)
  if name then cfg.myName = name end

  -- Applied after the name is known: SELF tracking and an unlocked scope are
  -- only switched on when there is a username for them to read.
  profiles.apply(cfg, id, kit)

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  return id
end

setup.wrap = wrap

return setup
