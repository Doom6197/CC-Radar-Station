-- A 3x5 bitmap font, drawn into a radar.pixel grid.
--
-- Only what the clock needs. At scale 2 a digit is 6x10 sub-pixels, which is
-- three cells wide and a little over three tall: big enough to read a monitor
-- across the room, and it sits directly on top of the sky art.

local glyphs = {}

local FONT = {
  ["0"] = { "111", "101", "101", "101", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" },
  ["7"] = { "111", "001", "001", "001", "001" },
  ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" },
  [":"] = { "000", "010", "000", "010", "000" },
  ["."] = { "000", "000", "000", "000", "010" },
  ["-"] = { "000", "000", "111", "000", "000" },
  [" "] = { "000", "000", "000", "000", "000" },
}

glyphs.WIDTH, glyphs.HEIGHT = 3, 5

--- Width in sub-pixels of a string at the given scale, including gaps.
function glyphs.measure(text, scale)
  scale = scale or 1
  return #text * (glyphs.WIDTH + 1) * scale - scale
end

--- Draws text into a pixel grid. Returns the x just past the last glyph.
---@param grid table radar.pixel grid
---@param x number Left sub-pixel position
---@param y number Top sub-pixel position
---@param text string
---@param index number Palette index for lit pixels
---@param scale? number Pixel size multiplier, default 1
function glyphs.draw(grid, x, y, text, index, scale)
  scale = scale or 1
  local advance = (glyphs.WIDTH + 1) * scale
  for i = 1, #text do
    local rows = FONT[text:sub(i, i)]
    if rows then
      local gx = x + (i - 1) * advance
      for row = 1, glyphs.HEIGHT do
        local bits = rows[row]
        for col = 1, glyphs.WIDTH do
          if bits:sub(col, col) == "1" then
            if scale == 1 then
              grid:set(gx + col - 1, y + row - 1, index)
            else
              grid:rect(gx + (col - 1) * scale, y + (row - 1) * scale, scale, scale, index)
            end
          end
        end
      end
    end
  end
  return x + #text * advance
end

--- Draws text twice, offset by one, so it stays legible over busy artwork.
function glyphs.drawShadowed(grid, x, y, text, index, shadowIndex, scale)
  glyphs.draw(grid, x + 1, y + 1, text, shadowIndex, scale)
  glyphs.draw(grid, x, y, text, index, scale)
end

return glyphs
