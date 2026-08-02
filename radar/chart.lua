-- Charts on a sub-pixel surface.
--
-- radar/pixel.lua already gives 2x3 addressable sub-pixels per character cell,
-- and a CC glyph is 6x9 screen pixels, so those sub-pixels are square. That is
-- enough resolution for a genuine line chart rather than a row of block
-- characters: on a 40x10 cell panel a graph gets 80x30 plot points, which is
-- plenty to read a trend off.
--
-- Everything here works in SUB-PIXEL coordinates and draws by palette index,
-- exactly as the rest of the pixel surface does, so a chart recolours with the
-- palette it is handed and costs no extra colour slots.
--
--   local box = { x = 1, y = 1, w = grid.w, h = grid.h }
--   chart.line(grid, box, { { values = samples, index = 4, fill = true } },
--              { count = 300, zero = true })

local chart = {}

local floor, min, max, huge = math.floor, math.min, math.max, math.huge

-- ------------------------------------------------------------------ scale ---

--- Lowest and highest value across every series, widened so a flat line does
--- not collapse to a division by zero.
---@param series table[] { { values = { number, ... } } , ... }
---@param opts? table { min = , max = , zero = boolean }
---@return number lo
---@return number hi
function chart.range(series, opts)
  opts = opts or {}
  local lo, hi = huge, -huge

  for _, entry in ipairs(series) do
    for _, value in ipairs(entry.values or {}) do
      if type(value) == "number" then
        if value < lo then lo = value end
        if value > hi then hi = value end
      end
    end
  end

  if lo == huge then lo, hi = 0, 1 end
  -- A rate chart wants the zero line on it whatever the data did, or a graph
  -- of 900..910 FE/t looks like a mountain range.
  if opts.zero then
    lo = min(lo, 0)
    hi = max(hi, 0)
  end
  if opts.min then lo = opts.min end
  if opts.max then hi = opts.max end

  if hi - lo < 1e-9 then
    local pad = max(1, math.abs(hi) * 0.1)
    lo, hi = lo - pad, hi + pad
  end
  return lo, hi
end

-- ------------------------------------------------------------- decoration ---

--- A dotted rule across the plot at one value. Used for the zero line on a
--- net-rate chart and for the alarm threshold on a buffer chart.
function chart.rule(grid, box, value, lo, hi, index, spacing)
  spacing = spacing or 3
  if value < lo or value > hi then return grid end
  local t = (value - lo) / (hi - lo)
  local y = floor(box.y + box.h - 1 - t * (box.h - 1) + 0.5)
  for x = box.x, box.x + box.w - 1, spacing do
    grid:set(x, y, index)
  end
  return grid
end

--- Faint vertical marks, so a wide graph has something to judge time against.
function chart.ticks(grid, box, count, index)
  count = count or 4
  if count < 1 or box.w < 4 then return grid end
  for i = 1, count - 1 do
    local x = floor(box.x + (box.w - 1) * i / count + 0.5)
    for y = box.y, box.y + box.h - 1, 3 do
      grid:set(x, y, index)
    end
  end
  return grid
end

-- ------------------------------------------------------------------- line ---

--- Plots one or more series into `box`.
---
--- Samples are oldest first. `opts.count` is how many slots the window holds,
--- so a partly filled history draws against the right-hand edge and grows
--- leftwards as it fills, instead of stretching a handful of readings across
--- the whole panel and implying a longer record than there is.
---
---@param grid table A radar.pixel grid
---@param box table { x, y, w, h } in sub-pixels
---@param series table[] { { values = , index = , fill = boolean } , ... }
---@param opts? table { count = , min = , max = , zero = boolean }
---@return number lo
---@return number hi
function chart.line(grid, box, series, opts)
  opts = opts or {}
  local lo, hi = chart.range(series, opts)
  if box.w < 2 or box.h < 2 then return lo, hi end

  local span = hi - lo
  local right = box.x + box.w - 1
  local bottom = box.y + box.h - 1

  -- Where the zero line sits, for the filled area under a series that can go
  -- negative. Clamped into the box so a fill always has something to sit on.
  local zeroT = (0 - lo) / span
  local zeroY = floor(bottom - min(1, max(0, zeroT)) * (box.h - 1) + 0.5)

  for _, entry in ipairs(series) do
    local values = entry.values or {}
    local n = #values
    if n > 0 then
      local slots = max(n, tonumber(opts.count) or n)
      local step = (slots > 1) and ((box.w - 1) / (slots - 1)) or 0

      local previousX, previousY = nil, nil
      for i = 1, n do
        local value = values[i]
        if type(value) == "number" then
          -- Oldest sample sits (slots - n) steps back from the right edge.
          local x = floor(right - (n - i) * step + 0.5)
          local t = (value - lo) / span
          local y = floor(bottom - min(1, max(0, t)) * (box.h - 1) + 0.5)

          if x >= box.x and x <= right then
            if entry.fill then
              grid:vline(x, zeroY, y, entry.fillIndex or entry.index)
            end

            -- Joining consecutive samples vertically is what turns a scatter of
            -- points into a line: at this resolution a busy series moves several
            -- sub-pixels between columns, and without the join it reads as
            -- speckle rather than as a trace.
            if previousX and previousY and x - previousX <= 2 then
              grid:vline(x, previousY, y, entry.index)
            end
            grid:set(x, y, entry.index)

            previousX, previousY = x, y
          end
        end
      end
    end
  end

  return lo, hi
end

-- ------------------------------------------------------------------ gauge ---

--- A horizontal bar. `fraction` is clamped, so a buffer reporting more than it
--- can hold -- which some machines do briefly -- draws full rather than
--- overrunning the panel.
function chart.gauge(grid, box, fraction, fillIndex, trackIndex)
  fraction = min(1, max(0, tonumber(fraction) or 0))
  grid:rect(box.x, box.y, box.w, box.h, trackIndex)
  local filled = floor(box.w * fraction + 0.5)
  if filled > 0 then
    grid:rect(box.x, box.y, min(filled, box.w), box.h, fillIndex)
  end
  return grid
end

--- Notch marks down a gauge, one every `every` fraction, drawn in the track
--- colour so they read against the fill and vanish against the empty part.
function chart.gaugeTicks(grid, box, every, index)
  every = every or 0.25
  local at = every
  while at < 1 do
    local x = floor(box.x + (box.w - 1) * at + 0.5)
    grid:vline(x, box.y, box.y + box.h - 1, index)
    at = at + every
  end
  return grid
end

return chart
