-- Live Outline: the pure part (no events, no UI).
--
-- An "outline layer" is a normal layer that carries the extension property `config`. Its cels are rebuilt from
-- the layers above it: the union of their opaque pixels is dilated ring by ring, from the inside out. Each ring
-- has a width (1..MAX_WIDTH px) and a corner matrix like Aseprite's own Outline command (the 8 neighbours of a
-- pixel, see M.kernel). With the default "Round" matrix width 1 is the plus shape and width 2 the 5x5 square
-- minus its 4 corners, the same pixels as the first version of the extension.
-- The cel image is rewritten through `image.bytes`, which writes the pixels directly and creates NO undo step,
-- so Ctrl+Z keeps undoing only what the artist drew.

local M = {}

M.KEY = "sglmnaz/live-outline"   -- publisher/name from package.json
M.DEFAULT_NAME = "Outline (live)"

M.MAX_RINGS = 10
M.MAX_WIDTH = 64

M.SOURCES = { "above", "next" }
M.SOURCE_LABELS = { above = "All visible layers above", next = "First layer above only" }

-- Corner matrices: 9 chars, row by row from the top-left neighbour; the 5th (the pixel itself) is always "0".
M.ROUND = "010101010"
M.MASKS = {
  { name = "Round", mask = M.ROUND },
  { name = "Square", mask = "111101111" },
  { name = "Horizontal", mask = "000101000" },
  { name = "Vertical", mask = "010000010" },
}

function M.maskName(mask)
  for _, m in ipairs(M.MASKS) do
    if m.mask == mask then return m.name end
  end
  return "Custom"
end

function M.normalizeMask(mask)
  if type(mask) ~= "string" or #mask ~= 9 or not mask:match("^[01]+$") then return M.ROUND end
  return mask:sub(1, 4) .. "0" .. mask:sub(6, 9)
end

function M.clampWidth(w)
  w = math.floor(tonumber(w) or 1)
  if w < 1 then return 1 end
  if w > M.MAX_WIDTH then return M.MAX_WIDTH end
  return w
end

function M.defaultConfig()
  return { rings = { { hex = "000000", w = 1, mask = M.ROUND } }, source = "above" }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Kernels

local function sign(v)
  if v > 0 then return 1 elseif v < 0 then return -1 end
  return 0
end

local function cellOn(mask, sx, sy)
  local i = (sy + 1) * 3 + sx + 2
  return mask:sub(i, i) == "1"
end

-- The offsets one ring of width `w` adds around a pixel, for corner matrix `mask`:
--   * a side neighbour (up/down/left/right) that is on adds its arm, `w` px long;
--   * a corner neighbour that is on fills its whole quadrant (a w x w square);
--   * a corner neighbour that is off, between two side neighbours that are on, fills its quadrant rounded:
--     dx^2 + dy^2 <= w^2 + w - 1 (nothing at width 1, the 5x5-minus-corners shape at width 2).
-- At width 1 this is exactly Aseprite's Outline matrix.
-- `closed` = every offset, stepped once towards the origin, is the origin or another offset. Then only the edge
-- pixels of the shape can add anything, which makes big shapes cheap (see computeFrame).
local kernelCache = {}
function M.kernel(w, mask)
  local key = w .. ":" .. mask
  local k = kernelCache[key]
  if k then return k end
  local offsets, set = {}, {}
  local r2 = w * w + w - 1
  for dy = -w, w do
    for dx = -w, w do
      if dx ~= 0 or dy ~= 0 then
        local sx, sy = sign(dx), sign(dy)
        local on
        if sx == 0 or sy == 0 then
          on = cellOn(mask, sx, sy)
        elseif cellOn(mask, sx, sy) then
          on = true
        else
          on = cellOn(mask, sx, 0) and cellOn(mask, 0, sy) and dx * dx + dy * dy <= r2
        end
        if on then
          offsets[#offsets + 1] = { dx, dy }
          set[dx .. "," .. dy] = true
        end
      end
    end
  end
  local closed = true
  for _, o in ipairs(offsets) do
    local bx, by = o[1] - sign(o[1]), o[2] - sign(o[2])
    if (bx ~= 0 or by ~= 0) and not set[bx .. "," .. by] then
      closed = false
      break
    end
  end
  k = { offsets = offsets, closed = closed }
  kernelCache[key] = k
  return k
end

-- ---------------------------------------------------------------------------------------------------------------
-- Config  "080808:2,ff00ff:10:111101111|above"   (hex:width[:corner matrix], no matrix = Round)

function M.parseConfig(s)
  if type(s) ~= "string" then return nil end
  local ringsPart, source = s:match("^([^|]*)|?(%a*)$")
  if not ringsPart then return nil end
  local cfg = { rings = {}, source = (source == "next") and "next" or "above" }
  for item in ringsPart:gmatch("[^,]+") do
    local hex, w, mask = item:match("^(%x+):(%d+):?([01]*)$")
    if hex and (#hex == 6 or #hex == 8) and #cfg.rings < M.MAX_RINGS then
      cfg.rings[#cfg.rings + 1] = {
        hex = hex:lower(), w = M.clampWidth(w), mask = M.normalizeMask(mask ~= "" and mask or nil),
      }
    end
  end
  if #cfg.rings == 0 then return nil end
  return cfg
end

function M.configString(cfg)
  local parts = {}
  for _, r in ipairs(cfg.rings) do
    local mask = M.normalizeMask(r.mask)
    parts[#parts + 1] = r.hex .. ":" .. M.clampWidth(r.w) .. (mask ~= M.ROUND and (":" .. mask) or "")
  end
  return table.concat(parts, ",") .. "|" .. (cfg.source or "above")
end

function M.getConfig(layer)
  if layer.isGroup then return nil end
  local ok, v = pcall(function() return layer.properties(M.KEY).config end)
  if ok and v ~= nil then return M.parseConfig(v) end
  return nil
end

function M.setConfig(layer, cfg)
  layer.properties(M.KEY).config = cfg and M.configString(cfg) or nil
end

function M.hexToRgba(hex)
  local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
  local a = (#hex >= 8) and tonumber(hex:sub(7, 8), 16) or 255
  return r, g, b, a
end

function M.rgbToHex(r, g, b)
  return string.format("%02x%02x%02x", r, g, b)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Layers

-- Bottom-to-top list of image layers with their effective visibility (a hidden group hides its children).
local function flatten(layers, out, parentVisible)
  for _, l in ipairs(layers) do
    local vis = parentVisible and l.isVisible
    if l.isGroup then
      flatten(l.layers, out, vis)
    else
      out[#out + 1] = { layer = l, visible = vis }
    end
  end
  return out
end

function M.outlineLayers(spr)
  local res = {}
  for _, e in ipairs(flatten(spr.layers, {}, true)) do
    local cfg = M.getConfig(e.layer)
    if cfg then res[#res + 1] = { layer = e.layer, cfg = cfg } end
  end
  return res
end

local function usableSource(l)
  return not l.isBackground and not l.isReference and not l.isTilemap and M.getConfig(l) == nil
end

-- Layers whose pixels make the silhouette: visible layers above the outline layer (other outline layers,
-- reference, tilemap and background layers never count).
function M.sourceLayers(spr, outlineLayer, cfg)
  local all = flatten(spr.layers, {}, true)
  local start
  for i, e in ipairs(all) do
    if e.layer.id == outlineLayer.id then start = i break end
  end
  local res = {}
  if not start then return res end
  for i = start + 1, #all do
    local e = all[i]
    if usableSource(e.layer) then
      if cfg.source == "next" then
        if e.visible then res[1] = e.layer end
        break
      elseif e.visible then
        res[#res + 1] = e.layer
      end
    end
  end
  return res
end

-- ---------------------------------------------------------------------------------------------------------------
-- Pixels

local function grayOf(r, g, b)
  return (r * 299 + g * 587 + b * 114) // 1000
end

local function nearestIndex(spr, r, g, b)
  local pal = spr.palettes[1]
  local best, bestD = 0, nil
  for i = 0, #pal - 1 do
    if i ~= spr.transparentColor then
      local c = pal:getColor(i)
      local d = (c.red - r) ^ 2 + (c.green - g) ^ 2 + (c.blue - b) ^ 2
      if not bestD or d < bestD then best, bestD = i, d end
    end
  end
  return best
end

-- The bytes one pixel of `hex` takes in the sprite's colour mode.
local function encode(spr, hex)
  local r, g, b, a = M.hexToRgba(hex)
  if spr.colorMode == ColorMode.RGB then
    return string.char(r, g, b, a)
  elseif spr.colorMode == ColorMode.GRAY then
    return string.char(grayOf(r, g, b), a)
  else
    return string.char(nearestIndex(spr, r, g, b))
  end
end

local function encodeTransparent(spr)
  if spr.colorMode == ColorMode.RGB then return "\0\0\0\0"
  elseif spr.colorMode == ColorMode.GRAY then return "\0\0"
  else return string.char(spr.transparentColor) end
end

-- Set of opaque canvas pixels (index y*W+x+1) in `frameNumber` over all source layers.
local function silhouette(spr, sources, frameNumber)
  local W, H = spr.width, spr.height
  local solid = {}
  local mode = spr.colorMode
  local tIdx = spr.transparentColor
  local byte = string.byte
  for _, src in ipairs(sources) do
    local cel = src:cel(frameNumber)
    if cel and cel.opacity > 0 then
      local img = cel.image
      local bytes, bpp, stride = img.bytes, img.bytesPerPixel, img.rowStride
      local px, py = cel.position.x, cel.position.y
      local iw, ih = img.width, img.height
      for y = 0, ih - 1 do
        local cy = py + y
        if cy >= 0 and cy < H then
          local row = y * stride
          local base = cy * W + 1
          for x = 0, iw - 1 do
            local cx = px + x
            if cx >= 0 and cx < W then
              local o = row + x * bpp + 1
              local opaque
              if mode == ColorMode.RGB then opaque = byte(bytes, o + 3) > 0
              elseif mode == ColorMode.GRAY then opaque = byte(bytes, o + 1) > 0
              else opaque = byte(bytes, o) ~= tIdx end
              if opaque then solid[base + cx] = true end
            end
          end
        end
      end
    end
  end
  return solid
end

-- -> string of W*H pixels for the outline cel of `frameNumber`, and whether any ring pixel was drawn.
function M.computeFrame(spr, outlineLayer, cfg, frameNumber)
  local W, H = spr.width, spr.height
  local cur = silhouette(spr, M.sourceLayers(spr, outlineLayer, cfg), frameNumber)
  local ringOf = {}
  local any = false
  for r, ring in ipairs(cfg.rings) do
    local k = M.kernel(M.clampWidth(ring.w), M.normalizeMask(ring.mask))
    local kern, closed = k.offsets, k.closed
    local added = {}
    for idx in pairs(cur) do
      local i0 = idx - 1
      local x, y = i0 % W, i0 // W
      -- With a closed kernel only edge pixels can reach outside: a pixel whose 8 neighbours are all solid adds
      -- nothing that a neighbour wouldn't (one step towards the target + another kernel offset reaches it).
      local edge = not closed or x == 0 or y == 0 or x == W - 1 or y == H - 1
        or not (cur[idx - 1] and cur[idx + 1] and cur[idx - W] and cur[idx + W]
          and cur[idx - W - 1] and cur[idx - W + 1] and cur[idx + W - 1] and cur[idx + W + 1])
      for k = 1, edge and #kern or 0 do
        local nx, ny = x + kern[k][1], y + kern[k][2]
        if nx >= 0 and nx < W and ny >= 0 and ny < H then
          local n = ny * W + nx + 1
          if not cur[n] then added[n] = true end
        end
      end
    end
    for n in pairs(added) do
      cur[n] = true
      ringOf[n] = r
      any = true
    end
  end

  local T = encodeTransparent(spr)
  local enc = {}
  for r, ring in ipairs(cfg.rings) do enc[r] = encode(spr, ring.hex) end
  -- Runs of transparent pixels in one string.rep each.
  local out, n, run = {}, 0, 0
  for i = 1, W * H do
    local r = ringOf[i]
    if r then
      if run > 0 then n = n + 1; out[n] = T:rep(run); run = 0 end
      n = n + 1; out[n] = enc[r]
    else
      run = run + 1
    end
  end
  if run > 0 then n = n + 1; out[n] = T:rep(run) end
  return table.concat(out), any
end

-- Rebuilds one frame of one outline layer.
--   structural = may create/replace the cel (an undoable step). Never pass true while an undo/redo is replaying,
--   or the redo stack would be cut.
-- -> true when pixels changed.
function M.updateFrame(spr, outlineLayer, cfg, frameNumber, structural)
  local W, H = spr.width, spr.height
  local bytes, any = M.computeFrame(spr, outlineLayer, cfg, frameNumber)
  local cel = outlineLayer:cel(frameNumber)
  local fits = cel and cel.image.width == W and cel.image.height == H
    and cel.position.x == 0 and cel.position.y == 0
    and cel.image.rowStride * H == #bytes
  if not fits then
    if not structural or (not cel and not any) then return false end
    spr:newCel(outlineLayer, frameNumber, Image(W, H, spr.colorMode), Point(0, 0))
    cel = outlineLayer:cel(frameNumber)
    if not (cel and cel.image.rowStride * H == #bytes) then return false end
  end
  if cel.image.bytes == bytes then return false end
  cel.image.bytes = bytes
  return true
end

return M
