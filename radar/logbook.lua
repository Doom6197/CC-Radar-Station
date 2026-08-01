-- Detection history and the visitor statistics derived from it.
-- Newest entry first; the tail is trimmed so the file cannot grow forever.

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

--- Records a contact. Called once per player, when they first appear.
function logbook:add(contact)
  local zone = theme.zoneFor(contact.dist)
  table.insert(self.entries, 1, {
    time = timestamp(),
    name = contact.name,
    dist = util.round(contact.dist),
    zone = zone,
    dir  = util.directionOf(contact.dx, contact.dz),
    dim  = contact.dim,
  })
  while #self.entries > config.MAX_LOG_ENTRIES do
    table.remove(self.entries)
  end
  self:save()
end

function logbook:clear()
  self.entries = {}
  self:save()
end

function logbook:count() return #self.entries end

function logbook:save() config.saveLog(self.entries) end

--- Visitor totals, most frequent first.
---@return table[] rows { name, count, lastSeen, closest }
function logbook:stats()
  local counts, lastSeen, closest = {}, {}, {}
  for _, e in ipairs(self.entries) do
    counts[e.name] = (counts[e.name] or 0) + 1
    -- Entries are newest first, so the first one wins.
    if not lastSeen[e.name] then lastSeen[e.name] = e.time end
    local d = e.dist or math.huge
    if not closest[e.name] or d < closest[e.name] then closest[e.name] = d end
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
