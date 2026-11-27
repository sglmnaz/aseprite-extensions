-- Live Outline: events, commands and the dialog. The outline maths is in outline_core.lua.
--
-- Update policy (cheap enough for usual pixel-art sprite sizes):
--   * after every change of the sprite (a stroke, a paste, a move, an undo/redo) the CURRENT frame is rebuilt and
--     every other frame is marked stale;
--   * a stale frame is rebuilt as soon as it becomes the current one (frame change, animation playback);
--   * before Save / Save As / Save Copy As / Export / Export Sprite Sheet every frame is rebuilt, so the file on
--     disk is always right.
-- Pixels are written without undo information; only creating a missing cel is an undoable step ("Live Outline"),
-- and that never happens while an undo/redo is replaying.

local core
local pluginRef         -- the plugin object given to init (for its preferences)
local watched = {}       -- sprite.id -> { sprite = Sprite, listeners = {...}, fresh = { [frameNumber] = true } }
local busy = false
local siteListener, beforeCmdListener
local reportedError = false

local SAVE_COMMANDS = {
  SaveFile = true, SaveFileAs = true, SaveFileCopyAs = true, ExportSpriteSheet = true, ExportFile = true,
}

local function reportError(err)
  if reportedError then return end
  reportedError = true
  app.alert { title = "Live Outline", text = { "Error while updating the outline:", tostring(err) } }
end

-- Rebuilds `frames` (list of frame numbers, nil = all) of every outline layer of `spr`.
local function rebuild(spr, frames, structural)
  if busy then return end
  local layers = core.outlineLayers(spr)
  if #layers == 0 then return end
  if not frames then
    frames = {}
    for i = 1, #spr.frames do frames[i] = i end
  end
  busy = true
  local changed = false
  local ok, err = pcall(function()
    local function work()
      for _, e in ipairs(layers) do
        for _, f in ipairs(frames) do
          if f >= 1 and f <= #spr.frames then
            if core.updateFrame(spr, e.layer, e.cfg, f, structural) then changed = true end
          end
        end
      end
    end
    -- A missing cel can only be created inside a transaction; pure pixel rewrites need none.
    local needsCel = false
    if structural then
      for _, e in ipairs(layers) do
        for _, f in ipairs(frames) do
          local cel = f <= #spr.frames and e.layer:cel(f)
          if not cel or cel.image.width ~= spr.width or cel.image.height ~= spr.height
            or cel.position.x ~= 0 or cel.position.y ~= 0 then
            needsCel = true
          end
        end
      end
    end
    if needsCel then app.transaction("Live Outline", work) else work() end
  end)
  busy = false
  if not ok then reportError(err) end
  if changed then app.refresh() end
end

local function currentFrameOf(spr)
  local site = app.site
  if site and site.sprite and site.sprite.id == spr.id and site.frame then return site.frame.frameNumber end
  return 1
end

local function onChange(entry, ev)
  if busy then return end
  local spr = entry.sprite
  local fromUndo = ev and ev.fromUndo
  local f = currentFrameOf(spr)
  entry.fresh = { [f] = true }
  rebuild(spr, { f }, not fromUndo)
end

local function watch(spr)
  if not spr or watched[spr.id] then return watched[spr and spr.id] end
  local entry = { sprite = spr, fresh = {} }
  local function handler(ev) onChange(entry, ev) end
  entry.listeners = {
    spr.events:on("change", handler),
    spr.events:on("layervisibility", handler),
  }
  watched[spr.id] = entry
  return entry
end

local function forgetClosed()
  local open = {}
  for _, s in ipairs(app.sprites) do open[s.id] = true end
  for id in pairs(watched) do
    if not open[id] then watched[id] = nil end
  end
end

local function onSiteChange()
  if busy then return end
  forgetClosed()
  local spr = app.site and app.site.sprite
  if not spr then return end
  local entry = watch(spr)
  local f = currentFrameOf(spr)
  if not entry.fresh[f] then
    entry.fresh[f] = true
    rebuild(spr, { f }, false)
  end
end

local function onBeforeCommand(ev)
  if not SAVE_COMMANDS[ev.name] then return end
  local spr = app.sprite
  if not spr then return end
  local entry = watch(spr)
  rebuild(spr, nil, true)
  entry.fresh = {}
  for i = 1, #spr.frames do entry.fresh[i] = true end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Presets: the user's own, saved in the extension preferences (Aseprite keeps them in the extension folder, so
-- they are per user and never shipped with the extension). Each one is { name = "...", config = "<config>" }.

local function loadPresets()
  local prefs = pluginRef and pluginRef.preferences
  if not prefs or type(prefs.presets) ~= "table" then return {} end
  local list = {}
  for _, p in ipairs(prefs.presets) do
    if type(p) == "table" and type(p.name) == "string" and p.name ~= "" and core.parseConfig(p.config) then
      list[#list + 1] = { name = p.name, config = p.config }
    end
  end
  return list
end

local function storePresets(list)
  if pluginRef then pluginRef.preferences.presets = list end
end

local function findPreset(name)
  for i, p in ipairs(loadPresets()) do
    if p.name == name then return p, i end
  end
  return nil
end

local function presetOptions()
  local names = { "" }   -- first entry empty: no preset selected
  for _, p in ipairs(loadPresets()) do names[#names + 1] = p.name end
  return names
end

-- ---------------------------------------------------------------------------------------------------------------
-- Dialog

local function colorFromHex(hex)
  local r, g, b, a = core.hexToRgba(hex)
  return Color { r = r, g = g, b = b, a = a }
end

local function hexFromColor(c)
  local h = core.rgbToHex(c.red, c.green, c.blue)
  if c.alpha < 255 then h = h .. string.format("%02x", c.alpha) end
  return h
end

local function copyRings(rings)
  local out = {}
  for i, r in ipairs(rings) do out[i] = { hex = r.hex, w = r.w, mask = r.mask } end
  return out
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Asks a preset name. -> the trimmed name, or nil when cancelled / empty.
local function askPresetName(default)
  local dlg = Dialog { title = "Save Preset" }
  dlg:entry { id = "name", label = "Name", text = default or "", focus = true }
  dlg:button { id = "ok", text = "Save" }
  dlg:button { id = "cancel", text = "Cancel" }
  dlg:show()
  if not dlg.data.ok then return nil end
  local name = trim(dlg.data.name)
  if name == "" then return nil end
  return name
end

-- The corner matrix editor, like the one of Edit > FX > Outline. -> the new mask, or nil when cancelled.
local function askCorners(mask)
  local dlg = Dialog { title = "Corners" }
  local function setMask(m)
    for i = 1, 9 do
      if i ~= 5 then dlg:modify { id = "m" .. i, selected = m:sub(i, i) == "1" } end
    end
  end
  for n, m in ipairs(core.MASKS) do
    dlg:button { id = "preset" .. n, label = (n == 1) and "Presets" or nil, text = m.name,
      onclick = function() setMask(m.mask) end }
  end
  for row = 0, 2 do
    dlg:newrow()
    for col = 1, 3 do
      local i = row * 3 + col
      local label = (i == 1) and "Neighbours" or nil
      if i == 5 then
        dlg:check { id = "m5", label = label, selected = true, enabled = false }
      else
        dlg:check { id = "m" .. i, label = label, selected = mask:sub(i, i) == "1" }
      end
    end
  end
  dlg:separator()
  dlg:button { id = "ok", text = "OK", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  dlg:show()
  local d = dlg.data
  if not d.ok then return nil end
  local out = {}
  for i = 1, 9 do out[i] = (i ~= 5 and d["m" .. i]) and "1" or "0" end
  return table.concat(out)
end

-- Shows the settings dialog once for `st` (the editable state: rings, source, preset name). `preview(st)` is
-- called when it opens and after every change.
-- -> "reopen" (the number of rings changed: show it again), "ok", "detach" or nil (cancelled).
local function runDialog(st, editing, preview)
  local dlg = Dialog { title = editing and "Live Outline Settings" or "New Live Outline" }
  local action

  -- Copies the widget values back into `st`.
  local function sync()
    local d = dlg.data
    for i, r in ipairs(st.rings) do
      r.hex = hexFromColor(d["c" .. i])
      r.w = core.clampWidth(d["w" .. i])
    end
    st.source = (d.source == core.SOURCE_LABELS.next) and "next" or "above"
    st.preset = d.preset or ""
  end
  local function reopen()
    action = "reopen"
    dlg:close()
  end
  local function changed()
    sync()
    preview(st)
  end

  dlg:combobox { id = "preset", label = "Preset", options = presetOptions(), option = st.preset,
    onchange = function()
      sync()
      local p = findPreset(st.preset)
      local cfg = p and core.parseConfig(p.config)
      if cfg then
        st.rings = copyRings(cfg.rings)
        st.source = cfg.source
        reopen()
      else
        dlg:modify { id = "deletePreset", enabled = false }
      end
    end }
  dlg:button { id = "savePreset", text = "Save...",
    onclick = function()
      sync()
      local name = askPresetName(st.preset)
      if not name then return end
      local list = loadPresets()
      local config = core.configString(st)
      local _, idx = findPreset(name)
      if idx then
        local answer = app.alert { title = "Save Preset", text = "Preset \"" .. name .. "\" already exists. Overwrite it?",
          buttons = { "Overwrite", "Cancel" } }
        if answer ~= 1 then return end
        list[idx].config = config
      else
        list[#list + 1] = { name = name, config = config }
      end
      storePresets(list)
      st.preset = name
      dlg:modify { id = "preset", options = presetOptions(), option = name }
      dlg:modify { id = "deletePreset", enabled = true }
    end }
  dlg:button { id = "deletePreset", text = "Delete", enabled = findPreset(st.preset) ~= nil,
    onclick = function()
      sync()
      local _, idx = findPreset(st.preset)
      if not idx then return end
      local answer = app.alert { title = "Delete Preset", text = "Delete preset \"" .. st.preset .. "\"?",
        buttons = { "Delete", "Cancel" } }
      if answer ~= 1 then return end
      local list = loadPresets()
      table.remove(list, idx)
      storePresets(list)
      st.preset = ""
      dlg:modify { id = "preset", options = presetOptions(), option = "" }
      dlg:modify { id = "deletePreset", enabled = false }
    end }

  dlg:separator { text = "Rings (inside to outside)" }
  for i, r in ipairs(st.rings) do
    dlg:color { id = "c" .. i, label = "Ring " .. i, color = colorFromHex(r.hex), onchange = changed }
    dlg:number { id = "w" .. i, text = tostring(r.w), decimals = 0, onchange = changed }
    dlg:label { id = "px" .. i, text = "px" }
    dlg:button { id = "k" .. i, text = "Corners: " .. core.maskName(r.mask),
      onclick = function()
        local m = askCorners(r.mask)
        if m then
          r.mask = m
          dlg:modify { id = "k" .. i, text = "Corners: " .. core.maskName(m) }
          changed()
        end
      end }
    if #st.rings > 1 then
      dlg:button { id = "remove" .. i, text = "-",
        onclick = function()
          sync()
          table.remove(st.rings, i)
          reopen()
        end }
    end
    dlg:newrow()
  end
  if #st.rings < core.MAX_RINGS then
    dlg:button { id = "addRing", text = "+ Add Ring",
      onclick = function()
        sync()
        local last = st.rings[#st.rings]
        st.rings[#st.rings + 1] = { hex = last.hex, w = last.w, mask = last.mask }
        reopen()
      end }
  end

  dlg:separator()
  dlg:combobox { id = "source", label = "Source", options = { core.SOURCE_LABELS.above, core.SOURCE_LABELS.next },
    option = core.SOURCE_LABELS[st.source], onchange = changed }
  dlg:separator()
  dlg:button { id = "ok", text = editing and "Apply" or "Create", focus = true }
  if editing then dlg:button { id = "detach", text = "Detach (Normal Layer)" } end
  dlg:button { id = "cancel", text = "Cancel" }

  preview(st)
  dlg:show()
  if action == "reopen" then return "reopen" end
  local d = dlg.data
  if d.ok then
    sync()
    return "ok"
  end
  if d.detach then return "detach" end
  return nil
end

local CANCELLED = "live-outline: cancelled"

-- The dialog runs inside one transaction, with a live preview on the current frame:
--   * a new outline layer is created right away, so the preview has somewhere to draw;
--   * OK commits everything (layer, settings, all frames) as one undo step;
--   * Cancel / Detach raise CANCELLED, which rolls the transaction back (the new layer and any cel it made are
--     gone). Pixels are written without undo information, so an edited layer's current frame is then redrawn
--     with its old settings.
local function showDialog()
  local spr = app.sprite
  if not spr then
    app.alert("Open a sprite first.")
    return
  end
  local active = app.layer
  local editing = active and core.getConfig(active) and active or nil
  local oldCfg = editing and core.getConfig(editing)
  local cfg = oldCfg or core.defaultConfig()
  local st = { rings = copyRings(cfg.rings), source = cfg.source, preset = "" }
  local frame = currentFrameOf(spr)
  local action

  busy = true   -- the sprite listeners must not redraw with the stored settings while previewing
  local ok, err = pcall(function()
    app.transaction(editing and "Edit Live Outline" or "New Live Outline", function()
      local layer = editing
      if not layer then
        layer = spr:newLayer()
        layer.name = core.DEFAULT_NAME
        if active then
          -- Right under the active layer, in the same group.
          layer.parent = active.parent
          layer.stackIndex = active.stackIndex
        else
          layer.stackIndex = 1
        end
        layer.isEditable = false   -- locked: it is rewritten anyway, so drawing on it would be lost
        if active then app.layer = active end
      end

      local previewError = false
      local function preview(s)
        local pok, perr = pcall(function()
          local c = { rings = copyRings(s.rings), source = s.source }
          if core.updateFrame(spr, layer, c, frame, true) then app.refresh() end
        end)
        if not pok and not previewError then
          previewError = true
          app.alert { title = "Live Outline", text = { "Preview failed:", tostring(perr) } }
        end
      end

      repeat action = runDialog(st, editing, preview) until action ~= "reopen"
      if action ~= "ok" then error(CANCELLED) end

      local newCfg = { rings = copyRings(st.rings), source = st.source }
      core.setConfig(layer, newCfg)
      for f = 1, #spr.frames do core.updateFrame(spr, layer, newCfg, f, true) end
      if active and not editing then app.layer = active end
    end)
  end)
  busy = false

  local cancelled = not ok and tostring(err):find(CANCELLED, 1, true) ~= nil
  if cancelled and editing then
    pcall(function() core.updateFrame(spr, editing, oldCfg, frame, false) end)
  end
  if cancelled and action == "detach" then
    app.transaction("Detach Live Outline", function() core.setConfig(editing, nil) end)
  elseif not ok and not cancelled then
    app.alert { title = "Live Outline", text = tostring(err) }
  end
  local entry = watch(spr)
  entry.fresh = {}
  if ok then
    for i = 1, #spr.frames do entry.fresh[i] = true end
  else
    entry.fresh[frame] = true
  end
  app.refresh()
end

-- ---------------------------------------------------------------------------------------------------------------

function init(plugin)
  pluginRef = plugin
  core = dofile(app.fs.joinPath(plugin.path, "outline_core.lua"))

  plugin:newCommand {
    id = "LiveOutline",
    title = "Live Outline...",
    group = "layer_popup_properties",
    onclick = showDialog,
  }
  plugin:newCommand {
    id = "LiveOutlineMenu",
    title = "Live Outline...",
    group = "layer_properties",
    onclick = showDialog,
  }
  plugin:newCommand {
    id = "LiveOutlineRefresh",
    title = "Refresh Live Outline (All Frames)",
    group = "layer_properties",
    onclick = function()
      local spr = app.sprite
      if not spr then return end
      rebuild(spr, nil, true)
      local entry = watch(spr)
      entry.fresh = {}
      for i = 1, #spr.frames do entry.fresh[i] = true end
    end,
    onenabled = function() return app.sprite ~= nil end,
  }

  siteListener = app.events:on("sitechange", onSiteChange)
  beforeCmdListener = app.events:on("beforecommand", onBeforeCommand)
  for _, s in ipairs(app.sprites) do watch(s) end
end

function exit(plugin)
  if siteListener then app.events:off(siteListener) end
  if beforeCmdListener then app.events:off(beforeCmdListener) end
  for _, entry in pairs(watched) do
    pcall(function()
      for _, id in ipairs(entry.listeners) do entry.sprite.events:off(id) end
    end)
  end
  watched = {}
end
