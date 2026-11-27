-- Color Reducer: the pure part (no dialog).
--
-- Reduces the colours of RGB cels to N "key" colours:
--   0. optional flattening: neighbouring pixels of very similar colour become one zone painted with ONE colour
--      already in it (no blur, shapes keep their edges); specks up to N pixels join the most similar neighbour zone;
--   1. every exact colour of the targets is counted (transparent pixels apart; optionally only pixels of flat
--      areas, so anti-aliasing / compression colours on soft edges never earn a palette entry);
--   2. colours are grouped in small RGB boxes (4/5/6 bits per channel) and averaged in OKLab, a perceptual space
--      where distance ~ how different two colours look;
--   3. fixed method: weighted k-means (k-means++ start, fixed seed = same result every time) finds the N colours;
--      the weight of a box is pixels^(1 - rare). Automatic method: k-means to 64 candidates, then Ward merging
--      until every pair is at least `dmin` apart (M.autoPalette);
--   4. optionally every key colour is snapped to the nearest colour really present in the image;
--   5. every pixel takes the nearest key colour (OKLab), optionally with ordered (Bayer) dithering;
--   6. optionally the sprite shrinks by blocks, each block taking its most present colour (M.downscale).
-- Everything is one undo step. Optionally the sprite palette is replaced and the sprite converted to Indexed with
-- exact indices.

local M = {}

local floor, byte, char, concat, huge = math.floor, string.byte, string.char, table.concat, math.huge

M.PRECISIONS = {
  { name = "Veloce (4 bit)", bits = 4 },
  { name = "Normale (5 bit)", bits = 5 },
  { name = "Fine (6 bit)", bits = 6 },
}
M.DITHERS = {
  { name = "Nessuno", n = 0 },
  { name = "Bayer 2x2", n = 2 },
  { name = "Bayer 4x4", n = 4 },
  { name = "Bayer 8x8", n = 8 },
}
M.SCOPES = {
  { name = "Cel corrente", id = "cel" },
  { name = "Tutte le cel del layer", id = "layer" },
  { name = "Tutto lo sprite", id = "sprite" },
}

function M.byName(list, name, default)
  for _, e in ipairs(list) do if e.name == name then return e end end
  return list[default or 1]
end

-- ---------------------------------------------------------------------------------------------------------------
-- sRGB <-> OKLab (Björn Ottosson, 2020)

local LIN = {}
for i = 0, 255 do
  local c = i / 255
  LIN[i] = (c <= 0.04045) and (c / 12.92) or (((c + 0.055) / 1.055) ^ 2.4)
end

local function cbrt(x)
  if x >= 0 then return x ^ (1 / 3) end
  return -((-x) ^ (1 / 3))
end

-- Weight of hue/saturation (OKLab a, b) against lightness in every distance the reducer measures. In plain
-- OKLab dark colours of different hue (dark red, dark purple, navy) are very close, so they merge; > 1 keeps them
-- apart. Set per run by M.run.
local CW = 1

function M.toLab(r, g, b)
  local lr, lg, lb = LIN[r], LIN[g], LIN[b]
  local l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
  local m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
  local s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
         (1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s) * CW,
         (0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s) * CW
end

local function to8(c)
  if c <= 0 then return 0 end
  if c >= 1 then return 255 end
  local v = (c <= 0.0031308) and (12.92 * c) or (1.055 * c ^ (1 / 2.4) - 0.055)
  v = floor(v * 255 + 0.5)
  if v < 0 then return 0 elseif v > 255 then return 255 end
  return v
end

function M.fromLab(L, A, B)
  A, B = A / CW, B / CW
  local l = L + 0.3963377774 * A + 0.2158037573 * B
  local m = L - 0.1055613458 * A - 0.0638541728 * B
  local s = L - 0.0894841775 * A - 1.2914855480 * B
  l, m, s = l * l * l, m * m * m, s * s * s
  return to8(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
         to8(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
         to8(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
end

-- ---------------------------------------------------------------------------------------------------------------
-- 0. Flattening. Pixels as one table: rgb24 when opaque (alpha >= thr), -1 when transparent. Transparent
-- pixels never take part; alpha is never changed.

local function unpackPixels(bytes, w, h, stride, thr)
  local P, i = {}, 0
  for y = 0, h - 1 do
    local row = y * stride
    for x = 0, w - 1 do
      local o = row + x * 4 + 1
      local r, g, b, a = byte(bytes, o, o + 3)
      i = i + 1
      P[i] = (a >= thr) and ((r << 16) | (g << 8) | b) or -1
    end
  end
  return P
end

local function packPixels(P, bytes, w, h, stride)
  local rows, i = {}, 0
  for y = 0, h - 1 do
    local parts = {}
    local row = y * stride
    for x = 0, w - 1 do
      local o = row + x * 4 + 1
      i = i + 1
      local v = P[i]
      if v >= 0 then
        parts[x + 1] = char((v >> 16) & 255, (v >> 8) & 255, v & 255, byte(bytes, o + 3))
      else
        parts[x + 1] = bytes:sub(o, o + 3)
      end
    end
    rows[y + 1] = concat(parts)
  end
  return concat(rows)
end

-- Zones of similar colour. Region growing in OKLab (4-neighbours): a pixel joins the zone when it is within `tol`
-- of the zone's running mean, so a zone can't creep along a gradient. Each zone is painted with its own pixel
-- closest to its mean (a colour already in the image). Zones of at most `speck` pixels then join the adjacent zone
-- (bigger than `speck`) with the most similar mean.
function M.flatten(s, alphaThr, tol, speck)
  if tol <= 0 and speck <= 0 then return nil end
  local img = s.img
  local bytes, w, h, stride = img.bytes, img.width, img.height, img.rowStride
  local P = unpackPixels(bytes, w, h, stride, alphaThr)
  local N = w * h

  local PL, PA, PB, label = {}, {}, {}, {}
  local labCache = {}
  for i = 1, N do
    local v = P[i]
    label[i] = 0
    if v >= 0 then
      local c = labCache[v]
      if not c then
        c = { M.toLab((v >> 16) & 255, (v >> 8) & 255, v & 255) }
        labCache[v] = c
      end
      PL[i], PA[i], PB[i] = c[1], c[2], c[3]
    else
      PL[i], PA[i], PB[i] = 0, 0, 0
    end
  end

  -- Grow the zones.
  local T2 = tol * tol
  local RL, RA, RB, RN = {}, {}, {}, {}
  local nr = 0
  local Q, tail = {}, 0
  local sl, sa, sb, n, ml, ma, mb = 0, 0, 0, 0, 0, 0, 0
  local function try(j)
    if label[j] == 0 and P[j] >= 0 then
      local dl, da, db = PL[j] - ml, PA[j] - ma, PB[j] - mb
      if dl * dl + da * da + db * db <= T2 then
        label[j] = nr
        sl, sa, sb, n = sl + PL[j], sa + PA[j], sb + PB[j], n + 1
        ml, ma, mb = sl / n, sa / n, sb / n
        tail = tail + 1
        Q[tail] = j
      end
    end
  end
  for i = 1, N do
    if label[i] == 0 and P[i] >= 0 then
      nr = nr + 1
      label[i] = nr
      sl, sa, sb, n = PL[i], PA[i], PB[i], 1
      ml, ma, mb = sl, sa, sb
      Q[1], tail = i, 1
      local head = 1
      while head <= tail do
        local j = Q[head]
        head = head + 1
        local x = (j - 1) % w
        if x > 0 then try(j - 1) end
        if x < w - 1 then try(j + 1) end
        if j > w then try(j - w) end
        if j + w <= N then try(j + w) end
      end
      RL[nr], RA[nr], RB[nr], RN[nr] = ml, ma, mb, n
    end
  end

  -- Specks join the most similar adjacent zone that is not a speck. But adjacent specks that look more like each
  -- other than like the zones around them are grouped first (a thin line, an outline, a small dot are chains of
  -- specks): a group bigger than `speck` is a detail and stays. Grain inside an area looks like the area, so it is
  -- not grouped and is absorbed.
  local final = {}
  for r = 1, nr do final[r] = r end
  if speck > 0 then
    local target, bestD = {}, {}
    local function consider(r, q)
      if q > 0 and q ~= r and RN[q] > speck then
        local dl, da, db = RL[r] - RL[q], RA[r] - RA[q], RB[r] - RB[q]
        local d = dl * dl + da * da + db * db
        if not bestD[r] or d < bestD[r] then bestD[r], target[r] = d, q end
      end
    end
    local function eachSpeckPixel(fn)
      for i = 1, N do
        local r = label[i]
        if r > 0 and RN[r] <= speck then fn(i, r, (i - 1) % w) end
      end
    end
    eachSpeckPixel(function(i, r, x)
      if x > 0 then consider(r, label[i - 1]) end
      if x < w - 1 then consider(r, label[i + 1]) end
      if i > w then consider(r, label[i - w]) end
      if i + w <= N then consider(r, label[i + w]) end
    end)

    local parent, gsize = {}, {}
    for r = 1, nr do
      if RN[r] <= speck then parent[r], gsize[r] = r, RN[r] end
    end
    local function find(r)
      while parent[r] ~= r do
        parent[r] = parent[parent[r]]
        r = parent[r]
      end
      return r
    end
    local function join(r, q)
      if q > 0 and q ~= r and parent[q] then
        local dl, da, db = RL[r] - RL[q], RA[r] - RA[q], RB[r] - RB[q]
        local d = dl * dl + da * da + db * db
        if (not bestD[r] or d < bestD[r]) and (not bestD[q] or d < bestD[q]) then
          local ra, rb = find(r), find(q)
          if ra ~= rb then parent[rb] = ra gsize[ra] = gsize[ra] + gsize[rb] end
        end
      end
    end
    eachSpeckPixel(function(i, r, x)
      if x < w - 1 then join(r, label[i + 1]) end
      if i + w <= N then join(r, label[i + w]) end
    end)

    for r = 1, nr do
      if parent[r] and target[r] and gsize[find(r)] <= speck then final[r] = target[r] end
    end
  end

  -- One colour per zone: its own pixel closest to its mean.
  local repD, repV = {}, {}
  for i = 1, N do
    local r = label[i]
    if r > 0 and final[r] == r then
      local dl, da, db = PL[i] - RL[r], PA[i] - RA[r], PB[i] - RB[r]
      local d = dl * dl + da * da + db * db
      if not repD[r] or d < repD[r] then repD[r], repV[r] = d, P[i] end
    end
  end
  for i = 1, N do
    local r = label[i]
    if r > 0 then P[i] = repV[final[r]] end
  end
  return packPixels(P, bytes, w, h, stride), nr
end

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Exact colours

-- sources: { { img = Image (RGB), x = sprite x of the image, y = ... } }; mask(x, y) in sprite coordinates or nil.
-- Returns count (rgb24 -> pixels) and whether some pixel is (or becomes) transparent.
-- With p.ignoreEdges only pixels of FLAT areas are counted: a pixel whose colour differs by more than EDGE from an
-- opaque 4-neighbour sits on a soft edge (anti-aliasing, blur, JPEG ringing) and its in-between colour would earn a
-- palette entry. Falls back to every pixel when flat areas are under 5% of the image.
M.EDGE = 0.04
function M.collect(sources, p, mask)
  local count, all, transparent = {}, {}, false
  local nFlat, nAll = 0, 0
  local thr = p.binaryAlpha and p.alphaThreshold or 1
  local edges = p.ignoreEdges
  local E2 = M.EDGE * M.EDGE
  local labs = {}
  local function lab(k)
    local c = labs[k]
    if not c then
      c = { M.toLab((k >> 16) & 255, (k >> 8) & 255, k & 255) }
      labs[k] = c
    end
    return c
  end
  for _, s in ipairs(sources) do
    local img = s.img
    local bytes, w, h, stride = s.bytes or img.bytes, img.width, img.height, img.rowStride
    local function keyAt(x, y)
      local o = y * stride + x * 4 + 1
      local r, g, b, a = byte(bytes, o, o + 3)
      if a < thr then return nil end
      return (r << 16) | (g << 8) | b
    end
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        if not mask or mask(x + s.x, y + s.y) then
          local k = keyAt(x, y)
          if not k then
            transparent = true
          else
            all[k] = (all[k] or 0) + 1
            nAll = nAll + 1
            local flat = true
            if edges then
              local c = lab(k)
              local function far(q)
                if not q or q == k then return false end
                local d = lab(q)
                local dl, da, db = c[1] - d[1], c[2] - d[2], c[3] - d[3]
                return dl * dl + da * da + db * db > E2
              end
              flat = not ((x > 0 and far(keyAt(x - 1, y))) or (x < w - 1 and far(keyAt(x + 1, y)))
                or (y > 0 and far(keyAt(x, y - 1))) or (y < h - 1 and far(keyAt(x, y + 1))))
            end
            if flat then
              count[k] = (count[k] or 0) + 1
              nFlat = nFlat + 1
            end
          end
        end
      end
    end
  end
  if edges and nFlat < nAll * 0.05 then return all, transparent end
  return count, transparent
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Boxes (averaged in OKLab)

function M.bins(count, keys, bits, rare)
  local shift = 8 - bits
  local exp = 1 - rare
  local idx, L, A, B, N = {}, {}, {}, {}, {}
  local n = 0
  for _, k in ipairs(keys) do
    local c = count[k]
    local r, g, b = (k >> 16) & 255, (k >> 8) & 255, k & 255
    local l, a, bb = M.toLab(r, g, b)
    local key = ((r >> shift) << (2 * bits)) | ((g >> shift) << bits) | (b >> shift)
    local i = idx[key]
    if not i then
      n = n + 1
      i = n
      idx[key] = i
      L[i], A[i], B[i], N[i] = 0, 0, 0, 0
    end
    L[i], A[i], B[i], N[i] = L[i] + l * c, A[i] + a * c, B[i] + bb * c, N[i] + c
  end
  local W = {}
  for i = 1, n do
    local c = N[i]
    L[i], A[i], B[i] = L[i] / c, A[i] / c, B[i] / c
    W[i] = c ^ exp
  end
  return { n = n, L = L, A = A, B = B, W = W, N = N }
end

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Weighted k-means

local function lcg(seed)
  local s = seed
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

function M.kmeans(bins, k, maxIter)
  local n, L, A, B, W = bins.n, bins.L, bins.A, bins.B, bins.W
  local cL, cA, cB = {}, {}, {}
  if n <= k then
    for i = 1, n do cL[i], cA[i], cB[i] = L[i], A[i], B[i] end
    return cL, cA, cB
  end

  -- k-means++: the heaviest box first, then boxes picked with probability weight * distance².
  local rnd = lcg(1)
  local first = 1
  for i = 2, n do if W[i] > W[first] then first = i end end
  cL[1], cA[1], cB[1] = L[first], A[first], B[first]
  local D = {}
  for i = 1, n do
    local dl, da, db = L[i] - cL[1], A[i] - cA[1], B[i] - cB[1]
    D[i] = dl * dl + da * da + db * db
  end
  for c = 2, k do
    local total = 0
    for i = 1, n do total = total + W[i] * D[i] end
    if total <= 0 then break end
    local target, acc, pick = rnd() * total, 0, n
    for i = 1, n do
      acc = acc + W[i] * D[i]
      if acc >= target then pick = i break end
    end
    cL[c], cA[c], cB[c] = L[pick], A[pick], B[pick]
    for i = 1, n do
      local dl, da, db = L[i] - cL[c], A[i] - cA[c], B[i] - cB[c]
      local d = dl * dl + da * da + db * db
      if d < D[i] then D[i] = d end
    end
  end
  local K = #cL

  -- Lloyd iterations.
  local assign = {}
  for iter = 1, maxIter do
    local changed = 0
    local sL, sA, sB, sW = {}, {}, {}, {}
    for c = 1, K do sL[c], sA[c], sB[c], sW[c] = 0, 0, 0, 0 end
    for i = 1, n do
      local l, a, b = L[i], A[i], B[i]
      local bi, bd = 1, huge
      for c = 1, K do
        local dl = l - cL[c]
        local d = dl * dl
        if d < bd then
          local da = a - cA[c]
          d = d + da * da
          if d < bd then
            local db = b - cB[c]
            d = d + db * db
            if d < bd then bd, bi = d, c end
          end
        end
      end
      if assign[i] ~= bi then changed = changed + 1 assign[i] = bi end
      D[i] = bd
      local w = W[i]
      sL[bi], sA[bi], sB[bi], sW[bi] = sL[bi] + l * w, sA[bi] + a * w, sB[bi] + b * w, sW[bi] + w
    end
    for c = 1, K do
      if sW[c] > 0 then
        cL[c], cA[c], cB[c] = sL[c] / sW[c], sA[c] / sW[c], sB[c] / sW[c]
      else
        -- Empty cluster: move it to the box that is worst served.
        local far, fd = 1, -1
        for i = 1, n do
          local v = W[i] * D[i]
          if v > fd then fd, far = v, i end
        end
        cL[c], cA[c], cB[c] = L[far], A[far], B[far]
        D[far] = 0
      end
    end
    if iter > 1 and changed <= n * 0.001 then break end
  end
  return cL, cA, cB
end

-- Automatic palette: as many colours as the image has DISTINCT ones. k-means over-segments to 64 candidates (square
-- root weights, so small real colours get a candidate), then Ward agglomeration merges the cheapest pair
-- (pixels_a * pixels_b / (pixels_a + pixels_b) * distance^2: two small close colours go first, two big different
-- ones last) while some pair is closer than `dmin`. A colour under MINSHARE of the pixels is merged too, but only
-- into a colour within FAR * dmin: a small colour that looks like nothing else (fangs, an eye highlight) stays.
M.MINSHARE = 0.0004
M.FAR = 2.5
function M.autoPalette(bins, dmin)
  local n, L, A, B, N = bins.n, bins.L, bins.A, bins.B, bins.N
  local Wsq, total = {}, 0
  for i = 1, n do Wsq[i] = N[i] ^ 0.5 total = total + N[i] end
  local cL, cA, cB = M.kmeans({ n = n, L = L, A = A, B = B, W = Wsq }, 64, 30)
  local K = #cL
  local SL, SA, SB, SN = {}, {}, {}, {}
  for c = 1, K do SL[c], SA[c], SB[c], SN[c] = 0, 0, 0, 0 end
  for i = 1, n do
    local bi, bd = 1, huge
    for c = 1, K do
      local dl, da, db = L[i] - cL[c], A[i] - cA[c], B[i] - cB[c]
      local d = dl * dl + da * da + db * db
      if d < bd then bd, bi = d, c end
    end
    local w = N[i]
    SL[bi], SA[bi], SB[bi], SN[bi] = SL[bi] + L[i] * w, SA[bi] + A[i] * w, SB[bi] + B[i] * w, SN[bi] + w
  end
  local C = {}
  for c = 1, K do
    if SN[c] > 0 then C[#C + 1] = { L = SL[c] / SN[c], A = SA[c] / SN[c], B = SB[c] / SN[c], n = SN[c] } end
  end
  local D2 = dmin * dmin
  local F2 = D2 * M.FAR * M.FAR
  local small = M.MINSHARE * total
  while #C > 1 do
    local bi, bj, bc = nil, nil, huge
    for i = 1, #C do
      local ci = C[i]
      for j = i + 1, #C do
        local cj = C[j]
        local dl, da, db = ci.L - cj.L, ci.A - cj.A, ci.B - cj.B
        local d = dl * dl + da * da + db * db
        if d < D2 or ((ci.n < small or cj.n < small) and d < F2) then
          local cost = ci.n * cj.n / (ci.n + cj.n) * d
          if cost < bc then bc, bi, bj = cost, i, j end
        end
      end
    end
    if not bi then break end
    local p, q = C[bi], C[bj]
    local m = p.n + q.n
    C[bi] = { L = (p.L * p.n + q.L * q.n) / m, A = (p.A * p.n + q.A * q.n) / m, B = (p.B * p.n + q.B * q.n) / m, n = m }
    table.remove(C, bj)
  end
  cL, cA, cB = {}, {}, {}
  for i, c in ipairs(C) do cL[i], cA[i], cB[i] = c.L, c.A, c.B end
  return cL, cA, cB
end

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Palette

local function nearest(PL, PA, PB, K, l, a, b)
  local bi, bd = 1, huge
  for c = 1, K do
    local dl = l - PL[c]
    local d = dl * dl
    if d < bd then
      local da = a - PA[c]
      d = d + da * da
      if d < bd then
        local db = b - PB[c]
        d = d + db * db
        if d < bd then bd, bi = d, c end
      end
    end
  end
  return bi
end

-- Returns { { r, g, b, L, A, B } } sorted dark to light, no duplicates.
function M.palette(keys, cL, cA, cB, snap)
  local pal, seen = {}, {}
  local function add(r, g, b)
    local k = (r << 16) | (g << 8) | b
    if seen[k] then return end
    seen[k] = true
    local l, a, bb = M.toLab(r, g, b)
    pal[#pal + 1] = { r = r, g = g, b = b, L = l, A = a, B = bb }
  end
  if snap then
    -- Nearest colour really in the image, each one used once.
    local kl, ka, kb = {}, {}, {}
    for i, k in ipairs(keys) do kl[i], ka[i], kb[i] = M.toLab((k >> 16) & 255, (k >> 8) & 255, k & 255) end
    local used = {}
    for c = 1, #cL do
      local bi, bd = nil, huge
      for i = 1, #keys do
        if not used[i] then
          local dl, da, db = kl[i] - cL[c], ka[i] - cA[c], kb[i] - cB[c]
          local d = dl * dl + da * da + db * db
          if d < bd then bd, bi = d, i end
        end
      end
      if bi then
        used[bi] = true
        local k = keys[bi]
        add((k >> 16) & 255, (k >> 8) & 255, k & 255)
      end
    end
  else
    for c = 1, #cL do add(M.fromLab(cL[c], cA[c], cB[c])) end
  end
  table.sort(pal, function(x, y) return x.L < y.L end)
  return pal
end

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Mapping

function M.bayer(n)
  local m, size = { 0 }, 1
  while size < n do
    local nm, ns = {}, size * 2
    for y = 0, size - 1 do
      for x = 0, size - 1 do
        local v = m[y * size + x + 1] * 4
        nm[y * ns + x + 1] = v
        nm[y * ns + x + size + 1] = v + 2
        nm[(y + size) * ns + x + 1] = v + 3
        nm[(y + size) * ns + x + size + 1] = v + 1
      end
    end
    m, size = nm, ns
  end
  for i = 1, #m do m[i] = (m[i] + 0.5) / (n * n) - 0.5 end
  return m
end

local function clamp8(v)
  v = floor(v + 0.5)
  if v < 0 then return 0 elseif v > 255 then return 255 end
  return v
end

-- Returns the new RGBA bytes of the source and its palette indices (1-based; 0 = transparent; -1 = untouched).
function M.map(s, pal, p, mask, cache)
  local img = s.img
  local orig = img.bytes
  local bytes, w, h, stride = s.bytes or orig, img.width, img.height, img.rowStride
  local K = #pal
  local PL, PA, PB, PS = {}, {}, {}, {}
  for i, c in ipairs(pal) do
    PL[i], PA[i], PB[i] = c.L, c.A, c.B
    PS[i] = char(c.r, c.g, c.b, 255)
  end
  local CLEAR = char(0, 0, 0, 0)
  local binary = p.binaryAlpha
  local thr = binary and p.alphaThreshold or 1
  local n = p.dither or 0
  local bay = n > 0 and M.bayer(n) or nil
  local spread = (p.ditherStrength or 0) * 255 / (K ^ (1 / 3))
  local rows, idx = {}, {}
  local ii = 0
  for y = 0, h - 1 do
    local parts = {}
    local row = y * stride
    local by = n > 0 and ((y + s.y) % n) * n or 0
    for x = 0, w - 1 do
      local o = row + x * 4 + 1
      ii = ii + 1
      if mask and not mask(x + s.x, y + s.y) then
        parts[x + 1] = orig:sub(o, o + 3)
        idx[ii] = -1
      else
        local r, g, b, a = byte(bytes, o, o + 3)
        if a < thr then
          parts[x + 1] = binary and CLEAR or orig:sub(o, o + 3)
          idx[ii] = 0
        else
          local key = (r << 16) | (g << 8) | b
          local ci
          if n > 0 then
            local ti = by + (x + s.x) % n
            local ck = key * 64 + ti
            ci = cache[ck]
            if not ci then
              local d = bay[ti + 1] * spread
              ci = nearest(PL, PA, PB, K, M.toLab(clamp8(r + d), clamp8(g + d), clamp8(b + d)))
              cache[ck] = ci
            end
          else
            ci = cache[key]
            if not ci then
              ci = nearest(PL, PA, PB, K, M.toLab(r, g, b))
              cache[key] = ci
            end
          end
          if binary or a == 255 then
            parts[x + 1] = PS[ci]
          else
            local c = pal[ci]
            parts[x + 1] = char(c.r, c.g, c.b, a)
          end
          idx[ii] = ci
        end
      end
    end
    rows[y + 1] = concat(parts)
  end
  return concat(rows), idx
end

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Downscale by blocks (for fake pixel art: AI images, upscaled art with soft edges)

-- idx: palette index per pixel (0 = transparent) of a w x h image. Each block x block square becomes one pixel: the
-- most frequent colour, unless a minority colour is different enough to be a detail (score = pixels * (1 + lambda *
-- distance to the majority colour): a dark nostril or a light fang wins over the face around it). Transparent wins
-- when it covers at least half the block. Returns the small idx, width, height.
function M.downscale(idx, w, h, block, pal, lambda)
  local sw, sh = w // block, h // block
  local out = {}
  local half = block * block / 2
  for by = 0, sh - 1 do
    for bx = 0, sw - 1 do
      local cnt, clear, best, bc = {}, 0, nil, -1
      for y = by * block, by * block + block - 1 do
        local row = y * w + 1
        for x = bx * block, bx * block + block - 1 do
          local c = idx[row + x]
          if c > 0 then
            local v = (cnt[c] or 0) + 1
            cnt[c] = v
            if v > bc or (v == bc and c < best) then bc, best = v, c end
          else
            clear = clear + 1
          end
        end
      end
      local o = by * sw + bx + 1
      if not best or clear >= half then
        out[o] = 0
      else
        if lambda > 0 then
          local m = pal[best]
          local bs, win = -1, best
          for c, v in pairs(cnt) do
            local e = pal[c]
            local dl, da, db = e.L - m.L, e.A - m.A, e.B - m.B
            local sc = v * (1 + lambda * math.sqrt(dl * dl + da * da + db * db))
            if sc > bs or (sc == bs and c < win) then bs, win = sc, c end
          end
          best = win
        end
        out[o] = best
      end
    end
  end
  return out, sw, sh
end

local function idxToBytes(idx, w, h, pal)
  local PS = {}
  for i, c in ipairs(pal) do PS[i] = char(c.r, c.g, c.b, 255) end
  local CLEAR = char(0, 0, 0, 0)
  local rows = {}
  for y = 0, h - 1 do
    local parts = {}
    for x = 0, w - 1 do
      local c = idx[y * w + x + 1]
      parts[x + 1] = (c > 0) and PS[c] or CLEAR
    end
    rows[y + 1] = concat(parts)
  end
  return concat(rows)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Targets and the whole operation

local function usable(layer)
  return layer and layer.isImage and not layer.isTilemap and not layer.isReference and layer.isEditable
end

-- Cels to process (linked cels once). Returns cels or nil + message.
function M.targets(spr, scope, layer, frame)
  local cels = {}
  if scope == "cel" then
    if not usable(layer) then return nil, "Il layer corrente non è modificabile (bloccato, gruppo, tilemap o riferimento)." end
    local cel = layer:cel(frame)
    if not cel then return nil, "Nessuna cel nel frame corrente di questo layer." end
    cels[1] = cel
  else
    local list
    if scope == "layer" then
      if not usable(layer) then return nil, "Il layer corrente non è modificabile (bloccato, gruppo, tilemap o riferimento)." end
      list = layer.cels
    else
      list = spr.cels
    end
    local seen = {}
    for _, cel in ipairs(list) do
      if usable(cel.layer) then
        local id = cel.image.id
        if not seen[id] then seen[id] = true cels[#cels + 1] = cel end
      end
    end
    if #cels == 0 then return nil, "Nessuna cel modificabile (i layer bloccati vengono saltati)." end
  end
  return cels
end

-- p: method ("auto" | "fixed"), colors (fixed), dmin (auto, OKLab distance), scope, hue (chroma weight, 1 = plain
--    OKLab), ignoreEdges, flatten (OKLab tolerance, 0 = off), speck (pixels, 0 = off), bits, rare (0..1, fixed),
--    snap, dither (0/2/4/8), ditherStrength (0..1), binaryAlpha, alphaThreshold (0..255), block (1 = keep size),
--    detail (lambda of the downscale, 0 = plain majority), setPalette, toIndexed.
-- Returns { before = colours, after = colours, seconds, width, height } or nil + message.
function M.run(spr, p, layer, frame)
  if spr.colorMode ~= ColorMode.RGB then return nil, "Lo sprite deve essere in RGB." end
  local cels, err = M.targets(spr, p.scope, layer, frame)
  if not cels then return nil, err end
  local block = math.max(1, math.floor(p.block or 1))
  local sel = spr.selection
  local hasSel = sel and not sel.isEmpty
  if block > 1 then
    if hasSel then return nil, "Con la riduzione di dimensione togli prima la selezione (Ctrl+D)." end
    if spr.width // block < 1 or spr.height // block < 1 then return nil, "Blocco più grande dello sprite." end
  end

  local t0 = os.clock()
  CW = p.hue or 1
  local sources = {}
  for i, cel in ipairs(cels) do
    local img = cel.image
    if block > 1 then
      -- Work on the whole canvas so the block grid is the sprite's grid.
      local full = Image(spr.width, spr.height, ColorMode.RGB)
      full:drawImage(img, cel.position)
      sources[i] = { img = full, x = 0, y = 0, cel = cel }
    else
      sources[i] = { img = img, x = cel.position.x, y = cel.position.y, cel = cel }
    end
    if sources[i].img.rowStride ~= sources[i].img.width * 4 then return nil, "Formato immagine inatteso." end
  end
  local mask
  if hasSel then
    mask = function(x, y) return sel:contains(x, y) end
  end

  local thr = p.binaryAlpha and p.alphaThreshold or 1
  for _, s in ipairs(sources) do s.bytes = M.flatten(s, thr, p.flatten or 0, p.speck or 0) end

  local count = M.collect(sources, p, mask)
  local keys = sortedKeys(count)
  if #keys == 0 then return nil, "Nessun pixel opaco da ridurre." end

  -- In Indexed one index is the transparent colour, unless the sprite is a single background layer.
  local reserve = not (#spr.layers == 1 and spr.layers[1].isBackground)
  local maxK = (p.toIndexed and reserve) and 255 or 256

  local cL, cA, cB
  if p.method == "auto" then
    local bins = M.bins(count, keys, p.bits, 0)
    cL, cA, cB = M.autoPalette(bins, p.dmin or 0.06)
    if #cL > maxK then cL, cA, cB = M.kmeans(bins, maxK, 30) end
  else
    local k = math.max(1, math.min(p.colors, maxK))
    cL, cA, cB = M.kmeans(M.bins(count, keys, p.bits, p.rare), k, 30)
  end
  local pal = M.palette(keys, cL, cA, cB, p.snap)

  local mp = p
  if block > 1 then
    mp = {}
    for k, v in pairs(p) do mp[k] = v end
    mp.dither = 0
  end
  local cache, results = {}, {}
  for i, s in ipairs(sources) do
    local bytes, idx = M.map(s, pal, mp, mask, cache)
    if block > 1 then
      local sidx, sw, sh = M.downscale(idx, s.img.width, s.img.height, block, pal, p.detail or 0)
      results[i] = { bytes = idxToBytes(sidx, sw, sh, pal), w = sw, h = sh }
    else
      results[i] = { bytes = bytes }
    end
  end

  app.transaction("Riduci colori a " .. #pal, function()
    if block > 1 then spr:resize(spr.width // block, spr.height // block) end
    for i, s in ipairs(sources) do
      local r = results[i]
      local im
      if block > 1 then
        im = Image(r.w, r.h, ColorMode.RGB)
      else
        im = s.img:clone()
      end
      im.bytes = r.bytes
      s.cel.image = im
      if block > 1 then s.cel.position = Point(0, 0) end
    end
    if p.setPalette or p.toIndexed then
      local off = reserve and 1 or 0
      local newPal = Palette(#pal + off)
      if reserve then newPal:setColor(0, Color { r = 0, g = 0, b = 0, a = 0 }) end
      for i, c in ipairs(pal) do newPal:setColor(i - 1 + off, Color { r = c.r, g = c.g, b = c.b, a = 255 }) end
      spr:setPalette(newPal)
      if reserve then spr.transparentColor = 0 end
    end
  end)

  if p.toIndexed then
    app.command.ChangePixelFormat { format = "indexed", dithering = "none" }
    -- The conversion maps colours through an approximate lookup table: write the exact indices, read back from the
    -- RGB result (every reduced pixel is exactly a palette colour; pixels outside the selection keep the conversion).
    local off = reserve and 1 or 0
    local tIdx = spr.transparentColor
    local lookup = {}
    for i, c in ipairs(pal) do lookup[(c.r << 16) | (c.g << 8) | c.b] = i - 1 + off end
    app.transaction("Indici esatti", function()
      for i, s in ipairs(sources) do
        local cel = s.cel
        local im = cel.image:clone()
        local old, rgba = im.bytes, results[i].bytes
        local w, h, stride = im.width, im.height, im.rowStride
        if #rgba == w * h * 4 then
          local rows = {}
          for y = 0, h - 1 do
            local parts = {}
            for x = 0, w - 1 do
              local o = (y * w + x) * 4 + 1
              local r, g, b, a = byte(rgba, o, o + 3)
              local v = (a == 255) and lookup[(r << 16) | (g << 8) | b] or nil
              if v then parts[x + 1] = char(v)
              elseif a == 0 then parts[x + 1] = char(tIdx)
              else parts[x + 1] = old:sub(y * stride + x + 1, y * stride + x + 1) end
            end
            rows[y + 1] = concat(parts) .. old:sub(y * stride + w + 1, (y + 1) * stride)
          end
          im.bytes = concat(rows)
          cel.image = im
        end
      end
    end)
  end

  return { before = #keys, after = #pal, seconds = os.clock() - t0, width = spr.width, height = spr.height }
end

return M
