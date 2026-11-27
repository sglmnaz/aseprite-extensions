-- Color Reducer: menu commands and the dialog. The maths is in reduce_core.lua.
--
-- The dialog shows only what changed the result on real images; everything else is fixed in FIXED (the values that
-- gave the best results in the tests, see README). The core still takes every option.
-- The dialog stays open: Apply, look, Ctrl+Z, change the values, Apply again.

local core
local prefs
local dlg

local PREFS_VERSION = 4   -- bump to reset the saved values to new defaults

-- What the user sets.
local DEFAULTS = {
  scope = "Current Cel",
  dmin = 6,          -- Color Distinction (x100)
  block = 1,         -- Block (px)
  detail = 0,        -- Small Details
  toIndexed = false,
}

-- What is fixed.
local FIXED = {
  method = "auto",
  ignoreEdges = true,
  hue = 2.5,
  bits = 5,
  snap = false,
  flatten = 0,
  speck = 0,
  dither = 0,
  binaryAlpha = true,
  alphaThreshold = 128,
  setPalette = true,
}

local function pref(key)
  local v = prefs[key]
  if v == nil then return DEFAULTS[key] end
  return v
end

local function names(list)
  local out = {}
  for i, e in ipairs(list) do out[i] = e.name end
  return out
end

local function refreshEnabled()
  dlg:modify { id = "detail", enabled = dlg.data.block > 1 }
end

local function reset()
  for k in pairs(DEFAULTS) do prefs[k] = nil end
  dlg:modify { id = "scope", option = DEFAULTS.scope }
  dlg:modify { id = "dmin", value = DEFAULTS.dmin }
  dlg:modify { id = "block", value = DEFAULTS.block }
  dlg:modify { id = "detail", value = DEFAULTS.detail }
  dlg:modify { id = "toIndexed", selected = DEFAULTS.toIndexed }
  dlg:modify { id = "info", text = "Settings reset." }
  refreshEnabled()
end

local function apply()
  local spr = app.sprite
  if not spr then return end
  if spr.colorMode ~= ColorMode.RGB then
    local answer = app.alert { title = "Reduce Colors", text = "The sprite is not in RGB mode. Convert it?",
      buttons = { "Convert to RGB", "Cancel" } }
    if answer ~= 1 then return end
    app.command.ChangePixelFormat { format = "rgb" }
  end

  local d = dlg.data
  for k in pairs(DEFAULTS) do prefs[k] = d[k] end

  local p = {}
  for k, v in pairs(FIXED) do p[k] = v end
  p.scope = core.byName(core.SCOPES, d.scope).id
  p.dmin = d.dmin / 100
  p.block = d.block
  p.detail = d.detail
  p.toIndexed = d.toIndexed

  local ok, res, err = pcall(core.run, spr, p, app.layer, app.frame)
  if not ok then
    app.alert { title = "Reduce Colors", text = { "Error:", tostring(res) } }
    return
  end
  if not res then
    app.alert { title = "Reduce Colors", text = err }
    return
  end
  dlg:modify { id = "info", text = string.format("%d colors -> %d, %dx%d  (%.1f s)", res.before, res.after,
    res.width, res.height, res.seconds) }
  app.refresh()
end

local function openDialog()
  if dlg then dlg:close() end
  dlg = Dialog { title = "Reduce Colors", onclose = function() dlg = nil end }
  dlg:combobox { id = "scope", label = "Apply To", option = pref("scope"), options = names(core.SCOPES) }

  dlg:slider { id = "dmin", label = "Color Distinction", min = 2, max = 15, value = pref("dmin") }
  dlg:label { label = "", text = "Colors closer than this become one. Lower = more colors and shades." }

  dlg:slider { id = "block", label = "Block (px)", min = 1, max = 16, value = pref("block"), onchange = refreshEnabled }
  dlg:label { label = "", text = "1 = same size. N = every NxN square becomes one pixel." }
  dlg:label { label = "", text = "Use it on the original big image, N = the size of one fake pixel." }

  dlg:slider { id = "detail", label = "Small Details", min = 0, max = 10, value = pref("detail") }
  dlg:label { label = "", text = "0 = clean outlines. Higher = more details, more jagged edges." }

  dlg:check { id = "toIndexed", label = "", text = "Convert to Indexed", selected = pref("toIndexed") }

  dlg:separator()
  dlg:label { id = "info", label = "", text = "Apply, look, Ctrl+Z to try again." }
  dlg:button { id = "apply", text = "Apply", focus = true, onclick = apply }
  dlg:button { id = "reset", text = "Reset", onclick = reset }
  dlg:button { id = "close", text = "Close", onclick = function() dlg:close() end }
  refreshEnabled()
  dlg:show { wait = false }
end

function init(plugin)
  core = dofile(app.fs.joinPath(plugin.path, "reduce_core.lua"))
  prefs = plugin.preferences
  if prefs.version ~= PREFS_VERSION then
    local keys = {}
    for k in pairs(prefs) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do prefs[k] = nil end
    prefs.version = PREFS_VERSION
  end
  local function enabled() return app.sprite ~= nil end
  plugin:newCommand {
    id = "ColorReducerReduceColors",
    title = "Reduce Colors...",
    group = "sprite_color",
    onclick = openDialog,
    onenabled = enabled,
  }
  plugin:newCommand {
    id = "ColorReducerReduceColorsFx",
    title = "Reduce Colors...",
    group = "edit_fx",
    onclick = openDialog,
    onenabled = enabled,
  }
  plugin:newCommand {
    id = "ColorReducerReduceColorsPalette",
    title = "Reduce Colors...",
    group = "palette_generation",
    onclick = openDialog,
    onenabled = enabled,
  }
end

function exit(plugin)
  if dlg then dlg:close() end
end
