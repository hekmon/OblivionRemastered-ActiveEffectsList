-- Fake UE4SS + game environment to run ActiveEffectsList/Scripts/main.lua outside the game.
-- Usage: lua tests/mock_ue4ss.lua <copy of ActiveEffectsList>/Scripts [nonames|names] [ok|broken]
--   Run it on a COPY of the mod folder: the mod writes spellbook.txt next to its Scripts folder.
--   names  = the game returns the named effect list (TryEffectNames path; set it true in config to test)
--   broken = bar geometry calls fail (exercises the fixed fallback position)
-- Data mirrors a real in-game probe (icons, fractions, magic menu names), including a 10 s pause.
local SCEN = arg[2] or "nonames"
BROKEN_BARS = (arg[3] == "broken")
local fakeNow = 100.0
os.clock = function() return fakeNow end
local loopFn, keyFn, hooks = nil, nil, {}
local function obj(class, name, props, full)
  local o = props or {}
  o.__class = class; o.__name = name; o.__full = full
  o.IsValid = function() return true end
  o.GetFName = function(self) return { ToString = function() return self.__name end } end
  o.GetClass = function(self) return { GetFName = function() return { ToString = function() return self.__class end } end } end
  o.GetFullName = function(self) return self.__class .. " " .. (self.__full or ("/Game/Maps/L.L:PersistentLevel.Hud_1.Main.WidgetTree_5." .. self.__name)) end
  o.GetOuter = function(self) return self.__outer end
  o.SetVisibility = function(self, v) self.vis = v end
  o.RemoveFromParent = function(self) self.removed = true end
  o.GetCachedGeometry = function(self)
    if self.vis == 1 then return { rect = { 0, 0, 0, 0 } } end
    if BROKEN_BARS and self.__class:find("Health") or BROKEN_BARS and self.__class:find("Magicka") or BROKEN_BARS and self.__class:find("Fatigue") then error("push_struct error") end
    return { rect = self.rect or { 0, 0, 1920, 1080 } } end
  return o
end
local function text(s) return { ToString = function() return s end } end
local function arr(t) return { ForEach = function(self, f) for i, v in ipairs(t) do f(i, { get = function() return v end }) end end } end
local function mkslot(cls, parent) local s = obj(cls, cls, { Parent = parent })
  for _, m in ipairs({"SetHorizontalAlignment","SetVerticalAlignment","SetPadding","SetAutoSize","SetAlignment"}) do s[m] = function() end end
  s.SetRowSpan = function(self, n) self.RowSpan = n end
  s.SetColumnSpan = function(self, n) self.ColumnSpan = n end
  s.SetAnchors = function(self, a) self.anchors = a end
  s.SetPosition = function(self, p) self.pos = p end
  return s end
local function panel(class, name, full)
  local p = obj(class, name, { children = {} }, full)
  p.AddChildToGrid = function(self, c, r, col) local s = mkslot("GridSlot", self); s.Row = r; s.Column = col; c.Slot = s; table.insert(self.children, c); return s end
  p.AddChildToOverlay = function(self, c) local s = mkslot("OverlaySlot", self); c.Slot = s; table.insert(self.children, c); return s end
  p.AddChildToCanvas = function(self, c) local s = mkslot("CanvasPanelSlot", self); c.Slot = s; table.insert(self.children, c); self.cslot = s; return s end
  return p
end
local function hudInstance(template)
  local full = template and "/Game/UI/Modern/HUD/Main/WBP_ModernHud_Main.WBP_ModernHud_Main_C:WidgetTree" or nil
  local tree = obj("WidgetTree", "WidgetTree", {}, full)
  local root = panel("Overlay", "MainRoot", full and full .. ".MainRoot"); root.__outer = tree; tree.RootWidget = root
  local box = obj("SizeBox", "SizeBox_0", nil, full and full .. ".SizeBox_0"); box.__outer = tree
  local icons = obj("WBP_ModernHud_EffectIcons_C", "EffectIcons", nil, full and full .. ".EffectIcons"); icons.__outer = tree
  icons.Slot = obj("SizeBoxSlot", "SizeBoxSlot_0", { Parent = box })
  box.Slot = obj("GridSlot", "GridSlot_0", { Parent = obj("GridPanel", "StatGrid"), Row = 0, Column = 0 })
  local bars = {}
  for i, c in ipairs({"WBP_ModernHud_Health_C","WBP_ModernHud_Magicka_C","WBP_ModernHud_Fatigue_C"}) do
    local b = obj(c, c, nil, full and full .. "." .. c); b.__outer = tree; b.Slot = obj("HorizontalBoxSlot", "s", { Parent = box })
    b.rect = { 80, 960 + i * 25, 330, 975 + i * 25 }; bars[c] = b
  end
  return icons, root, box, bars
end
local tIcons, tRoot, tBox, tBars = hudInstance(true)
local icons, root, box, bars = hudInstance(false)
local tb = obj("TextBlock", "x", { Font = { FontObject = obj("Font", "K"), TypefaceFontName = text("Regular") } }, "/Game/Maps/L.L:PersistentLevel.Hud.WBP_ModernHud_Info.WidgetTree.text")
-- HUD effects like the real probe: {icon, duration, start time}
local tex = {}
local function T(n) tex[n] = tex[n] or obj("Texture2D", n); return tex[n] end
local effects = {
  { icon = "T_chameleon_illusion", dur = 100, start = tonumber(os.getenv("CHAM_START") or 59) }, -- already 41s in at t=100
  { icon = "T_night_eye_illusion", dur = 300, start = 64 },
  { icon = "T_fortify_restoration", dur = 60, start = 108 },          -- custom spell, 2 effects
  { icon = "T_fortify_restoration", dur = 60, start = 108 },
  { icon = "T_fortify_magicka_ultiplier_restoration", dur = 60, start = 108 },
}
-- VRECAST=1: the 3-effect spell cast at 108 is cast again at 130 (its old effects are replaced).
if os.getenv("VRECAST") == "1" then
  for i = 3, 5 do effects[i].stop = 130 end
  table.insert(effects, 6, { icon = "T_fortify_restoration", dur = 60, start = 130 })
  table.insert(effects, 7, { icon = "T_fortify_restoration", dur = 60, start = 130 })
  table.insert(effects, 8, { icon = "T_fortify_magicka_ultiplier_restoration", dur = 60, start = 130 })
end
-- FULL=1: a 5-piece bound armor spell at 112 (the HUD list is capped, only 3 pieces fit), then a
-- shield spell at 120 while the HUD is full (nothing of it is visible).
FULL = os.getenv("FULL") == "1"
local HUD_CAP = tonumber(os.getenv("HUD_CAP") or 8)
-- PARTIAL=1: 7 effects running, then a fortify + magicka spell (56 s): only its fortify effect fits.
PARTIAL = os.getenv("PARTIAL") == "1"
if PARTIAL then
  effects = { effects[1], effects[2] }
  for _ = 1, 5 do effects[#effects + 1] = { icon = "T_bound_armor_conjuration", dur = 120, start = 112 } end
  effects[#effects + 1] = { icon = "T_fortify_restoration", dur = 56, start = 116 }
  effects[#effects + 1] = { icon = "T_fortify_magicka_ultiplier_restoration", dur = 56, start = 116 }
end
-- STUCK=1 (with HUD_CAP=3): the game's HUD list keeps hiding new effects although it shows fewer than 8.
-- A Volonté fortify (90 s, cost 40) cast at 125 never appears; an enemy drain takes 37 magicka at 130.
STUCK = os.getenv("STUCK") == "1"
if STUCK then effects[#effects + 1] = { icon = "T_fortify_restoration", dur = 90, start = 125, hidden = true } end
-- BOW=1: "Arc enchanté" (bound bow + fortify agility, 50 s, cost 284) cast at 115: its fortify
-- effect shows 0.3 s before the bow, and the magicka drops with the bow. "Masse enchantée" has the
-- same icons and duration (cost 281); "Épée liée" is a bound weapon alone (15 s, no cost recorded).
BOW = os.getenv("BOW") == "1"
if BOW then
  effects[#effects + 1] = { icon = "T_fortify_restoration", dur = 50, start = 115.0 }
  effects[#effects + 1] = { icon = "T_bound_weapon_conjuration", dur = 50, start = 115.3 }
end
-- CHAM=1: "Caméléon" (60 s, cost 239) cast at 115 right before the HUD stops updating for 3 s
-- while the game runs (as after a menu): the duration estimate creeps up (17, 20, 22 s...).
-- "Pas voilés" has the same icon, 30 s, cost 17.
CHAM = os.getenv("CHAM") == "1"
if CHAM then effects[#effects + 1] = { icon = "T_chameleon_illusion", dur = 60, start = 115.0 } end
-- POOL=1: Deepscorn Hollow's ichor basin at 116 gives Fortify Health 25, Agility 10, Sneak 20 and
-- Chameleon 50, 20 min, no magicka spent. The active effects page also lists permanent effects
-- (Agility 10, Sneak 7, Luck 10), merged by type. The magic menu is opened at 118.
POOL = os.getenv("POOL") == "1"
if POOL then
  for _ = 1, 3 do effects[#effects + 1] = { icon = "T_fortify_restoration", dur = 1200, start = 116 } end
  effects[#effects + 1] = { icon = "T_chameleon_illusion", dur = 1200, start = 116 }
end
-- EXPLORE=1 (with FULL=1): "Oeil de la nuit" (night eye + detect life, 120 s, cost 108) cast at
-- 125 while the list is full. At that moment a hidden armor piece surfaces (one more slot); the
-- night eye shows 2 s later, the detect life stays hidden.
EXPLORE = os.getenv("EXPLORE") == "1"
if EXPLORE then
  table.insert(effects, 3, { icon = "T_night_eye_illusion", dur = 120, start = 125, showAt = 127 })
end
if FULL then
  for _ = 1, 5 do effects[#effects + 1] = { icon = "T_bound_armor_conjuration", dur = 120, start = 112 } end
  effects[#effects + 1] = { icon = "T_shield_alteration", dur = 118, start = 120 }
end
if EXPLORE then
  effects[#effects + 1] = { icon = "T_detect_life_mysticism", dur = 120, start = 125, hidden = true }
  -- the surfacing armor piece (53 % left) does not match its cast's timer (in game it did not join)
  for i = #effects, 1, -1 do
    if effects[i].icon == "T_bound_armor_conjuration" then effects[i - 1].start = 70; break end
  end
end
local gameTime = 100.0
local paused = false
local function hudArrays()
  local ic, tl = {}, {}
  local gameTime = gameTime
  BUMP_NOW = os.getenv("BUMP") == "1" and gameTime >= 130
  -- GLITCH=1: for one update the game's list is empty, then everything is back unchanged.
  if os.getenv("GLITCH") == "1" and math.abs(gameTime - 125) < 0.01 then return ic, tl end
  if CHAM and gameTime >= 115.5 and gameTime < 118.5 then gameTime = 115.5 end
  for _, e in ipairs(effects) do
    -- DISPEL=1: everything active is removed at 140 (Dissipation)
    -- SELFDISPEL=1: the player casts "Dissipation suprême" (cost 42) at 140; use with HUD_CAP=0,
    -- where the game's HUD list shows nothing and every effect is rebuilt.
    local dispelled = ((os.getenv("DISPEL") == "1" or os.getenv("SELFDISPEL") == "1") and gameTime >= 140 and e.start < 140)
      or (e.stop and gameTime >= e.stop)
    if gameTime >= e.start and not dispelled then
      local f = 1 - (gameTime - e.start) / e.dur
      local cap = HUD_CAP + ((EXPLORE and gameTime >= 125) and 1 or 0)
      if f > 0 and (#ic < cap or BUMP_NOW) and not e.hidden and not (e.showAt and gameTime < e.showAt) then ic[#ic + 1] = T(e.icon); tl[#tl + 1] = f end
    end
  end
  -- REORDER=1: from 135 the game lists the effects in reverse order (seen after an overflow).
  if os.getenv("REORDER") == "1" and gameTime >= 135 then
    local ric, rtl = {}, {}
    for i = #ic, 1, -1 do ric[#ric + 1] = ic[i]; rtl[#rtl + 1] = tl[i] end
    ic, tl = ric, rtl
  end
  -- BUMP=1 (with FULL=1): from 130 the full list shows the newest effects, pushing older ones out.
  if BUMP_NOW then
    while #ic > HUD_CAP do table.remove(ic, 1); table.remove(tl, 1) end
  end
  return ic, tl
end
local vm = obj("VHUDMainViewModel", "VM")
local mt = { __index = function(t, k)
  local ic, tl = hudArrays()
  if k == "EffectsIcons" then return arr(ic) elseif k == "EffectsTimeLeft" then return arr(tl)
  elseif k == "CurrentMagickaValue" then
    local m = 400.0 - (MAGOFF or 0)
    if PARTIAL then
      if gameTime >= 112 then m = m - 121 end
      if gameTime >= 116 then m = m - 277 end
      return m
    end
    -- COSTUP=1: the spell now costs 42 instead of the recorded 50 (skill went up).
    if gameTime >= 108 then m = m - (os.getenv("COSTUP") == "1" and 42 or 50) end
    if STUCK and gameTime >= 125 then m = m - 40 end
    if STUCK and gameTime >= 130 then m = m - 37 end
    if os.getenv("VRECAST") == "1" and gameTime >= 130 then m = m - 50 end
    if STUCK and os.getenv("RECAST") == "1" and gameTime >= 135 then m = m - 40 end -- same spell again
    if BOW and gameTime >= 115.3 then m = m - 284 end
    if os.getenv("SELFDISPEL") == "1" and gameTime >= 140 then m = m - 42 end
    if EXPLORE and gameTime >= 125 then m = m - 108 end
    if CHAM and gameTime >= 115 then m = m - 239 end
    if FULL and gameTime >= 112 then m = m - 121 end
    if FULL and gameTime >= 120 then m = m - 85 end
    return m
  elseif k == "SpellIcon" then
    if CHAM and gameTime >= 114 then return T("T_chameleon_illusion") end
    if os.getenv("SELFDISPEL") == "1" and gameTime >= 139 then return T("T_dispel_mysticism") end
    if EXPLORE and gameTime >= 124 then return T("T_detect_life_mysticism") end
    if PARTIAL and gameTime >= 115 then return T("T_fortify_restoration") end
    if PARTIAL and gameTime >= 111 then return T("T_bound_armor_conjuration") end
    if FULL and gameTime >= 119 then return T("T_shield_alteration") end
    if FULL and gameTime >= 111 then return T("T_bound_armor_conjuration") end
    return T("T_fortify_restoration")
  end
end }
setmetatable(vm, mt)
-- The live HUD's main widget holds its view model (WidgetTree -> WBP_ModernHud_Main.HUDMainViewModel).
local mainWidget = obj("WBP_ModernHud_Main_C", "WBP_ModernHud_Main", { HUDMainViewModel = vm })
icons.__outer.__outer = mainWidget
local function item(name, icon) return { Name = text(name), Icon = T(icon), Type = 8 } end
-- Full list as in the game: Active effects page items (Type 8) and spells, with InventoryIndex.
local INV = {
    item("Caméléon", "T_chameleon_illusion"), item("Vision nocturne", "T_night_eye_illusion"),
    item("Renfort : Volonté", "T_fortify_restoration"), item("Renfort : Force", "T_fortify_restoration"),
    item("Renfort : Intelligence", "T_fortify_restoration"), item("Renfort de Magie", "T_fortify_magicka_ultiplier_restoration"),
    -- the hover IDs (3007, 3049) do not match InventoryIndex, as in the game
    { Name = text("Nerver Give Up"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 7, Property = 30 },
    { Name = text("Puissance de l'archer"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 12, Property = 50 },
    { Name = text("Puissance du mage"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 13, Property = 60 },
    { Name = text("Daedric Armor"), Icon = T("T_bound_armor_conjuration"), Type = 4, InventoryIndex = 14, Property = 121 },
    { Name = text("Bouclier lié"), Icon = T("T_bound_armor_conjuration"), Type = 4, InventoryIndex = 15, Property = 40 },
    { Name = text("Champ de Force"), Icon = T("T_shield_alteration"), Type = 4, InventoryIndex = 16, Property = 85 },
    { Name = text("Égide"), Icon = T("T_shield_alteration"), Type = 4, InventoryIndex = 17, Property = 73 },
    { Name = text("Magic Well"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 18, Property = 277 },
    { Name = text("Renfort de Volonté supérieur"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 19, Property = 40 },
    { Name = text("Arc enchanté"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 20, Property = 284 },
    { Name = text("Masse enchantée"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 21, Property = 281 },
    { Name = text("Épée liée"), Icon = T("T_bound_weapon_conjuration"), Type = 4, InventoryIndex = 22 },
    { Name = text("Caméléon"), Icon = T("T_chameleon_illusion"), Type = 4, InventoryIndex = 23, Property = 239 },
    { Name = text("Pas voilés"), Icon = T("T_chameleon_illusion"), Type = 4, InventoryIndex = 24, Property = 17 },
    { Name = text("Dissipation suprême"), Icon = T("T_dispel_mysticism"), Type = 4, InventoryIndex = 25, Property = 42 },
    -- DECOY=1 (with STUCK=1): a fortify spell costing 41, within 2 % of the Volonté spell's 40
    { Name = text("Renfort leurre"), Icon = T("T_fortify_restoration"), Type = 4, InventoryIndex = 26, Property = 41 },
    { Name = text("Oeil de la nuit"), Icon = T("T_detect_life_mysticism"), Type = 4, InventoryIndex = 27, Property = 108 },
}
if POOL then
  -- permanent effects (enchanted gear, abilities) on the active effects page
  INV[#INV + 1] = { Name = text("Renfort : Agilité"), Icon = T("T_fortify_restoration"), Type = 8, Property = 10 }
  INV[#INV + 1] = { Name = text("Renfort : Discrétion"), Icon = T("T_fortify_restoration"), Type = 8, Property = 7 }
  INV[#INV + 1] = { Name = text("Renfort : Chance"), Icon = T("T_fortify_restoration"), Type = 8, Property = 10 }
end
local mm = obj("VMagicMenuViewModel", "MM", {
  Inventory = arr(INV),
  -- what the game showed after selecting a spell; USERTEXT=1: a custom spell's raw name key
  CurrentSpellEquiped = os.getenv("USERTEXT") == "1" and { Name = text("UserInputText_104_471_22"), Icon = T("T_fortify_restoration"), Type = 0 }
    or { Name = text("{Item}"), Type = 0 },
  CurrentPageInventory = arr({}) })
local function eff(name, extra, mag, dur, icon, range) return { EffectName = text(name), AdditionalEffectName = text(extra), Magnitude = mag, Duration = dur, Image = T(icon), Range = range } end
local SPELL_EFFECTS = {
  [3007] = { eff("Renfort", "Endurance", 50, 60, "T_fortify_restoration", 0), eff("Renfort", "Force", 50, 60, "T_fortify_restoration", 0) },
  [3049] = { eff("Renfort : {0}", "Agilité", 100, 60, "T_fortify_restoration", 0), eff("Renfort : {0}", "Archerie", 30, 60, "T_fortify_restoration", 0),
           eff("Renfort de Magie", "", 100, 60, "T_fortify_magicka_ultiplier_restoration", 0), eff("Dégâts de feu", "", 10, 0, "T_fire_damage", 2) },
  -- decoy: same icons as 3049, other durations (like "Masse enchantée" vs "Arc enchanté")
  [3050] = { eff("Renfort : {0}", "Force", 100, 34, "T_fortify_restoration", 0), eff("Renfort : {0}", "Endurance", 30, 34, "T_fortify_restoration", 0),
           eff("Renfort de Magie", "", 50, 34, "T_fortify_magicka_ultiplier_restoration", 0) },
  [3060] = { eff("Cuirasse liée", "", 0, 120, "T_bound_armor_conjuration", 0), eff("Casque lié", "", 0, 120, "T_bound_armor_conjuration", 0),
             eff("Gantelets liés", "", 0, 120, "T_bound_armor_conjuration", 0), eff("Grèves liées", "", 0, 120, "T_bound_armor_conjuration", 0),
             eff("Bottes liées", "", 0, 120, "T_bound_armor_conjuration", 0) },
  [3061] = { eff("Bouclier lié", "", 0, 120, "T_bound_armor_conjuration", 0) },
  [3070] = { eff("Bouclier", "", 85, 118, "T_shield_alteration", 0) },
  [3071] = { eff("Bouclier", "", 50, 60, "T_shield_alteration", 0) },
  [3080] = { eff("Renfort : {0}", "Intelligence", 100, 56, "T_fortify_restoration", 0), eff("Renfort de Magie", "", 100, 56, "T_fortify_magicka_ultiplier_restoration", 0) },
  [3081] = { eff("Renfort : {0}", "Volonté", 10, 90, "T_fortify_restoration", 0) },
  [3090] = { eff("Arc lié", "", 0, 50, "T_bound_weapon_conjuration", 0), eff("Renfort : {0}", "Agilité", 100, 50, "T_fortify_restoration", 0) },
  [3091] = { eff("Masse liée", "", 0, 50, "T_bound_weapon_conjuration", 0), eff("Renfort : {0}", "Force", 100, 50, "T_fortify_restoration", 0) },
  [3092] = { eff("Épée liée", "", 0, 15, "T_bound_weapon_conjuration", 0) },
  [3093] = { eff("Caméléon", "", 100, 60, "T_chameleon_illusion", 0) },
  [3094] = { eff("Caméléon", "", 15, 30, "T_chameleon_illusion", 0) },
  [3095] = { eff("Dissipation", "", 150, -1, "T_dispel_mysticism", 0) },
  [3096] = { eff("Renfort : {0}", "Chance", 20, 30, "T_fortify_restoration", 0) },
  [3097] = { eff("Vision nocturne", "", 0, 120, "T_night_eye_illusion", 0), eff("Détection de vie", "", 100, 120, "T_detect_life_mysticism", 0) },
}
local added = obj("VAddedEffectsListViewModel", "AddedVM")
local SPELL_NAMES = { [3007] = "Nerver Give Up", [3049] = "Puissance de l'archer", [3050] = "Puissance du mage",
  [3060] = "Daedric Armor", [3061] = "Bouclier lié", [3070] = "Champ de Force", [3071] = "Égide",
  [3080] = "Magic Well", [3081] = "Renfort de Volonté supérieur",
  [3090] = "Arc enchanté", [3091] = "Masse enchantée", [3092] = "Épée liée",
  [3093] = "Caméléon", [3094] = "Pas voilés", [3095] = "Dissipation suprême", [3096] = "Renfort leurre", [3097] = "Oeil de la nuit" }
-- As in the game: the panel instance is named after the menu's variable ("magic_details"), and the
-- title is a WBP_AltarTextBlock user widget wrapping a VAltarTextBlock named text_block.
local title = obj("VAltarTextBlock", "text_block", nil,
  "/Game/Maps/L.L:PersistentLevel.Hud.Menu.WidgetTree_1.magic_details.WidgetTree_2.Magic_Castable_Name.WidgetTree_3.text_block")
title.GetText = function() return text(HOVERED and SPELL_NAMES[HOVERED] or "") end
local titleWrapper = obj("WBP_AltarTextBlock_C", "Magic_Castable_Name", { text_block = title },
  "/Game/Maps/L.L:PersistentLevel.Hud.Menu.WidgetTree_1.magic_details.WidgetTree_2.Magic_Castable_Name")
local detailsPanel = obj("WBP_ModernMenu_MagicDetails_C", "magic_details", { Magic_Castable_Name = titleWrapper },
  "/Game/Maps/L.L:PersistentLevel.Hud.Menu.WidgetTree_1.magic_details")
HOVERED = nil
setmetatable(added, { __index = function(t, k) if k == "ModernAddedItemEffectsList" then return arr(HOVERED and SPELL_EFFECTS[HOVERED] or {}) end end })
local namedList = {}
local requests = 0
local comp = obj("C", "AEPC")
setmetatable(comp, { __index = function(t, k) if k == "ActiveEffectList" then return arr(namedList) end end })
local player = obj("BP_OblivionPlayerCharacter_C", "Player", { ActiveEffectsPairingComponent = comp,
  RequestActiveEffectsFromOG = function()
    requests = requests + 1
    if SCEN == "names" then
      namedList = {}
      local nm = { "Caméléon", "Vision nocturne", "Renfort : Volonté", "Renfort : Intelligence", "Renfort de Magie" }
      local mag = { 100, 0, 100, 100, 100 }
      for i, e in ipairs(effects) do
        local rem = e.dur - (gameTime - e.start)
        if gameTime >= e.start and rem > 0 then namedList[#namedList + 1] = { EffectName = text(nm[i]), AdditionalEffectName = text(""), Magnitude = mag[i], RemainingDuration = rem } end
      end
      namedList[#namedList + 1] = { EffectName = text("Vampirisme"), AdditionalEffectName = text(""), Magnitude = 100, RemainingDuration = 0 }
    end
  end })
local registry = { WBP_ModernMenu_MagicDetails_C = { detailsPanel }, VAltarTextBlock = { title }, VAddedEffectsListViewModel = { added }, WBP_ModernHud_EffectIcons_C = { tIcons, icons }, TextBlock = { tb }, BP_OblivionPlayerCharacter_C = { player }, VHUDMainViewModel = { vm }, VMagicMenuViewModel = { mm } }
for c, b in pairs(bars) do registry[c] = { tBars[c], b } end
local lib = obj("SlateBlueprintLibrary", "Default__SlateBlueprintLibrary")
lib.GetLocalSize = function(self, g) return { X = g.rect[3] - g.rect[1], Y = g.rect[4] - g.rect[2] } end
lib.LocalToAbsolute = function(self, g, p) return { X = g.rect[1] + p.X, Y = g.rect[2] + p.Y } end
lib.AbsoluteToLocal = function(self, g, p) return { X = (p.X - g.rect[1]) / 1.5, Y = (p.Y - g.rect[2]) / 1.5 } end
FindAllOf = function(n) return registry[n] end
FindFirstOf = function(n) return registry[n] and registry[n][1] end
local gs = obj("GameplayStatics", "GS"); gs.GetTimeSeconds = function() return gameTime end; gs.GetRealTimeSeconds = function() return fakeNow end
StaticFindObject = function(p) if p:find("SlateBlueprintLibrary") then return lib end if p:find("GameplayStatics") then return gs end return obj("Class", p) end
EFindName = { FNAME_Add = 1 }
FName = function(s) return { ToString = function() return s end } end
FText = function(s) return s end
StaticConstructObject = function(cls, outer, name)
  local cn = cls.__name:match("UMG%.(.*)")
  if outer.__full then error("constructed inside a TEMPLATE: " .. outer.__full) end
  local o = (cn == "GridPanel" or cn == "CanvasPanel") and panel(cn, name:ToString()) or obj(cn, name:ToString())
  o.__outer = outer
  if cn == "TextBlock" then o.Font = { OutlineSettings = {} } end
  if cn == "ProgressBar" then
    o.WidgetStyle = { BackgroundImage = {}, FillImage = {} }
    o.SetPercent = function(self, f) self.percent = f end
    o.SetFillColorAndOpacity = function(self, c) self.fill = c end
  end
  if cn == "GridPanel" then o.SetColumnFill = function(self, i, v) self.fill = { i, v } end end
  if cn == "SizeBox" then
    o.SetWidthOverride = function(self, w) self.width = w end
    o.SetHeightOverride = function(self, h) self.height = h end
    o.SetContent = function(self, c) self.content = c end
  end
  o.SetText = function(self, t) self.text = t end
  o.SetBrushFromTexture = function(self, t) self.tex = t end
  for _, m in ipairs({"SetFont","SetColorAndOpacity","SetShadowOffset","SetShadowColorAndOpacity","SetJustification","SetDesiredSizeOverride"}) do o[m] = function() end end
  return o
end
LoopAsync = function(ms, f) loopFn = f end
ExecuteInGameThread = function(f) f() end
RegisterKeyBind = function(k, m, f) keyFn = f end
RegisterHook = function(p, f) hooks[p] = f end
Key = { F7 = 1 }; ModifierKey = { CONTROL = 1 }
package.path = arg[1] .. "/?.lua;" .. package.path
QUIET = true
local realPrint = print
print = function(s) if not QUIET or s:find("placement") or s:find("spell book") or s:find("cast") or s:find("hover") then io.write(s) end end
dofile(arg[1] .. "/main.lua")
local function step(sec, pause)
  for _ = 1, math.floor(sec / 0.25) do
    fakeNow = fakeNow + 0.25
    if not pause then gameTime = gameTime + 0.25 end
    -- PAGESTUCK=1 (with STUCK=1 HUD_CAP=3): the menu is opened at 128 while the hidden Volonté
    -- cast and two of the archer spell's effects are rebuilt: none of them is permanent.
    if os.getenv("PAGESTUCK") == "1" and not PAGE_OPENED and gameTime >= 128 then
      PAGE_OPENED = true
      local function act(name, icon, mag) return { Name = text(name), Icon = T(icon), Type = 8, Property = mag } end
      mm.Inventory = arr({
        act("Caméléon", "T_chameleon_illusion", 100), act("Vision nocturne", "T_night_eye_illusion", 0),
        act("Renfort : Agilité", "T_fortify_restoration", 100), act("Renfort : Archerie", "T_fortify_restoration", 30),
        act("Renfort : Volonté", "T_fortify_restoration", 10), act("Renfort : Chance", "T_fortify_restoration", 10),
        act("Renfort de Magie", "T_fortify_magicka_ultiplier_restoration", 100) })
    end
    if POOL and not POOL_OPENED and gameTime >= 118 then
      POOL_OPENED = true
      local function act(name, icon, mag) return { Name = text(name), Icon = T(icon), Type = 8, Property = mag } end
      local page = {
        act("Caméléon", "T_chameleon_illusion", 100), act("Vision nocturne", "T_night_eye_illusion", 0),
        act("Renfort : Agilité", "T_fortify_restoration", 120), act("Renfort : Archerie", "T_fortify_restoration", 30),
        act("Renfort de Magie", "T_fortify_magicka_ultiplier_restoration", 100),
        act("Renfort de Santé", "T_fortify_restoration", 25), act("Renfort : Discrétion", "T_fortify_restoration", 27),
        act("Renfort : Chance", "T_fortify_restoration", 10) }
      mm.Inventory = arr(page)
    end
    if HOVERED and HOVER_HOOK then HOVER_HOOK(nil, { get = function() return HOVERED end }) end
    loopFn()
    if ORDER_TRACE then ORDER_TRACE() end
  end
end
-- main menu: player exists but no fade yet -> nothing happens, no request
step(3)
realPrint("main menu: attached=" .. tostring(#root.children > 0) .. " requests=" .. requests)
hooks["/Script/Altar.VLevelChangeData:OnFadeToGameBeginEventReceived"]()
step(1)
realPrint("after fade+1s: attached=" .. tostring(#root.children > 0) .. " requests=" .. requests .. " template untouched=" .. tostring(#tRoot.children == 0 and tBox.vis == nil))
local hoverHook = hooks["/Script/Altar.VMagicMenuViewModel:RegisterSendItemHoverHandler"]
HOVER_HOOK = hoverHook
local function hoverSpell(idx) HOVERED = idx; hoverHook(nil, { get = function() return idx end }) end
hoverSpell(3007); step(1, true)    -- quick look at the decoy
hoverSpell(3049); step(2, true)   -- the spell that will be cast
hoverSpell(3050); step(2, true)   -- decoy with the same icons
if FULL or PARTIAL or STUCK then for _, id in ipairs({ 3060, 3061, 3070, 3071, 3080, 3081 }) do hoverSpell(id); step(1, true) end end
if BOW then for _, id in ipairs({ 3090, 3091, 3092 }) do hoverSpell(id); step(1, true) end end
if CHAM then for _, id in ipairs({ 3093, 3094 }) do hoverSpell(id); step(1, true) end end
if os.getenv("SELFDISPEL") == "1" then hoverSpell(3095); step(1, true) end
if os.getenv("DECOY") == "1" then hoverSpell(3096); step(1, true) end
if EXPLORE then hoverSpell(3097); step(1, true) end
HOVERED = nil
-- DELETED=1: "Puissance du mage" is deleted in game after being learned: the book forgets it.
if os.getenv("DELETED") == "1" then
  for i, it in ipairs(INV) do if it.Name.ToString() == "Puissance du mage" then table.remove(INV, i); break end end
end
step(9)          -- includes the fortify cast at gameTime 108
step(10, true)   -- paused (menu open)
step(5)
local canvas = root.children[1]
if os.getenv("TRACE_ORDER") then
  local lastOrder, changes = nil, 0
  ORDER_TRACE = function()
    local holder = canvas.children[1]; local tbl = holder.content or holder
    local rows = {}
    for _, c in ipairs(tbl.children) do
      if c.vis ~= 1 and c.Slot.Column == 1 and c.text then rows[c.Slot.Row] = c.text end
    end
    local names = {}
    for r = 0, 60, 2 do if rows[r] then names[#names + 1] = rows[r]:sub(1, 14) end end
    local o = table.concat(names, " | ")
    if o ~= lastOrder then changes = changes + 1; realPrint(string.format("t=%.2f %s", gameTime, o)); lastOrder = o end
  end
end
local holder = canvas.children[1]
local our = holder.content or holder
realPrint("holder " .. holder.__class .. " width " .. tostring(holder.width) .. " column fill " .. tostring(our.fill and our.fill[1]))
local function show(title)
  canvas = root.children[#root.children]
  local holder = canvas.children[1]
  our = holder.content or holder
  realPrint(title .. string.format("  (game time %.1f, requests %d)", gameTime, requests))
  local rows = {}
  for _, c in ipairs(our.children) do
    if c.vis ~= 1 then
      local r = c.Slot.Row; rows[r] = rows[r] or {}
      local v
      if c.__class == "Image" then v = c.tex and c.tex.__name or "-"
      elseif c.__class == "SizeBox" then
        local n = math.floor((c.content.percent or 0) * 20 + 0.5)
        v = (c.vis == 2 and "(no bar)" or ("[" .. string.rep("#", n) .. string.rep(".", 20 - n) .. "]")) .. (c.content.fill and c.content.fill.R > 0.9 and " warn" or "")
      else v = c.text end
      rows[r][c.Slot.Column] = v
    end
  end
  for r = 0, 60, 2 do local x = rows[r]; if x then
    realPrint(string.format("   %-40s | %-24s | %s", x[0] or "", x[1] or "", x[2] or ""))
    local b = rows[r + 1]; if b then realPrint(string.format("   %-40s   %s", "", b[1] or "")) end
  end end
end
show("list:")
realPrint("true remaining: cham " .. (100 - (gameTime - 59)) .. ", night " .. (300 - (gameTime - 64)) .. ", fortify " .. (60 - (gameTime - 108)))
if os.getenv("RELOAD") == "1" then
  -- Loading screen: the game makes a new view model; the old one stays valid but frozen (empty).
  hooks["/Script/Altar.VLevelChangeData:OnFadeToBlackBeginEventReceived"]()
  step(2, true)
  local vm2 = obj("VHUDMainViewModel", "VM2")
  setmetatable(vm2, mt)
  setmetatable(vm, { __index = function(_, k)
    if k == "EffectsIcons" or k == "EffectsTimeLeft" then return arr({}) end
    return mt.__index(vm, k)
  end })
  mainWidget.HUDMainViewModel = vm2
  registry.VHUDMainViewModel = { vm, vm2 }
  -- TELEPORT=1: 20 s of game time pass during the loading screen (a teleport, fast travel).
  if os.getenv("TELEPORT") == "1" then gameTime = gameTime + 20 end
  -- LOADSAVE=1: the loading screen loads an older save: effects are 10 s less far along, and
  -- magicka is 57 lower, without any cast.
  if os.getenv("LOADSAVE") == "1" then
    for _, e in ipairs(effects) do e.start = e.start + 10 end
    MAGOFF = 57
  end
  hooks["/Script/Altar.VLevelChangeData:OnFadeToGameBeginEventReceived"]()
  canvas = root.children[#root.children]
end
step(20)
show("20s later:")
step(30)
show("30s later (fortify expired, chameleon expired):")
realPrint("canvas vis " .. tostring(canvas.vis) .. " holder pos " .. canvas.cslot.pos.X .. "," .. canvas.cslot.pos.Y .. " table vis " .. tostring(our.vis) .. " anchors " .. (canvas.cslot.anchors and canvas.cslot.anchors.Minimum.Y or "?"))

-- Ctrl+F7 dump at the end
keyFn()
