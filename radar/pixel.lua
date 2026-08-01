-- Sub-pixel drawing surface.
--
-- ComputerCraft's font includes the teletext block characters (\128-\159),
-- which split one character cell into a 2x3 grid of sub-pixels. Two colours
-- survive per cell: the sub-pixels matching the cell background, and the rest
-- drawn in the foreground. That gives six times the resolution of plain cell
-- painting -- and because a CC glyph is 6x9 screen pixels, a 2x3 sub-pixel is
-- exactly square, so circles come out round with no aspect fudging.
--
--   local grid = pixel.new(cellWidth, cellHeight, palette)
--   grid:clear(1); grid:disc(20, 20, 6, 4)
--   grid:blitTo(renderBuffer, 1, 1)
--
-- A palette is an array of theme tones ({ c = colour handle, l = luminance }).
-- Everything is drawn by palette INDEX, so swapping palettes recolours the
-- whole picture without redrawing it.

local pixel = {}

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local char, concat = string.char, table.concat

local Grid = {}
Grid.__index = Grid

--- Creates a drawing surface covering cellW x cellH character cells.
---@param cellW number Width in character cells
---@param cellH number Height in character cells
---@param palette table[] Array of tones
---@return table grid
function pixel.new(cellW, cellH, palette)
  local self = setmetatable({
    px = {}, cellW = 0, cellH = 0, w = 0, h = 0,
    _text = {}, _fg = {}, _bg = {}, _cache = {},
  }, Grid)
  self:resize(cellW, cellH)
  self:setPalette(palette)
  return self
end

--- Resizes the surface. Cheap and idempotent when the size is unchanged, so
--- views can call it on every draw to follow their container.
function Grid:resize(cellW, cellH)
  cellW, cellH = max(1, floor(cellW)), max(1, floor(cellH))
  if self.cellW == cellW and self.cellH == cellH then return self end
  self.cellW, self.cellH = cellW, cellH
  self.w, self.h = cellW * 2, cellH * 3
  self.px = {}
  return self
end

--- Swaps the palette. Indices keep their meaning; only the colours change.
function Grid:setPalette(palette)
  if self.pal ~= palette then
    self.pal = palette
    -- Cell compilation depends on the palette's luminances, so its memo table
    -- is only valid for one palette.
    self._cache = {}
  end
  return self
end

-- ------------------------------------------------------------- primitives ---

function Grid:clear(index)
  local px, n = self.px, self.w * self.h
  for i = 1, n do px[i] = index end
  return self
end

function Grid:set(x, y, index)
  x, y = floor(x), floor(y)
  if x < 1 or y < 1 or x > self.w or y > self.h then return self end
  self.px[(y - 1) * self.w + x] = index
  return self
end

function Grid:get(x, y)
  x, y = floor(x), floor(y)
  if x < 1 or y < 1 or x > self.w or y > self.h then return nil end
  return self.px[(y - 1) * self.w + x]
end

function Grid:hline(x0, x1, y, index)
  y = floor(y)
  if y < 1 or y > self.h then return self end
  x0, x1 = max(1, floor(min(x0, x1))), min(self.w, floor(max(x0, x1)))
  local base, px = (y - 1) * self.w, self.px
  for x = x0, x1 do px[base + x] = index end
  return self
end

function Grid:vline(x, y0, y1, index)
  x = floor(x)
  if x < 1 or x > self.w then return self end
  y0, y1 = max(1, floor(min(y0, y1))), min(self.h, floor(max(y0, y1)))
  local w, px = self.w, self.px
  for y = y0, y1 do px[(y - 1) * w + x] = index end
  return self
end

function Grid:rect(x, y, w, h, index)
  for row = y, y + h - 1 do self:hline(x, x + w - 1, row, index) end
  return self
end

function Grid:line(x0, y0, x1, y1, index)
  x0, y0, x1, y1 = floor(x0), floor(y0), floor(x1), floor(y1)
  local dx, dy = abs(x1 - x0), -abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    self:set(x0, y0, index)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
  return self
end

--- Filled circle.
function Grid:disc(cx, cy, r, index)
  local r2 = r * r
  for dy = -floor(r), floor(r) do
    local span = r2 - dy * dy
    if span >= 0 then
      local dx = math.sqrt(span)
      self:hline(cx - dx, cx + dx, cy + dy, index)
    end
  end
  return self
end

--- Circle outline. Stepped by angle so large radii stay continuous.
function Grid:ring(cx, cy, r, index)
  if r < 1 then return self:set(cx, cy, index) end
  local steps = max(12, floor(r * 6.5))
  local step = 2 * math.pi / steps
  for i = 0, steps - 1 do
    local a = i * step
    self:set(cx + math.cos(a) * r, cy + math.sin(a) * r, index)
  end
  return self
end

--- Circle outline with every other arc segment skipped, for range rings that
--- should not compete with the contacts drawn on top of them.
function Grid:dashedRing(cx, cy, r, index, onLen, offLen)
  if r < 1 then return self end
  onLen, offLen = onLen or 3, offLen or 3
  local steps = max(12, floor(r * 6.5))
  local step = 2 * math.pi / steps
  local period = onLen + offLen
  for i = 0, steps - 1 do
    if i % period < onLen then
      local a = i * step
      self:set(cx + math.cos(a) * r, cy + math.sin(a) * r, index)
    end
  end
  return self
end

--- Vertical gradient over rows y0..y1 using the given palette indices in
--- order, so a three-stop sky is one call. Hard bands.
function Grid:gradient(y0, y1, indices)
  local n = #indices
  if n == 0 then return self end
  local span = y1 - y0
  for y = y0, y1 do
    local t = span == 0 and 0 or (y - y0) / span
    local band = min(n, floor(t * n) + 1)
    self:hline(1, self.w, y, indices[band])
  end
  return self
end

-- Ordered dither matrix. With only three sky colours available, hard bands
-- look like stripes; mixing the neighbouring pair across the transition reads
-- as a smooth blend at this pixel size.
local BAYER = {
  { 0, 8, 2, 10 },
  { 12, 4, 14, 6 },
  { 3, 11, 1, 9 },
  { 15, 7, 13, 5 },
}

--- Vertical gradient with the band edges dithered together.
function Grid:ditherGradient(y0, y1, indices)
  local n = #indices
  if n == 0 then return self end
  if n == 1 then return self:rect(1, y0, self.w, y1 - y0 + 1, indices[1]) end

  local span = y1 - y0
  local w, px, h = self.w, self.px, self.h
  for y = max(1, floor(y0)), min(h, floor(y1)) do
    local t = span == 0 and 0 or (y - y0) / span
    local position = t * (n - 1)
    local lo = floor(position)
    local frac = position - lo
    lo = min(n, lo + 1)
    local hi = min(n, lo + 1)
    local base = (y - 1) * w
    local row = BAYER[(y - 1) % 4 + 1]
    for x = 1, w do
      px[base + x] = frac > (row[(x - 1) % 4 + 1] / 16) and indices[hi] or indices[lo]
    end
  end
  return self
end

-- --------------------------------------------------------------- blitting ---

-- Which of the five addressable sub-pixels each bit of a teletext character
-- controls. The sixth (bottom-right) sub-pixel is always the cell background,
-- which is why it decides which of the two colours becomes the background.
local BIT = { 1, 2, 4, 8, 16 }

local vals, uniq, cnt = {}, {}, {}

--- Reduces six sub-pixel palette indices to one character plus a foreground
--- and background index. Cells with more than two colours keep the two most
--- common and snap the rest to whichever of those is closer in luminance.
local function compile(pal, v1, v2, v3, v4, v5, v6)
  vals[1], vals[2], vals[3], vals[4], vals[5], vals[6] = v1, v2, v3, v4, v5, v6

  local n = 0
  for i = 1, 6 do
    local v, seen = vals[i], false
    for j = 1, n do
      if uniq[j] == v then cnt[j] = cnt[j] + 1; seen = true; break end
    end
    if not seen then n = n + 1; uniq[n] = v; cnt[n] = 1 end
  end

  if n == 1 then return " ", v1, v1 end

  local a, b, ac, bc = nil, nil, -1, -1
  for j = 1, n do
    if cnt[j] > ac then b, bc, a, ac = a, ac, uniq[j], cnt[j]
    elseif cnt[j] > bc then b, bc = uniq[j], cnt[j] end
  end

  local la, lb = pal[a].l, pal[b].l
  local mask, pivot = 0, nil
  for i = 6, 1, -1 do
    local v = vals[i]
    local bit
    if v == a then bit = 0
    elseif v == b then bit = 1
    else
      local lv = pal[v].l
      bit = abs(lv - la) <= abs(lv - lb) and 0 or 1
    end
    if i == 6 then pivot = bit
    elseif bit ~= pivot then mask = mask + BIT[i] end
  end

  -- Sub-pixels differing from the bottom-right one are the foreground.
  if pivot == 0 then return char(128 + mask), b, a end
  return char(128 + mask), a, b
end

--- Paints the surface into a Basalt render buffer at cell (ox, oy).
--- One colorBlit per cell row: a single clipped line splice instead of one
--- write per cell, which is what makes animating a full-screen scene viable.
function Grid:blitTo(buf, ox, oy)
  local pal, px, w = self.pal, self.px, self.w
  local text, fg, bg, cache = self._text, self._fg, self._bg, self._cache
  local cellW = self.cellW

  for cy = 1, self.cellH do
    local r1 = ((cy - 1) * 3) * w
    local r2, r3 = r1 + w, r1 + w + w
    for cx = 1, cellW do
      local l = (cx - 1) * 2
      -- Falling back to index 1 keeps a drawing gap to a wrong colour rather
      -- than an error thrown from the middle of a render pass.
      local v1, v2 = px[r1 + l + 1] or 1, px[r1 + l + 2] or 1
      local v3, v4 = px[r2 + l + 1] or 1, px[r2 + l + 2] or 1
      local v5, v6 = px[r3 + l + 1] or 1, px[r3 + l + 2] or 1

      -- Memoised on the six indices packed into one integer. Scenes reuse the
      -- same combinations across large flat areas, so this hits constantly.
      local key = ((((v1 * 16 + v2) * 16 + v3) * 16 + v4) * 16 + v5) * 16 + v6
      local hit = cache[key]
      if not hit then
        local ch, f, b = compile(pal, v1, v2, v3, v4, v5, v6)
        hit = { ch, pal[f].c, pal[b].c }
        cache[key] = hit
      end
      text[cx], fg[cx], bg[cx] = hit[1], hit[2], hit[3]
    end
    buf:colorBlit(ox, oy + cy - 1, concat(text, "", 1, cellW), fg, bg)
  end
  return self
end

return pixel
