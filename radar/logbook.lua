-- The alert log: what the station has had to tell you, newest first.
--
-- It started as an arrival history and is still mostly that, but a contact
-- walking into range is not the only thing worth recording -- a power buffer
-- running low is the other one, and a page listing one and not the other would
-- mean checking two places to find out what happened while you were away.
-- So an entry has a KIND: "contact" for an arrival, "alarm" for anything a
-- module raised. Entries written before v8.4 carry no kind at all and are read
-- as arrivals, which is what they were.
--
-- Every entry is also unread until it has been looked at. That is what the
-- marker in the header counts, and what viewing the page clears. It is stored
-- on the entry rather than as a running total, so a restart cannot lose track
-- of which ones had been seen.
--
-- The tail is trimmed so the file cannot grow forever.

local config = require("radar.config")
local theme  = require("radar.theme")
local util   = require("radar.util")

local logbook = {}
logbook.__index = logbook

--- In-world timestamp, e.g. "D142 09:31". os.time() is the Minecraft clock,
--- so entries read the same way as an F3 screen.
local function timestamp()
  local ok, t = pcall(textutils.formatTime, os.time(), true)
  if ok and t then return "D" .. os.day() .. " " .. t end
  return "D" .. os.day()
end

logbook.timestamp = timestamp

function logbook.new(entries)
  return setmetatable({ entries = entries or {} }, logbook)
end

--- Whether an entry is an arrival. Anything without a kind is one: that is
--- every entry in a log file written before the alarms arrived.
function logbook.isContact(entry)
  return type(entry) == "table" and (entry.kind == nil or entry.kind == "contact")
end

--- Puts a finished entry at the top and trims the tail.
function logbook:push(entry)
  table.insert(self.entries, 1, entry)
  while #self.entries > config.MAX_LOG_ENTRIES do
    table.remove(self.entries)
  end
  self:save()
  return entry
end

--- Records a contact. Called once per player, when they first appear.
function logbook:add(contact)
  return self:push({
    kind = "contact",
    time = timestamp(),
    name = contact.name,
    dist = util.round(contact.dist),
    zone = theme.zoneFor(contact.dist),
    dir  = util.directionOf(contact.dx, contact.dz),
    dim  = contact.dim,
  })
end

--- Records something a module raised the alarm about -- the power buffer
--- running low, and whatever a dropped-in module decides is worth saying.
---@param text string One line, as it will appear on the page
---@param source? string The module that raised it, for the settings page
function logbook:alarm(text, source)
  return self:push({
    kind = "alarm",
    time = timestamp(),
    text = tostring(text),
    source = source,
  })
end

function logbook:clear()
  self.entries = {}
  self:save()
end

function logbook:count() return #self.entries end

--- How many entries have not been looked at yet. This is the number the
--- marker in every screen's header is counting.
function logbook:unread()
  local n = 0
  for _, entry in ipairs(self.entries) do
    if not entry.seen then n = n + 1 end
  end
  return n
end

--- Dismisses everything unread.
---@return number cleared How many entries this actually changed
function logbook:markRead()
  local cleared = 0
  for _, entry in ipairs(self.entries) do
    if not entry.seen then
      entry.seen = true
      cleared = cleared + 1
    end
  end
  if cleared > 0 then self:save() end
  return cleared
end

function logbook:save() config.saveLog(self.entries) end

--- Visitor totals, most frequent first. Alarms are left out: they are not
--- visitors, and counting "Power low" as a caller would be nonsense.
---@return table[] rows { name, count, lastSeen, closest }
function logbook:stats()
  local counts, lastSeen, closest = {}, {}, {}
  for _, e in ipairs(self.entries) do
    if logbook.isContact(e) and e.name then
      counts[e.name] = (counts[e.name] or 0) + 1
      -- Entries are newest first, so the first one wins.
      if not lastSeen[e.name] then lastSeen[e.name] = e.time end
      local d = e.dist or math.huge
      if not closest[e.name] or d < closest[e.name] then closest[e.name] = d end
    end
  end

  local rows = {}
  for name, count in pairs(counts) do
    rows[#rows + 1] = {
      name = name, count = count,
      lastSeen = lastSeen[name], closest = closest[name],
    }
  end
  table.sort(rows, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)
  return rows
end

return logbook
