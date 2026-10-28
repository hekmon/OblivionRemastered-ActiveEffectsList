--[[
    Active Effects List
    Replaces the HUD's row of active-effect icons with a column:
        [icon] Effect name ........ time left
    sorted so the effect that expires first sits at the bottom, right above the bars.

    Data sources (both maintained by the game):
      * Player.ActiveEffectsPairingComponent.ActiveEffectList
            names, magnitude and remaining seconds (read only; never call RequestActiveEffectsFromOG)
      * VHUDMainViewModel.EffectsIcons / EffectsTimeLeft
            the icons the vanilla HUD shows

    Layout: WBP_ModernHud_Main's root Overlay (MainRoot) gets an extra full-size CanvasPanel.
    Our table lives in that canvas and is moved every update so that its bottom-left corner
    sits just above the on-screen position of the health / magicka / fatigue bars. Nothing in
    the existing layout is moved, so it works with Better HUD's offsets and with the vanilla HUD.
    The original icons are hidden (not collapsed, so the bars keep their place).
]]

local config = require("config")
local OrderRows -- defined further down

if config.ProbeOnly then
    require("probe")
    return
end

local MOD = "[ActiveEffectsList]"

-- ESlateVisibility
local VIS_VISIBLE, VIS_COLLAPSED, VIS_HIDDEN, VIS_HIT_TEST_INVISIBLE = 0, 1, 2, 3
-- EHorizontalAlignment / EVerticalAlignment
local ALIGN_FILL, HALIGN_LEFT, HALIGN_RIGHT = 0, 1, 3
local VALIGN_CENTER = 2

local function Log(fmt, ...)
    print(string.format("%s " .. fmt .. "\n", MOD, ...))
end

local function Debug(fmt, ...)
    if config.Debug then Log(fmt, ...) end
end

local function Valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function FullName(obj)
    if not Valid(obj) then return "<invalid>" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and n or "<?>"
end

local function NameOf(obj)
    if not Valid(obj) then return "<invalid>" end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return ok and n or "<?>"
end

local function ClassOf(obj)
    if not Valid(obj) then return "<invalid>" end
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and n or "<?>"
end

local function TextToString(t)
    if t == nil then return "" end
    local ok, s = pcall(function() return t:ToString() end)
    if ok and s then return s end
    return ""
end

-- Objects that belong to a blueprint class (widget templates) or are class defaults.
-- Touching those corrupts the HUD for everyone that is built from them, so never use them.
local function IsTemplate(obj)
    local full = FullName(obj)
    return full == "<invalid>" or full == "<?>"
        or string.find(full, "_C:", 1, true) ~= nil
        or string.find(full, "Default__", 1, true) ~= nil
end

local nameCounter = 0
local function NewName(prefix)
    nameCounter = nameCounter + 1
    return FName(string.format("AEL_%s_%d", prefix, nameCounter), EFindName.FNAME_Add)
end

local classCache = {}
local function UMGClass(name)
    local c = classCache[name]
    if not Valid(c) then
        c = StaticFindObject("/Script/UMG." .. name)
        classCache[name] = c
    end
    return c
end

local function NewWidget(className, outer)
    local cls = UMGClass(className)
    if not Valid(cls) then error("class not found: " .. className) end
    local w = StaticConstructObject(cls, outer, NewName(className))
    if not Valid(w) then error("could not construct " .. className) end
    return w
end

local slateLib = nil
local function SlateLib()
    if not Valid(slateLib) then
        slateLib = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary")
    end
    return slateLib
end

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local state = {
    effectIcons = nil, -- live WBP_ModernHud_EffectIcons_C we attached next to
    bars        = {},  -- live health / magicka / fatigue widgets
    hiddenBox   = nil, -- the original icons container we hid
    canvas      = nil, -- our full-size CanvasPanel inside MainRoot
    canvasSlot  = nil, -- CanvasPanelSlot of our table
    table       = nil, -- our GridPanel
    rows        = {},  -- { icon=Image, name=TextBlock, time=TextBlock, last={...} }
    font        = nil, -- table describing the font copied from the HUD
    player      = nil,
    viewModel   = nil,
    lastPos     = nil,
    lastSignature = nil,
    loggedPlacement = false,
    errors      = 0,
}

----------------------------------------------------------------------------------------------------
-- Finding game objects
----------------------------------------------------------------------------------------------------

local function GetPlayer()
    if Valid(state.player) then return state.player end
    state.player = nil
    local p = FindFirstOf("BP_OblivionPlayerCharacter_C")
    if Valid(p) and not IsTemplate(p) then state.player = p end
    return state.player
end

-- The HUD view model. Read from the HUD widget we are attached to (its HUDMainViewModel), because
-- the game can create a new view model on a loading screen while the old one stays "valid" but
-- frozen. Fallback: the live instances, logged when there are several.
local vmCountLogged = -1
local function GetViewModel()
    local vm = nil
    if Valid(state.effectIcons) then
        pcall(function()
            local main = state.effectIcons:GetOuter():GetOuter() -- WidgetTree -> WBP_ModernHud_Main
            local v = main.HUDMainViewModel
            if Valid(v) and not IsTemplate(v) then vm = v end
        end)
    end
    if not vm then
        local live = {}
        for _, v in ipairs(FindAllOf("VHUDMainViewModel") or {}) do
            if Valid(v) and not IsTemplate(v) then live[#live + 1] = v end
        end
        if #live ~= vmCountLogged and #live > 1 then
            local parts = {}
            for _, v in ipairs(live) do
                parts[#parts + 1] = string.format("%s (%d icons)", NameOf(v), #ReadArray(v.EffectsIcons))
            end
            Debug("%d HUD view models: %s", #live, table.concat(parts, ", "))
        end
        vmCountLogged = #live
        vm = live[#live]
    end
    if vm ~= nil and FullName(vm) ~= state.viewModelName then
        state.viewModelName = FullName(vm)
        Debug("HUD view model: %s", state.viewModelName)
    end
    state.viewModel = vm
    return vm
end

-- Live (non-template) instance of a HUD widget class, placed in a panel.
-- If 'tree' is given, only widgets from that WidgetTree are accepted.
local function FindLiveWidget(className, tree)
    local all = FindAllOf(className)
    if not all then return nil end
    local treeName = tree and FullName(tree)
    for _, w in ipairs(all) do
        if Valid(w) and not IsTemplate(w) then
            local slot = w.Slot
            if Valid(slot) and Valid(slot.Parent) then
                if not treeName or FullName(w:GetOuter()) == treeName then
                    return w
                end
            end
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------------
-- Font: copy the one used by the HUD so the list matches the game's style
----------------------------------------------------------------------------------------------------

local FONT_SOURCE_HINTS = {
    "WBP_ModernHud_Info",
    "WBP_ModernHud_Subtitle",
    "WBP_ModernHud_Compass",
    "WBP_ModernHud_",
}

local function PickFont()
    local blocks = FindAllOf("TextBlock") or {}
    for _, extra in ipairs(FindAllOf("VAltarTextBlock") or {}) do blocks[#blocks + 1] = extra end
    for _, hint in ipairs(FONT_SOURCE_HINTS) do
        for _, tb in ipairs(blocks) do
            if Valid(tb) and not IsTemplate(tb) then
                local full = FullName(tb)
                if string.find(full, hint, 1, true) then
                    local ok, font = pcall(function()
                        local f = tb.Font
                        if not Valid(f.FontObject) then return nil end
                        return {
                            FontObject = f.FontObject,
                            TypefaceFontName = f.TypefaceFontName,
                            Size = config.FontSize,
                            LetterSpacing = 0,
                            SkewAmount = 0.0,
                            bForceMonospaced = false,
                            MonospacedWidth = 1.0,
                            OutlineSettings = {
                                OutlineSize = 1,
                                bSeparateFillAlpha = false,
                                bApplyOutlineToDropShadows = false,
                                OutlineColor = { R = 0, G = 0, B = 0, A = 0.85 },
                            },
                        }
                    end)
                    if ok and font then
                        Debug("font copied from %s (typeface %s)", full, font.TypefaceFontName:ToString())
                        return font
                    end
                end
            end
        end
    end
    Debug("no HUD font found, using the default one")
    return nil
end

----------------------------------------------------------------------------------------------------
-- Building our widgets
----------------------------------------------------------------------------------------------------

-- SetFont() rejects a Lua table for FSlateFontInfo on this UE4SS build, so the font is written
-- field by field into the TextBlock's own Font property, before the widget is first drawn.
local fontWarned = {}
local function SetFontField(tb, field, value)
    local ok, err = pcall(function() tb.Font[field] = value end)
    if not ok and not fontWarned[field] then
        fontWarned[field] = true
        Log("could not set font %s: %s", field, tostring(err))
    end
end

local function StyleText(tb, color, justifyRight)
    SetFontField(tb, "Size", config.FontSize)
    if state.font then
        SetFontField(tb, "FontObject", state.font.FontObject)
        SetFontField(tb, "TypefaceFontName", state.font.TypefaceFontName)
    end
    pcall(function()
        tb.Font.OutlineSettings.OutlineSize = 1
        tb.Font.OutlineSettings.OutlineColor = { R = 0, G = 0, B = 0, A = 0.85 }
    end)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    pcall(function() tb:SetShadowOffset({ X = 1.0, Y = 1.0 }) end)
    pcall(function() tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.75 }) end)
    if justifyRight then
        pcall(function() tb:SetJustification(2) end) -- ETextJustify::Right
    end
end

local function SetCell(slot, hAlign, padRight)
    slot:SetHorizontalAlignment(hAlign)
    slot:SetVerticalAlignment(VALIGN_CENTER)
    slot:SetPadding({ Left = 0, Top = 0, Right = padRight, Bottom = 0 })
end

-- Thin bar showing the fraction of the duration left: a ProgressBar inside a SizeBox that fixes
-- its height. The style is written field by field before the first draw (see StyleText).
local function CreateBar(outer)
    local box = NewWidget("SizeBox", outer)
    box:SetHeightOverride(config.BarHeight)
    local bar = NewWidget("ProgressBar", outer)
    pcall(function()
        -- ESlateBrushDrawType::Image: stretch the textures (box margins look wrong at a few pixels).
        bar.WidgetStyle.BackgroundImage.DrawAs = 3
        bar.WidgetStyle.FillImage.DrawAs = 3
        bar.WidgetStyle.BackgroundImage.TintColor = { SpecifiedColor = config.BarBackgroundColor, ColorUseRule = 0 }
    end)
    pcall(function() bar:SetFillColorAndOpacity(config.BarColor) end)
    bar:SetPercent(1.0)
    box:SetContent(bar)
    return box, bar
end

local function CreateRow(index)
    local outer = state.table:GetOuter()
    local r = (index - 1) * 2 -- grid rows are 0-based; each effect uses a text row and a bar row

    local icon = NewWidget("Image", outer)
    local name = NewWidget("TextBlock", outer)
    local time = NewWidget("TextBlock", outer)

    pcall(function() icon:SetDesiredSizeOverride({ X = config.IconSize, Y = config.IconSize }) end)
    StyleText(name, config.NameColor, false)
    StyleText(time, config.TimeColor, true)
    -- Long names end with "..." instead of running into the time.
    pcall(function() name:SetClipping(1) end)           -- EWidgetClipping::ClipToBounds
    pcall(function() name:SetTextOverflowPolicy(1) end) -- ETextOverflowPolicy::Ellipsis

    local iconSlot = state.table:AddChildToGrid(icon, r, 0)
    SetCell(iconSlot, HALIGN_LEFT, 6)
    SetCell(state.table:AddChildToGrid(name, r, 1), HALIGN_LEFT, 14)
    SetCell(state.table:AddChildToGrid(time, r, 2), HALIGN_RIGHT, 0)

    local barBox, bar = nil, nil
    if config.ShowBar then
        iconSlot:SetRowSpan(2) -- icon centered on text + bar
        barBox, bar = CreateBar(outer)
        local barSlot = state.table:AddChildToGrid(barBox, r + 1, 1)
        barSlot:SetColumnSpan(2)
        barSlot:SetHorizontalAlignment(ALIGN_FILL)
        barSlot:SetVerticalAlignment(VALIGN_CENTER)
        barSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = config.RowSpacing })
    end

    local row = { icon = icon, name = name, time = time, barBox = barBox, bar = bar, last = {} }
    state.rows[index] = row
    return row
end

local function Detach()
    -- Our widgets die with the HUD; only restore what we changed if it still exists.
    if Valid(state.hiddenBox) then
        pcall(function() state.hiddenBox:SetVisibility(VIS_VISIBLE) end)
    end
    if Valid(state.canvas) then
        pcall(function() state.canvas:RemoveFromParent() end)
    end
    state.effectIcons, state.hiddenBox, state.canvas, state.canvasSlot, state.table = nil, nil, nil, nil, nil
    state.bars, state.rows, state.lastPos = {}, {}, nil
end

local function DumpLayout(effectIcons)
    Log("---- layout around %s ----", FullName(effectIcons))
    local w = effectIcons
    local depth = 0
    while Valid(w) and depth < 12 do
        local slot = w.Slot
        local extra = ""
        if Valid(slot) and ClassOf(slot) == "GridSlot" then
            extra = string.format(" row=%d col=%d", slot.Row, slot.Column)
        end
        Log("  %s (%s) slot=%s%s", NameOf(w), ClassOf(w), ClassOf(slot), extra)
        if not Valid(slot) then break end
        w = slot.Parent
        depth = depth + 1
    end
end

-- Returns true when our table is in place.
local function EnsureAttached()
    if Valid(state.effectIcons) and Valid(state.table) and Valid(state.canvas) and Valid(state.canvas.Slot) then
        return true
    end
    Detach()

    -- Only attach in game, once the HUD exists.
    if not GetPlayer() then return false end
    local effectIcons = FindLiveWidget("WBP_ModernHud_EffectIcons_C")
    if not effectIcons then return false end

    local tree = effectIcons:GetOuter()          -- WBP_ModernHud_Main's WidgetTree (instance)
    if not Valid(tree) or IsTemplate(tree) or ClassOf(tree) ~= "WidgetTree" then return false end
    local root = tree.RootWidget                 -- MainRoot (Overlay)
    if not Valid(root) or ClassOf(root) ~= "Overlay" then
        Log("unexpected HUD root (%s), not attaching", ClassOf(root))
        return false
    end

    local bars = {}
    for _, cls in ipairs({ "WBP_ModernHud_Health_C", "WBP_ModernHud_Magicka_C", "WBP_ModernHud_Fatigue_C" }) do
        local b = FindLiveWidget(cls, tree)
        if b then bars[#bars + 1] = b end
    end
    if #bars == 0 then
        Log("health / magicka / fatigue bars not found, not attaching")
        return false
    end

    if config.Debug then DumpLayout(effectIcons) end
    if not state.font then state.font = PickFont() end

    -- Full-size canvas on top of the HUD's root overlay.
    local canvas = NewWidget("CanvasPanel", tree)
    local overlaySlot = root:AddChildToOverlay(canvas)
    overlaySlot:SetHorizontalAlignment(ALIGN_FILL)
    overlaySlot:SetVerticalAlignment(ALIGN_FILL)
    canvas:SetVisibility(VIS_HIT_TEST_INVISIBLE)

    -- Our table, pinned by its bottom-left corner. With a fixed width (ListWidth), the name column
    -- stretches so the times line up on the right edge.
    local tbl = NewWidget("GridPanel", tree)
    tbl:SetVisibility(VIS_HIT_TEST_INVISIBLE)
    local holder = tbl
    if (config.ListWidth or 0) > 0 then
        holder = NewWidget("SizeBox", tree)
        holder:SetWidthOverride(config.ListWidth)
        holder:SetVisibility(VIS_HIT_TEST_INVISIBLE)
        holder:SetContent(tbl)
        tbl:SetColumnFill(1, 1.0)
    end
    local slot = canvas:AddChildToCanvas(holder)
    slot:SetAutoSize(true)
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    slot:SetAlignment({ X = 0, Y = 1 })
    slot:SetPosition({ X = 0, Y = 0 })
    tbl:SetVisibility(VIS_COLLAPSED) -- shown once we know where to put it

    -- Hide the original icons (Hidden keeps their space, so nothing else moves).
    if config.HideOriginalIcons then
        local box = effectIcons.Slot.Parent
        if Valid(box) and ClassOf(box) == "SizeBox" then
            box:SetVisibility(VIS_HIDDEN)
            state.hiddenBox = box
        else
            effectIcons:SetVisibility(VIS_HIDDEN)
            state.hiddenBox = effectIcons
        end
    end

    state.effectIcons = effectIcons
    state.bars = bars
    state.canvas = canvas
    state.canvasSlot = slot
    state.table = tbl
    state.rows = {}
    state.lastSignature = nil
    state.lastPos = nil
    state.loggedPlacement = false
    state.placeMode, state.placeTries = nil, 0
    Log("attached to %s", FullName(root))
    return true
end

----------------------------------------------------------------------------------------------------
-- Placement: just above the bars, wherever the HUD draws them
----------------------------------------------------------------------------------------------------

-- Absolute (screen) rectangle of a widget as last painted, or nil.
local function AbsRect(w)
    local lib = SlateLib()
    local geo = w:GetCachedGeometry()
    local size = lib:GetLocalSize(geo)
    if size.X <= 0 or size.Y <= 0 then return nil end
    local a = lib:LocalToAbsolute(geo, { X = 0, Y = 0 })
    local b = lib:LocalToAbsolute(geo, { X = size.X, Y = size.Y })
    return math.min(a.X, b.X), math.min(a.Y, b.Y), math.max(a.X, b.X), math.max(a.Y, b.Y)
end

local placeFailures = {}
local function PlaceFailed(what, err)
    if not placeFailures[what] then
        placeFailures[what] = true
        Log("placement: %s (%s)", what, tostring(err))
    end
end

-- Fixed position (HUD units from the bottom-left corner), used when the bars cannot be measured.
local function PlaceFallback()
    if state.placeMode ~= "fallback" then
        state.canvasSlot:SetAnchors({ Minimum = { X = 0, Y = 1 }, Maximum = { X = 0, Y = 1 } })
        state.canvasSlot:SetPosition({ X = config.FallbackLeft + config.OffsetX, Y = -config.FallbackBottom + config.OffsetY })
        state.placeMode = "fallback"
        state.lastPos = { X = config.FallbackLeft, Y = -config.FallbackBottom }
        Log("placement: using the fixed position (FallbackLeft=%d, FallbackBottom=%d)", config.FallbackLeft, config.FallbackBottom)
    end
    return true
end

local function Place()
    if state.placeMode == "fallback" then return true end
    state.placeTries = (state.placeTries or 0) + 1

    local left, top
    for _, bar in ipairs(state.bars) do
        if Valid(bar) then
            local ok, x1, y1 = pcall(AbsRect, bar)
            if ok and x1 then
                left = left and math.min(left, x1) or x1
                top = top and math.min(top, y1) or y1
            elseif not ok then
                PlaceFailed("bar geometry", x1)
            end
        end
    end

    local p
    if left then
        local lib = SlateLib()
        local ok, res = pcall(function()
            local canvasGeo = state.canvas:GetCachedGeometry()
            local size = lib:GetLocalSize(canvasGeo)
            if size.X <= 0 or size.Y <= 0 then error("canvas has no size yet") end
            return lib:AbsoluteToLocal(canvasGeo, { X = left, Y = top })
        end)
        if ok and res then p = res else PlaceFailed("canvas geometry", res) end
    else
        PlaceFailed("bars", "no bar with a size on screen")
    end

    if not p then
        if state.lastPos then return true end
        -- About 3 seconds without a measurement: use the fixed position.
        if state.placeTries * config.UpdateIntervalMs >= 3000 then return PlaceFallback() end
        return false
    end

    local x = p.X + config.OffsetX
    local y = p.Y - config.GapAboveBars + config.OffsetY
    local last = state.lastPos
    if not last or math.abs(last.X - x) > 0.5 or math.abs(last.Y - y) > 0.5 then
        state.canvasSlot:SetPosition({ X = x, Y = y })
        state.lastPos = { X = x, Y = y }
        if config.Debug and not state.loggedPlacement then
            Log("bars top-left on screen = (%.1f, %.1f), list bottom-left in HUD = (%.1f, %.1f)", left, top, x, y)
            state.loggedPlacement = true
        end
    end
    return true
end

----------------------------------------------------------------------------------------------------
-- Reading effects
----------------------------------------------------------------------------------------------------

local function ReadArray(arr)
    local out = {}
    if arr == nil then return out end
    pcall(function()
        arr:ForEach(function(_, elem) out[#out + 1] = elem:get() end)
    end)
    return out
end

local function Round(x)
    return math.floor(x + 0.5)
end

local function Now()
    return os.clock() -- wall-clock seconds on Windows (MSVC)
end

----------------------------------------------------------------------------------------------------
-- In-game detection (the old engine thread must be running before some game functions are safe)
----------------------------------------------------------------------------------------------------

local inGame = { active = false, since = 0, hooked = false }

local okFade = pcall(function()
    RegisterHook("/Script/Altar.VLevelChangeData:OnFadeToGameBeginEventReceived", function()
        inGame.active = true
        inGame.since = Now()
        inGame.reload = true -- re-find the player, HUD and view model after a loading screen
    end)
    RegisterHook("/Script/Altar.VLevelChangeData:OnFadeToBlackBeginEventReceived", function()
        inGame.active = false
    end)
end)
inGame.hooked = okFade

local function InGameFor(seconds)
    return inGame.hooked and inGame.active and (Now() - inGame.since) >= seconds
end

local iconTextures = {} -- icon texture name -> UTexture2D, remembered from everything we read

local function RememberTexture(tex)
    if Valid(tex) then
        local n = NameOf(tex)
        if n ~= "<invalid>" and n ~= "<?>" then iconTextures[n] = tex end
    end
end

----------------------------------------------------------------------------------------------------
-- Source 1: HUD view model (always safe): icon + fraction of the duration left
----------------------------------------------------------------------------------------------------

-- Effects are tracked across updates so we can turn the fraction into seconds:
-- duration = active time elapsed / fraction consumed, remaining = fraction * duration.
local tracker = {
    entries = {},    -- { icon, iconName, f0, t0, f, duration }
    activeClock = 0, -- seconds of unpaused game time we observed
    pending = 0,     -- time since the last observed change (not yet credited)
    lastReal = nil,
    lastFractions = "",
    -- diagnostics
    changes = 0, longGaps = 0, maxGap = 0, lastChange = nil, lastDiag = 0,
}

local function ReadHud(vm)
    local out = {}
    if not vm then return out end
    local icons = ReadArray(vm.EffectsIcons)
    local times = ReadArray(vm.EffectsTimeLeft)
    for i, tex in ipairs(icons) do
        if Valid(tex) then
            RememberTexture(tex)
            out[#out + 1] = { icon = tex, iconName = NameOf(tex), f = tonumber(times[i]) or 0 }
        end
    end
    return out
end

local function UpdateTracker(hud, running)
    local now = Now()
    local dt = tracker.lastReal and math.max(0, now - tracker.lastReal) or 0
    tracker.lastReal = now

    local parts = {}
    for _, h in ipairs(hud) do parts[#parts + 1] = string.format("%.5f", h.f) end
    local sig = table.concat(parts, ";")
    tracker.pending = tracker.pending + dt

    -- Match the new list against the previous one (see below).
    local old = tracker.entries
    local new = {}
    local kept = {}
    -- Entries missing from the HUD for less than a second ("ghosts"): the game's list can drop
    -- effects for an update (seen while recasting quickly) and give them back unchanged.
    tracker.ghosts = tracker.ghosts or {}
    local function Resurrect(h)
        local best, bestDiff
        for i, g in ipairs(tracker.ghosts) do
            local diff = g.e.f - h.f
            if g.e.iconName == h.iconName and diff >= -0.01 and diff <= 0.05 and (not best or diff < bestDiff) then
                best, bestDiff = i, diff
            end
        end
        if not best then return nil end
        return table.remove(tracker.ghosts, best).e
    end
    -- The list is not always in cast order (after overflowing, the game reordered it: effects
    -- were lost, a false dispel dropped rebuilt armor pieces). So each HUD item takes, among
    -- unused entries with its icon: 1. the first, in the old order, that continues smoothly
    -- (same or slightly lower fraction); 2. else the closest above it (a jump: game time passed
    -- during a loading screen). A fraction going up is a new effect (recast).
    local matchOf = {}
    for i, h in ipairs(hud) do
        for _, o in ipairs(old) do
            if not kept[o] and o.iconName == h.iconName and h.f <= o.f + 0.01 and o.f - h.f <= 0.03 then
                matchOf[i] = o; kept[o] = true; break
            end
        end
    end
    for i, h in ipairs(hud) do
        if not matchOf[i] then
            local best
            for _, o in ipairs(old) do
                if not kept[o] and o.iconName == h.iconName and h.f <= o.f + 0.01 and (not best or o.f < best.f) then
                    best = o
                end
            end
            if best then matchOf[i] = best; kept[best] = true end
        end
    end
    for i, h in ipairs(hud) do
        local matched = matchOf[i]
        local e = matched
        if e then
            e.prevF = e.f
        else
            -- Back from a ghost: not a time reference (its time was counted while it was gone).
            e = Resurrect(h)
            if e then e.prevF = nil end
        end
        if not e then
            tracker.uidCounter = (tracker.uidCounter or 0) + 1
            e = { iconName = h.iconName, f0 = h.f, born = now, uid = tracker.uidCounter, isNew = true }
        end
        e.icon, e.f = h.icon, h.f
        new[#new + 1] = e
    end

    -- Advance the clock only while fractions move (they freeze when the game is paused).
    if #hud == 0 then
        -- No effect on the HUD: nothing to watch, follow real time while the game runs (rebuilt
        -- effects keep counting down).
        if running then tracker.activeClock = tracker.activeClock + math.min(dt, 1.0) end
        tracker.pending = 0
        tracker.lastFractions = ""
    elseif sig ~= tracker.lastFractions then
        if tracker.lastChange then
            local gap = now - tracker.lastChange
            if gap > tracker.maxGap then tracker.maxGap = gap end
            if gap > 2.0 then tracker.longGaps = tracker.longGaps + 1 end
        end
        tracker.lastChange = now
        tracker.changes = tracker.changes + 1
        -- An effect whose duration is known (recognized cast) or settled measures the game time
        -- that passed: fraction used x duration. That holds across pauses and across loading
        -- screens where game time passes (a teleport took 20 % of a 20 min effect at once).
        local ref, refDuration, refKnown
        for _, e in ipairs(new) do
            local d = e.knownDuration or (e.durSettled and e.duration)
            if d and e.prevF and e.prevF > e.f then
                local known = e.knownDuration ~= nil
                if not ref or (known and not refKnown) or (known == refKnown and d > refDuration) then
                    ref, refDuration, refKnown = e, d, known
                end
            end
        end
        local credit
        if ref then
            credit = (ref.prevF - ref.f) * refDuration
        else
            -- After a long freeze (pause), only the last update interval was game time.
            credit = tracker.pending
            if credit > 2.0 then credit = math.min(dt, config.UpdateIntervalMs / 1000) end
        end
        tracker.activeClock = tracker.activeClock + credit
        tracker.pending = 0
        tracker.lastFractions = sig
    end
    local clock = tracker.activeClock

    for _, e in ipairs(new) do
        if e.isNew then e.isNew, e.t0 = nil, clock end
        local used = e.f0 - e.f
        local elapsed = clock - e.t0
        if e.knownDuration then
            e.duration = e.knownDuration
        elseif used >= 0.003 and elapsed >= 1.0 then
            local d = elapsed / used
            if d > 5 then d = Round(d) end -- spell durations are whole seconds
            e.duration = d
            -- The estimate is "settled" once it has held within 5 % for a second of game time.
            -- Right after a menu it can creep up for a while (17, 20, 22 s... for a 60 s spell).
            if e.durRef and math.abs(d - e.durRef) <= math.max(1, e.durRef * 0.05) then
                if clock - e.durRefAt >= 1.0 then e.durSettled = true end
            else
                e.durRef, e.durRefAt, e.durSettled = d, clock, false
            end
        end
    end
    -- Entries gone with time still left: removed by the game (dispel, cure...), not expired.
    -- Decided once they have been gone for a second (see ghosts above).
    for _, o in ipairs(old) do
        if not kept[o] then
            local back = false
            for _, e in ipairs(new) do if e == o then back = true end end
            -- From a full HUD list, an effect can be pushed out by a new one (it is hidden, not
            -- removed): seen as false dispels while the list was full.
            -- A dispel empties the list instead: only a list that stays full counts.
            local full = #old >= config.HudLimit and #hud >= config.HudLimit
            if not back then tracker.ghosts[#tracker.ghosts + 1] = { e = o, since = now, full = full } end
        end
    end
    tracker.removedEarly = {}
    tracker.bumped = {}
    local ghosts = {}
    for _, g in ipairs(tracker.ghosts) do
        if now - g.since < 1.0 then
            ghosts[#ghosts + 1] = g
        else
            local o = g.e
            local left = o.duration and (o.f * o.duration) or nil
            if g.full then
                -- hidden by the game: a recognized cast rebuilds it as a stand-in
                tracker.bumped[#tracker.bumped + 1] = o
            elseif (left and left > 1.5) or (not left and o.f > 0.05) then
                tracker.removedEarly[#tracker.removedEarly + 1] = o
            end
        end
    end
    tracker.ghosts = ghosts
    tracker.entries = new
    return new
end

----------------------------------------------------------------------------------------------------
-- Spell book: each spell's effects, learned from the magic menu's detail panel
----------------------------------------------------------------------------------------------------

-- When a spell is hovered in the magic menu, the game fills VAddedEffectsListViewModel with its
-- effects (name, magnitude, duration, icon, range). We remember them per spell name and save
-- them next to the mod, so each spell only needs to be hovered once, ever.

local RANGE_SELF = 0 -- EModernEffectItemRange::Self
local SPELL_TYPES = { [1] = true, [2] = true, [4] = true } -- Target, Touch, OnSelf (not Active = 8)

local spellbook = { spells = {}, count = 0, dirty = false }
local hover = { index = nil, time = 0, since = 0 } -- time = last hover call, since = index changed
local capture = { sig = nil, since = 0 }

local function ModDir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    -- .../Mods/ActiveEffectsList/Scripts/main.lua -> .../Mods/ActiveEffectsList/
    local dir = src:match("^(.*[/\\])[Ss]cripts[/\\][^/\\]+$")
    return dir
end

local SPELLBOOK_FILE = (ModDir() or "") .. "spellbook.txt"

-- Effect label as shown in the magic menu, e.g. "Renfort : Agilité 100".
local function EffectText(name, extra, magnitude)
    local label = name
    if string.find(label, "{0}", 1, true) then
        -- The game's name has a placeholder for the attribute / skill: "Renfort : {0}".
        label = label:gsub("{0}", (extra:gsub("%%", "%%%%")))
    elseif extra ~= "" and not string.find(label, extra, 1, true) then
        label = label .. " " .. extra
    end
    if config.ShowMagnitude and magnitude and magnitude >= 1 then
        label = string.format("%s %d", label, Round(magnitude))
    end
    return label
end

local function LoadSpellbook()
    local f = io.open(SPELLBOOK_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local name, icon, rest, tail = line:match("^(.-)\t(.-)\t([^\t]*)\t?(.*)$")
        if name and name ~= "" then
            local cost, learned = tail:match("^([^\t]*)\t?(.*)$")
            local spell = { icon = icon, effects = {}, cost = tonumber(cost), learned = tonumber(learned) }
            for eff in (rest .. "||"):gmatch("(.-)||") do
                local eicon, label, dur, range = eff:match("^(.-)|(.-)|(.-)|(.-)$")
                if eicon then
                    label = label:gsub("{0}%s*", "")
                    spell.effects[#spell.effects + 1] = {
                        icon = eicon, label = label, duration = tonumber(dur) or 0, range = tonumber(range) or -1,
                    }
                end
            end
            spellbook.spells[name] = spell
            spellbook.count = spellbook.count + 1
            if spell.learned and spell.learned > (spellbook.lastLearned or 0) then spellbook.lastLearned = spell.learned end
        end
    end
    f:close()
    Log("spell book: %d spells loaded from %s", spellbook.count, SPELLBOOK_FILE)
end

local function SaveSpellbook()
    local f = io.open(SPELLBOOK_FILE, "w")
    if not f then
        Log("spell book: cannot write %s", SPELLBOOK_FILE)
        return
    end
    local names = {}
    for n in pairs(spellbook.spells) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        local s = spellbook.spells[n]
        local parts = {}
        for _, e in ipairs(s.effects) do
            parts[#parts + 1] = string.format("%s|%s|%d|%d", e.icon, e.label, e.duration, e.range)
        end
        f:write(n, "\t", s.icon, "\t", table.concat(parts, "||"), "\t", s.cost and string.format("%d", s.cost) or "",
            s.learned and ("\t" .. string.format("%d", s.learned)) or "", "\n")
    end
    f:close()
    spellbook.dirty = false
end

pcall(LoadSpellbook)

pcall(function()
    RegisterHook("/Script/Altar.VMagicMenuViewModel:RegisterSendItemHoverHandler", function(ctx, index)
        local ok, i = pcall(function() return index:get() end)
        if not ok then Log("hover hook: cannot read the index (%s)", tostring(i)) end
        local newIndex = ok and i or nil
        if newIndex ~= hover.index then
            Debug("hover: index %s", tostring(newIndex))
            hover.since = Now()
        end
        hover.index = newIndex
        hover.time = Now()
    end)
end)

local captureNotes = {}
local function Note(fmt, ...)
    local msg = string.format(fmt, ...)
    local key = tostring(hover.index) .. msg
    if not captureNotes[key] then
        captureNotes[key] = true
        Debug("spell book: hover %s: %s", tostring(hover.index), msg)
    end
end

-- The hovered spell's name, read from the detail panel's title text ("Magic_Castable_Name" in
-- WBP_ModernMenu_MagicDetails). The hover index is an internal ID, not a list position.
-- Text of a text widget, or of a user widget wrapping one (WBP_AltarTextBlock: inner "text_block").
local function WidgetText(w)
    if not Valid(w) then return nil end
    local ok, txt = pcall(function() return w:GetText():ToString() end)
    if ok and txt and txt ~= "" then return txt end
    for _, field in ipairs({ "text_block", "TextBlock", "Text_Block" }) do
        local okF, inner = pcall(function() return w[field] end)
        if okF and Valid(inner) then
            local okT, t2 = pcall(function() return inner:GetText():ToString() end)
            if okT and t2 and t2 ~= "" then return t2 end
        end
    end
    local okV, t3 = pcall(function() return w.Text:ToString() end)
    if okV and t3 and t3 ~= "" then return t3 end
    return nil
end

local TEXT_CLASSES = { "VAltarTextBlock", "TextBlock", "CommonTextBlock", "RichTextBlock", "VAltarRichTextBlock" }
local titleDiagLogged = false

-- The hovered spell's name, read from the detail panel's title ("Magic_Castable_Name" in
-- WBP_ModernMenu_MagicDetails). The hover index is an internal ID, not a list position.
local function DetailPanelTitle()
    -- 1. The live detail panel widget and its title widget.
    local panels = 0
    for _, p in ipairs(FindAllOf("WBP_ModernMenu_MagicDetails_C") or {}) do
        if Valid(p) and not IsTemplate(p) then
            panels = panels + 1
            local okW, w = pcall(function() return p.Magic_Castable_Name end)
            if okW and Valid(w) then
                local txt = WidgetText(w)
                if txt then return txt end
                Note("title widget %s (%s) has no readable text", NameOf(w), ClassOf(w))
            else
                Note("detail panel %s has no Magic_Castable_Name", NameOf(p))
            end
        end
    end
    if panels == 0 then Note("no live WBP_ModernMenu_MagicDetails_C") end

    -- 2. Any text widget named / nested under Magic_Castable_Name.
    for _, cls in ipairs(TEXT_CLASSES) do
        for _, tb in ipairs(FindAllOf(cls) or {}) do
            if Valid(tb) and not IsTemplate(tb) and string.find(FullName(tb), "Magic_Castable_Name", 1, true) then
                local txt = WidgetText(tb)
                if txt then return txt end
            end
        end
    end

    -- Diagnostics, once: text widgets that look related to the magic menu.
    if not titleDiagLogged then
        titleDiagLogged = true
        local n = 0
        for _, cls in ipairs(TEXT_CLASSES) do
            for _, tb in ipairs(FindAllOf(cls) or {}) do
                local full = FullName(tb)
                local low = full:lower()
                if n < 40 and Valid(tb) and not IsTemplate(tb) and (low:find("magic", 1, true) or low:find("castable", 1, true)) then
                    n = n + 1
                    Debug("  text widget [%s] %s = '%s'", cls, full:sub(math.max(1, #full - 160)), WidgetText(tb) or "")
                end
            end
        end
        Debug("  (%d magic-related text widgets, %d detail panels)", n, panels)
    end
    return nil
end

local function ItemIndex(it)
    local ok, v = pcall(function() return it.InventoryIndex end)
    return ok and v or nil
end

-- The hovered spell: { name, icon (or nil), type (or nil), source }.
local function HoveredSpell()
    if hover.index == nil then return nil end
    -- 1. by the hover index in the magic menu lists (kept in case it is a list index somewhere)
    for _, mm in ipairs(FindAllOf("VMagicMenuViewModel") or {}) do
        if Valid(mm) and not IsTemplate(mm) then
            for _, listName in ipairs({ "Inventory", "CurrentPageInventory", "FavoritesItems" }) do
                for _, it in ipairs(ReadArray(mm[listName])) do
                    if ItemIndex(it) == hover.index then
                        local okT, typ = pcall(function() return it.Type end)
                        local okP, prop = pcall(function() return tonumber(it.Property) end)
                        return { name = TextToString(it.Name), icon = NameOf(it.Icon), type = okT and typ or nil,
                                 cost = okP and prop or nil, source = listName }
                    end
                end
            end
            break
        end
    end
    -- 2. the detail panel's title, then its icon and type from the lists by name
    local title = DetailPanelTitle()
    if not title then return nil end
    local spell = { name = title, source = "detail panel title" }
    for _, mm in ipairs(FindAllOf("VMagicMenuViewModel") or {}) do
        if Valid(mm) and not IsTemplate(mm) then
            for _, listName in ipairs({ "CurrentPageInventory", "Inventory" }) do
                for _, it in ipairs(ReadArray(mm[listName])) do
                    local okT, typ = pcall(function() return it.Type end)
                    if okT and SPELL_TYPES[typ] and TextToString(it.Name) == title then
                        local okP, prop = pcall(function() return tonumber(it.Property) end)
                        spell.icon, spell.type, spell.cost = NameOf(it.Icon), typ, okP and prop or nil
                        return spell
                    end
                end
            end
            break
        end
    end
    return spell
end

local function ReadAddedEffects()
    for _, vm in ipairs(FindAllOf("VAddedEffectsListViewModel") or {}) do
        if Valid(vm) and not IsTemplate(vm) then
            local list = ReadArray(vm.ModernAddedItemEffectsList)
            if #list > 0 then return list end
        end
    end
    return {}
end

-- Called every update: learn the hovered spell once hover and effect list have been stable.
local function CaptureSpell()
    -- The menu may repeat the hover call every frame: wait for the hovered index to be stable.
    if hover.index == nil or Now() - hover.since < 0.5 then return end
    local list = ReadAddedEffects()
    if #list == 0 then
        Note("effect list empty (%d VAddedEffectsListViewModel found)", #(FindAllOf("VAddedEffectsListViewModel") or {}))
        return
    end

    local effects, parts = {}, {}
    for _, d in ipairs(list) do
        pcall(function() RememberTexture(d.Image) end)
        local e = {
            icon = NameOf(d.Image),
            label = EffectText(TextToString(d.EffectName), TextToString(d.AdditionalEffectName), tonumber(d.Magnitude)),
            duration = tonumber(d.Duration) or 0,
            range = tonumber(d.Range) or -1,
        }
        effects[#effects + 1] = e
        parts[#parts + 1] = string.format("%s|%s|%d|%d", e.icon, e.label, e.duration, e.range)
    end
    local sig = tostring(hover.index) .. "#" .. table.concat(parts, "||")
    if sig ~= capture.sig then
        capture.sig, capture.since = sig, Now()
        return
    end
    if Now() - capture.since < 0.25 or capture.done == sig then return end
    capture.done = sig

    local spell = HoveredSpell()
    if not spell then return end
    local name, icon, source = spell.name, spell.icon, spell.source
    if spell.type ~= nil and not SPELL_TYPES[spell.type] then Note("'%s' has type %s, not a spell", name, tostring(spell.type)) return end
    if name == "" then Note("item without a name") return end
    if not icon then
        -- Not found in the spell lists: the panel may show another tab's item, do not guess.
        Note("'%s' not found in the spell lists, skipped", name)
        return
    end
    -- Sanity check: a spell's list icon is the icon of one of its effects.
    local iconOk = false
    for _, e in ipairs(effects) do if e.icon == icon then iconOk = true end end
    if not iconOk then
        Debug("spell book: '%s' (icon %s) does not match the effect list, skipped", name, icon)
        return
    end

    local old = spellbook.spells[name]
    local changed = not old or #old.effects ~= #effects or (spell.cost and old.cost ~= spell.cost)
    if old and not changed then
        for i, e in ipairs(effects) do
            local o = old.effects[i]
            if o.icon ~= e.icon or o.label ~= e.label or o.duration ~= e.duration or o.range ~= e.range then changed = true end
        end
    end
    if changed then
        if not old then spellbook.count = spellbook.count + 1 end
        -- When it was first learned: a spell recreated under a new name wins over its old copy.
        local learned = old and old.learned
        if not learned then
            learned = math.max(os.time(), (spellbook.lastLearned or 0) + 1) -- strictly increasing
            spellbook.lastLearned = learned
        end
        spellbook.spells[name] = { icon = icon, effects = effects, cost = spell.cost, learned = learned }
        pcall(SaveSpellbook)
        Debug("spell book: learned '%s' (%s, cost %s, from %s): %s", name, icon, tostring(spell.cost), source, table.concat(parts, " ; "))
    end
end

-- icon -> effect label, when every spell in the book agrees (used for unattributed effects).
local function SpellbookLabelForIcon(iconName)
    local found = nil
    for _, s in pairs(spellbook.spells) do
        for _, e in ipairs(s.effects) do
            if e.icon == iconName then
                local base = e.label:gsub("%s+%d+$", "") -- without magnitude
                if found and found ~= base then return nil end
                found = base
            end
        end
    end
    return found
end

----------------------------------------------------------------------------------------------------
-- Casts: effects that appear when magicka drops come from casting the equipped spell
----------------------------------------------------------------------------------------------------

-- The game's HUD list holds at most HudLimit effects (8); extra effects stay hidden until others
-- expire. For recognized casts we know every effect of the spell from the spell book, so effects
-- the HUD cannot show are displayed anyway ("stand-ins"), timed from the cast.

local cast = { lastMagicka = nil, lastDrop = -1000, drop = nil }

-- Cast records: id -> { id, spell, start (tracker.activeClock at cast start), hudFull, slots }
-- slots[k] = tracked entry shown for the spell's k-th self timed effect (nil = not on the HUD).
local castRecords = {}
local castCounter = 0

local function SelfTimed(spell)
    local out = {}
    for k, se in ipairs(spell.effects) do
        if se.range == RANGE_SELF and se.duration > 0 then out[#out + 1] = { k = k, se = se } end
    end
    return out
end

-- Name of the equipped spell from the magic menu, only when it matches the HUD's live spell icon.
local function EquippedSpellName(vm, hudIcon)
    for _, mm in ipairs(FindAllOf("VMagicMenuViewModel") or {}) do
        if Valid(mm) and not IsTemplate(mm) then
            local okC, cur = pcall(function() return mm.CurrentSpellEquiped end)
            if okC and cur and NameOf(cur.Icon) == hudIcon then
                local name = TextToString(cur.Name)
                -- Custom spells come back as a raw text key ("UserInputText_104_471_22"), and a
                -- stale value as "{Item}": not names.
                if name ~= "" and not name:find("^UserInputText") and not name:find("{", 1, true) then return name end
            end
            return nil
        end
    end
    return nil
end

-- Spells from the book whose self timed effects contain these icons.
-- Returns exact matches if any, otherwise spells that have these icons plus others (partial casts:
-- the HUD list was full, or an effect could not apply).
local function SpellsMatching(icons)
    local want = {}
    for _, i in ipairs(icons) do want[i] = (want[i] or 0) + 1 end
    local exact, partial = {}, {}
    for name, s in pairs(spellbook.spells) do
        local have, n = {}, 0
        for _, it in ipairs(SelfTimed(s)) do
            have[it.se.icon] = (have[it.se.icon] or 0) + 1
            n = n + 1
        end
        local contains = true
        for i, c in pairs(want) do if (have[i] or 0) < c then contains = false end end
        if contains then
            if n == #icons then exact[#exact + 1] = name else partial[#partial + 1] = name end
        end
    end
    table.sort(exact)
    table.sort(partial)
    return exact, partial
end

-- Does the magicka spent match the spell's recorded cost? nil = unknown.
-- The measured drop is normally the exact cost; strict = within 2 points / 2 % (used when nothing
-- else confirms the cast), otherwise within 3 points / 10 %.
local function CostMatches(spell, amount, strict)
    if not spell.cost or spell.cost <= 0 or not amount then return nil end
    local tolerance = strict and math.max(2, spell.cost * 0.02) or math.max(3, spell.cost * 0.1)
    return math.abs(spell.cost - amount) <= tolerance
end

-- Spells with the same self timed effects (icons and durations): a spell deleted in game with a
-- mod and recreated under another name leaves its old copy in the book ("Daedric Armor" and
-- "Cuirasse des Abysses": same effects, duration and cost, so no name was shown). Among such
-- identical spells, the one learned last wins. The book never forgets a spell on its own: the
-- game's spell list does not give custom spells' real names (a version that removed spells
-- missing from it erased 18 existing custom spells).
local function Signature(name)
    local parts = {}
    for _, it in ipairs(SelfTimed(spellbook.spells[name])) do
        parts[#parts + 1] = it.se.icon .. "|" .. it.se.duration
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function NewestIfIdentical(list)
    if #list < 2 then return list end
    local sig = Signature(list[1])
    for i = 2, #list do if Signature(list[i]) ~= sig then return list end end
    local best, bestT, tie = nil, -1, false
    for _, n in ipairs(list) do
        local t = spellbook.spells[n].learned or 0
        if t > bestT then best, bestT, tie = n, t, false elseif t == bestT then tie = true end
    end
    if tie then return list end
    return { best }
end

-- Casting a spell again replaces its previous cast (same-spell effects do not stack in
-- Oblivion: the duration restarts). Effects of replaced casts are no longer shown.
local supersededGroups = {}

local function NewRecord(name, start, hudFull)
    castCounter = castCounter + 1
    local rec = { id = "cast" .. castCounter, spell = name, start = start, hudFull = hudFull, slots = {} }
    for id, other in pairs(castRecords) do
        if other.spell == name then
            supersededGroups[id] = true
            castRecords[id] = nil
            Debug("cast: '%s' cast again, previous cast replaced", name)
        end
    end
    castRecords[rec.id] = rec
    return rec
end

local function SlotFree(rec, k, present)
    if rec.gone and rec.gone[k] then return false end
    local e = rec.slots[k]
    return e == nil or not present[e]
end

-- Effects removed before their end (dispel, cure, recast...): their slots are not rebuilt.
-- - all the visible effects of a cast removed: the whole cast is gone (its rebuilt effects too);
-- - effects of two or more casts removed together: a dispel, all rebuilt effects are dropped.
-- A recast removes the effects of a single cast, so other casts are not touched.
-- Removals right after a loading screen are ignored (the game's HUD list is rebuilt then).
local function DropRecord(rec, present)
    local spell = spellbook.spells[rec.spell]
    rec.gone = rec.gone or {}
    if spell then
        for _, it in ipairs(SelfTimed(spell)) do
            if SlotFree(rec, it.k, present) then rec.gone[it.k] = true end
        end
    end
end

-- When effects of each spell last left the HUD before their end (spell name -> time).
local lastRemovedAt = {}

local function ProcessRemovals(removed, present)
    if #removed == 0 then return end
    if not inGame.active or Now() - inGame.since < 3 then return end
    local labels, groups, groupCount = {}, {}, 0
    for _, e in ipairs(removed) do
        if e.spell then lastRemovedAt[e.spell] = Now() end
        labels[#labels + 1] = e.effectLabel or e.iconName
        local g = e.castGroup or ("effect" .. tostring(e.uid))
        -- Effects replaced by a recast of their spell do not count toward a dispel (two quick
        -- recasts were taken for one).
        local recast = e.castGroup and supersededGroups[e.castGroup]
        if not groups[g] and not recast then groups[g] = true; groupCount = groupCount + 1 end
        local rec = e.castGroup and castRecords[e.castGroup]
        if rec then
            for k, slotEntry in pairs(rec.slots) do
                if slotEntry == e then
                    rec.gone = rec.gone or {}
                    rec.gone[k] = true
                end
            end
        end
    end
    local dispel = groupCount >= 2
    for _, rec in pairs(castRecords) do
        local anyVisible, anyRemoved = false, false
        for _, slotEntry in pairs(rec.slots) do
            if present[slotEntry] then anyVisible = true end
        end
        for _, e in ipairs(removed) do
            if e.castGroup == rec.id then anyRemoved = true end
        end
        if dispel or (anyRemoved and not anyVisible) then DropRecord(rec, present) end
    end
    Debug("%d effect(s) of %d cast(s) removed before their end%s: %s", #removed, groupCount,
        dispel and " (dispel: rebuilt effects dropped)" or "", table.concat(labels, ", "))
end

local function Attach(e, rec, k, se)
    rec.slots[k] = e
    e.spell = rec.spell
    e.castGroup = rec.id
    e.effectLabel = se.label
    e.knownDuration = se.duration
    e.duration = se.duration
end

-- Label each effect of the group from the spell's effects (same icon, in order).
local function ApplySpell(group, name, hudFull, present)
    local spell = spellbook.spells[name]
    if not spell then
        -- Not in the book (equipped-spell fallback): name only.
        local rec = NewRecord(name, tracker.activeClock, false)
        for _, e in ipairs(group) do e.spell = name; e.castGroup = rec.id end
        return
    end
    -- Cast start, from the first effect's fraction and the spell's duration for it.
    local start = tracker.activeClock
    for _, it in ipairs(SelfTimed(spell)) do
        if it.se.icon == group[1].iconName then
            start = tracker.activeClock - (1 - group[1].f) * it.se.duration
            break
        end
    end
    local rec = NewRecord(name, start, hudFull)
    for _, e in ipairs(group) do
        for _, it in ipairs(SelfTimed(spell)) do
            if it.se.icon == e.iconName and SlotFree(rec, it.k, present) then
                Attach(e, rec, it.k, it.se)
                break
            end
        end
    end
end

-- An effect that shows up after its cast (hidden by the HUD limit until now): same spell effect
-- icon, and its fraction is where that cast's timer is.
local function JoinCast(e, present)
    for _, rec in pairs(castRecords) do
        local spell = spellbook.spells[rec.spell]
        if spell then
            local elapsed = tracker.activeClock - rec.start
            for _, it in ipairs(SelfTimed(spell)) do
                if it.se.icon == e.iconName and SlotFree(rec, it.k, present) then
                    local expected = 1 - elapsed / it.se.duration
                    if math.abs(expected - e.f) <= 0.02 then
                        Attach(e, rec, it.k, it.se)
                        Debug("cast: late effect joins '%s' (%s)", rec.spell, it.se.label)
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- An effect nobody claimed (cast before the mod started, potion-like timing...): match the spell
-- book by icon and estimated duration, if only one spell fits.
local function MatchLeftover(e, present)
    if e.bookTried or not e.duration then return end
    e.bookTried = true
    local fits, spells = {}, {}
    for name, s in pairs(spellbook.spells) do
        for _, it in ipairs(SelfTimed(s)) do
            if it.se.icon == e.iconName and math.abs(it.se.duration - e.duration) <= math.max(3, it.se.duration * 0.08) then
                fits[#fits + 1] = { name = name, it = it }
                spells[name] = true
            end
        end
    end
    local count = 0
    for _ in pairs(spells) do count = count + 1 end
    if count ~= 1 then return end
    local f = fits[1]
    -- With the HUD full, the spell's other effects may be hidden: rebuild them.
    local hudFull = #tracker.entries >= config.HudLimit
    local rec = NewRecord(f.name, tracker.activeClock - (1 - e.f) * f.it.se.duration, hudFull)
    Attach(e, rec, f.it.k, f.it.se)
    -- Several effects of that spell share the icon (e.g. bound armor pieces): the piece is unknown.
    if #fits > 1 then e.effectLabel = nil end
    Debug("cast: leftover effect %s matched '%s' by duration (%.0fs)", e.iconName, f.name, e.duration)
end

local function AttributeCasts(tracked, vm)
    if not config.ShowSpellNames or not vm then return end
    local now = Now()
    local hudIcon = NameOf(vm.SpellIcon)
    local present = {}
    for _, e in ipairs(tracked) do present[e] = true end
    ProcessRemovals(tracker.removedEarly or {}, present)
    -- Effects pushed out of a full HUD list: their casts are shown with stand-ins from now on.
    for _, e in ipairs(tracker.bumped or {}) do
        local rec = e.castGroup and castRecords[e.castGroup]
        if rec and not rec.hudFull then
            rec.hudFull = true
            Debug("cast: '%s' partly pushed out of the full HUD list, rebuilt", rec.spell)
        end
    end
    local hudFull = #tracked >= config.HudLimit

    -- Magicka drops (a drop spread over a few updates counts as one).
    local okM, m = pcall(function() return tonumber(vm.CurrentMagickaValue) end)
    if okM and m then
        if cast.lastMagicka and m < cast.lastMagicka - 0.5 then
            local d = cast.drop
            if d and not d.handled and now - d.at < 0.6 then
                d.amount = d.amount + (cast.lastMagicka - m)
            else
                cast.drop = { at = now, amount = cast.lastMagicka - m, icon = hudIcon, clock = tracker.activeClock,
                              hudFull = hudFull, hudCount = #tracked, handled = false }
            end
            cast.lastDrop = now
        end
        cast.lastMagicka = m
    end

    -- New effects not attributed yet (an effect gets 8 seconds to be matched with a cast; ties
    -- between spells wait for the duration estimate, about a second after the cast).
    -- Effects of one cast can show up a few updates apart: they give up together, from the first
    -- one's arrival, so a cast is never split and its last effect matched alone to another spell.
    local unattributed = {}
    for _, e in ipairs(tracked) do
        if e.spell == nil and e.born then unattributed[#unattributed + 1] = e end
    end
    local function GroupBorn(e)
        local b = e.born
        for _, o in ipairs(unattributed) do
            if math.abs(o.born - e.born) <= 1.0 and o.born < b then b = o.born end
        end
        return b
    end
    local pending = {}
    for _, e in ipairs(tracked) do
        if e.spell == nil and e.born then
            if JoinCast(e, present) then
                -- attached to an earlier cast
            elseif cast.reloadAt and e.born - cast.reloadAt < 3 and e.born >= cast.reloadAt then
                e.spell = false -- already active when the level loaded
            elseif e.f0 < 0.9 then
                -- First seen well into its timer: an effect the full HUD hid, surfacing now, not a
                -- new cast (seen: a bound armor piece at 53 % took the magicka of "Oeil de la
                -- nuit", cast at that moment).
                e.spell = false
            elseif now - GroupBorn(e) > 8 then
                e.spell = false
            else
                pending[#pending + 1] = e
            end
        end
        -- Leftovers: join a known cast (e.g. one matched by another leftover), else the book.
        if e.spell == false and not JoinCast(e, present) then MatchLeftover(e, present) end
    end

    -- A cast whose effects are all hidden: magicka dropped, nothing new appeared on the HUD.
    -- The game's HUD list is unreliable once it has overflowed: it can keep hiding new effects even
    -- when it shows fewer than HudLimit, so this is checked for every drop. When the HUD is not
    -- full, the spell's recorded cost must match the magicka spent exactly (enemy drains, target
    -- spells and so on must not create effects).
    local d = cast.drop
    if d and not d.handled and now - d.at >= 1.5 then
        d.handled = true
        local visible = false
        for _, e in ipairs(tracked) do
            if e.born and e.born >= d.at - 2 and e.born <= d.at + 1.5 then visible = true end
        end
        -- A dispel cast on self (equipped spell with a self dispel effect, exact cost): every
        -- rebuilt effect goes. When the game's HUD list shows nothing, there is no removal to
        -- see (seen in game: "Dissipation suprême" left the rebuilt Daedric Armor on screen).
        local dispel
        for name, s in pairs(spellbook.spells) do
            if s.icon == d.icon and CostMatches(s, d.amount, true) == true then
                for _, se in ipairs(s.effects) do
                    if se.range == RANGE_SELF and se.icon:find("dispel", 1, true) then dispel = name end
                end
            end
        end
        if dispel then
            local n = 0
            for _, rec in pairs(castRecords) do
                for _, it in ipairs(SelfTimed(spellbook.spells[rec.spell] or { effects = {} })) do
                    if SlotFree(rec, it.k, present) then n = n + 1 end
                end
                DropRecord(rec, present)
            end
            Debug("cast: dispel '%s' (%.0f magicka spent): %d rebuilt effect(s) dropped", dispel, d.amount, n)
        elseif visible then
            Debug("magicka drop of %.0f: new effects appeared (handled as a visible cast)", d.amount)
        else
            local cands = {}
            for name, s in pairs(spellbook.spells) do
                local cost = CostMatches(s, d.amount, not d.hudFull)
                if s.icon == d.icon and #SelfTimed(s) > 0 and (cost == true or (d.hudFull and cost == nil)) then
                    cands[#cands + 1] = name
                end
            end
            table.sort(cands)
            local byCost = {}
            for _, n in ipairs(cands) do
                if CostMatches(spellbook.spells[n], d.amount, true) == true then byCost[#byCost + 1] = n end
            end
            if #byCost > 0 then cands = byCost end
            -- Several costs fit (seen: 276 spent, Magic Well 276, Masse enchantée 281, Nerver Give
            -- Up 281): the closest cost wins; on a tie, a spell whose effects just left the HUD
            -- (a recast replaces them).
            if #cands > 1 then
                local best
                for _, n in ipairs(cands) do
                    local c = spellbook.spells[n].cost
                    if c and (not best or math.abs(c - d.amount) < best) then best = math.abs(c - d.amount) end
                end
                if best then
                    local closest = {}
                    for _, n in ipairs(cands) do
                        local c = spellbook.spells[n].cost
                        if c and math.abs(c - d.amount) <= best + 0.5 then closest[#closest + 1] = n end
                    end
                    cands = closest
                end
            end
            if #cands > 1 then
                local recast = {}
                for _, n in ipairs(cands) do
                    local t = lastRemovedAt[n]
                    if t and math.abs(t - d.at) <= 4 then recast[#recast + 1] = n end
                end
                if #recast == 1 then cands = recast end
            end
            cands = NewestIfIdentical(cands)
            if #cands == 1 then
                NewRecord(cands[1], d.clock, true)
                Debug("cast: hidden cast of '%s' (HUD %d/%d, %.0f magicka spent)", cands[1], d.hudCount, config.HudLimit, d.amount)
            else
                Debug("magicka drop of %.0f with nothing new on the HUD (%d/%d): not identified (spell icon %s, candidates {%s})",
                    d.amount, d.hudCount, config.HudLimit, d.icon, table.concat(cands, ", "))
            end
        end
    end

    if #pending == 0 then return end
    local first = pending[1]
    -- Magicka must have dropped around the moment the effects appeared.
    if cast.lastDrop < first.born - 2 then
        if not first.loggedNoDrop then
            first.loggedNoDrop = true
            Debug("cast: %d new effect(s), no magicka drop yet (magicka %s, last drop %.1fs ago)", #pending,
                tostring(cast.lastMagicka), now - cast.lastDrop)
        end
        return
    end

    -- One cast = effects that appeared together.
    local group, icons = {}, {}
    for _, e in ipairs(pending) do
        if math.abs(e.born - pending[1].born) <= 1.0 then
            group[#group + 1] = e
            icons[#icons + 1] = e.iconName
        end
    end
    local logIt = not first.loggedCast -- set once a decision is reached
    local dropAmount = cast.drop and cast.drop.amount or nil

    -- 1. The spell book; ties broken by the equipped icon, the magicka spent, then durations.
    local function Narrow(list, keep)
        local out = {}
        for _, n in ipairs(list) do if keep(n) then out[#out + 1] = n end end
        if #out > 0 then return out end
        return list
    end
    local estimates, settled = true, true
    for _, e in ipairs(group) do
        if not e.duration then estimates = false end
        if not (e.knownDuration or e.durSettled) then settled = false end
    end
    -- A spell must not contradict the measured durations (an "Épée liée" of 15 s is not a bound
    -- weapon running for 50 s). Only applied to settled estimates, and loosely.
    local function DurationsFit(n)
        for _, e in ipairs(group) do
            if e.duration then
                local found = false
                for _, it in ipairs(SelfTimed(spellbook.spells[n])) do
                    if it.se.icon == e.iconName and math.abs(it.se.duration - e.duration) <= math.max(5, it.se.duration * 0.3) then
                        found = true
                    end
                end
                if not found then return false end
            end
        end
        return true
    end
    -- Returns the remaining candidates, or nil when the duration estimate is needed but not ready.
    local function Choose(list)
        if settled then
            local fit = {}
            for _, n in ipairs(list) do if DurationsFit(n) then fit[#fit + 1] = n end end
            list = fit
        end
        if #list > 1 then
            list = Narrow(list, function(n) return spellbook.spells[n].icon == hudIcon end)
        end
        if #list > 1 then
            list = Narrow(list, function(n) return CostMatches(spellbook.spells[n], dropAmount) == true end)
        end
        if #list > 1 then
            local equipped = EquippedSpellName(vm, hudIcon)
            list = Narrow(list, function(n) return n == equipped end)
        end
        if #list > 1 then
            -- Same icons (e.g. two bound weapon + fortify spells): compare durations.
            if not estimates then return nil end
            local matching = {}
            for _, n in ipairs(list) do
                local ok = true
                for _, e in ipairs(group) do
                    local found = false
                    for _, it in ipairs(SelfTimed(spellbook.spells[n])) do
                        if it.se.icon == e.iconName and math.abs(it.se.duration - e.duration) <= math.max(3, it.se.duration * 0.1) then
                            found = true
                        end
                    end
                    if not found then ok = false end
                end
                if ok then matching[#matching + 1] = n end
            end
            -- The first estimates are rough (44 s for a 50 s spell): if none fits, keep waiting.
            if #matching > 0 then list = matching end
        end
        if #list > 1 and dropAmount and cast.drop and now - cast.drop.at >= 0.6 then
            -- Same icons and durations (e.g. "Arc enchanté" 284 vs "Masse enchantée" 281): the
            -- closest recorded cost wins, once the drop is complete.
            local best
            for _, n in ipairs(list) do
                local c = spellbook.spells[n].cost
                if c and c > 0 then
                    local dist = math.abs(c - dropAmount)
                    if not best or dist < best then best = dist end
                end
            end
            if best then
                list = Narrow(list, function(n)
                    local c = spellbook.spells[n].cost
                    return c and c > 0 and math.abs(c - dropAmount) <= best + 0.5
                end)
            end
        end
        return NewestIfIdentical(list)
    end
    local exact, containing = SpellsMatching(icons)
    local isExact = {}
    for _, n in ipairs(exact) do isExact[n] = true end
    local all = {}
    for _, n in ipairs(exact) do all[#all + 1] = n end
    for _, n in ipairs(containing) do all[#all + 1] = n end
    local function Select(base)
        local list = base
        -- Effects can only be missing when the HUD list is full: otherwise exact matches come first.
        if not hudFull then
            local exactOnly = {}
            for _, n in ipairs(list) do if isExact[n] then exactOnly[#exactOnly + 1] = n end end
            if #exactOnly > 0 then list = exactOnly end
        end
        local out = Choose(list)
        if out and #out > 1 then out = Narrow(out, function(n) return isExact[n] end) end
        return out
    end
    -- Spells whose recorded cost contradicts the magicka spent are out, unless no other spell fits:
    -- recorded costs go out of date as skills and gear change.
    local affordable = {}
    for _, n in ipairs(all) do
        if CostMatches(spellbook.spells[n], dropAmount) ~= false then affordable[#affordable + 1] = n end
    end
    -- Evidence: the effects' icons, then the magicka spent. Until the durations are settled, a
    -- spell is only taken if its recorded cost matches; otherwise wait (an effect gets 8 s).
    local candidates = Select(affordable)
    local outdated = false
    if candidates and #candidates == 1 and not settled
        and CostMatches(spellbook.spells[candidates[1]], dropAmount) ~= true then
        candidates = nil
    end
    if candidates and #candidates ~= 1 and not settled then candidates = nil end
    if candidates and #candidates == 0 and #affordable < #all then
        -- Settled durations rule out every spell whose cost fits: recorded costs go out of date
        -- as skills and gear change, so the effects decide.
        candidates = Select(all)
        outdated = #candidates > 0
    end
    if candidates == nil then
        if not first.loggedWait then
            first.loggedWait = true
            Debug("cast: {%s} match these icons, waiting for the duration estimate to settle", table.concat(all, ", "))
        end
        return
    end
    local partial = #candidates == 1 and not isExact[candidates[1]]
    if logIt and outdated then
        Debug("cast: no spell matches the magicka spent (%s), recorded costs may be outdated", tostring(dropAmount))
    end
    if logIt and #candidates == 0 and #all > 0 then
        Debug("cast: {%s} rejected, their durations do not match the effects' (%.0fs)", table.concat(all, ", "), group[1].duration or -1)
    end
    first.loggedCast = true
    local summary = string.format("%.0fs -> {%s}", group[1].duration or -1, table.concat(candidates, ", "))
    if estimates and first.lastSummary ~= summary then
        first.lastSummary = summary
        Debug("cast: duration estimate %s", summary)
    end
    if logIt then
        Debug("cast: icons {%s}, HUD spell icon %s, %s magicka spent, HUD %d/%d, book candidates {%s}%s (%d spells in book)",
            table.concat(icons, ", "), hudIcon, dropAmount and string.format("%.0f", dropAmount) or "?", #tracked,
            config.HudLimit, table.concat(candidates, ", "), partial and " (partial)" or "", spellbook.count)
    end
    if #candidates == 1 then
        ApplySpell(group, candidates[1], hudFull, present)
        if cast.drop then cast.drop.handled = true end
        -- Costs change as skills go up: learn the magicka actually spent, when it is plausible
        -- (within 25 %) and the spell was identified by its effects, not by its cost.
        local spell = spellbook.spells[candidates[1]]
        local fitting = 0
        if settled then
            for _, n in ipairs(all) do if DurationsFit(n) then fitting = fitting + 1 end end
        end
        local byEffects = #exact == 1 or (#exact == 0 and #containing == 1) or fitting == 1
        if spell and dropAmount and byEffects and now - cast.drop.at < 3 then
            local spent = Round(dropAmount)
            if spell.cost == nil or (spent ~= spell.cost and math.abs(spent - spell.cost) <= spell.cost * 0.25) then
                Debug("spell book: cost of '%s' %s -> %d (magicka spent)", candidates[1], tostring(spell.cost), spent)
                spell.cost = spent
                pcall(SaveSpellbook)
            end
        end
        Debug("cast of '%s' (spell book%s) -> %d effect(s)", candidates[1], partial and ", partial" or "", #group)
        return
    end

    -- 2. Not in the book: the equipped spell's name, if its icon is one of the new effects'.
    local iconMatch = false
    for _, i in ipairs(icons) do if i == hudIcon then iconMatch = true end end
    if not iconMatch then
        if logIt then Debug("cast: not attributed (HUD spell icon is not one of the new effects')") end
        return
    end
    local name = EquippedSpellName(vm, hudIcon)
    if not name then
        if logIt then Debug("cast: not attributed (spell not in the book: hover it in the magic menu)") end
        return
    end
    ApplySpell(group, name, false, present)
    if cast.drop then cast.drop.handled = true end
    Debug("cast of '%s' (equipped, not in the spell book: hover it in the magic menu) -> %d effect(s)", name, #group)
end

-- Rows for effects of recognized casts that the HUD list cannot show (it was full).
local function StandInRows(present)
    local rows = {}
    for id, rec in pairs(castRecords) do
        local spell = spellbook.spells[rec.spell]
        local alive = false
        if spell then
            local elapsed = tracker.activeClock - rec.start
            for _, it in ipairs(SelfTimed(spell)) do
                local rem = it.se.duration - elapsed
                if rem > 0 then
                    alive = true
                    if rec.hudFull and SlotFree(rec, it.k, present) then
                        rows[#rows + 1] = {
                            icon = iconTextures[it.se.icon],
                            label = string.format("%s (%s)", it.se.label, rec.spell),
                            seconds = rem,
                            fraction = rem / it.se.duration,
                            order = 100 + it.k,
                            group = rec.id,
                        }
                    end
                end
            end
        end
        -- Keep records while one of their effects can still be on screen.
        local onHud = false
        for _, e in pairs(rec.slots) do if present[e] then onHud = true end end
        if not alive and not onHud then castRecords[id] = nil end
    end
    return rows
end

-- Effects of recognized casts that are running but not on the HUD (shown as stand-in rows):
-- { icon = icon name, label = effect label }.
local function RebuiltEffects(present)
    local out = {}
    for _, rec in pairs(castRecords) do
        local spell = spellbook.spells[rec.spell]
        if spell and rec.hudFull then
            local elapsed = tracker.activeClock - rec.start
            for _, it in ipairs(SelfTimed(spell)) do
                if it.se.duration - elapsed > 0 and SlotFree(rec, it.k, present) then
                    out[#out + 1] = { icon = it.se.icon, label = it.se.label }
                end
            end
        end
    end
    return out
end

----------------------------------------------------------------------------------------------------
-- Source 2: magic menu "Active" page (safe, refreshed when the menu opens): icon -> names
----------------------------------------------------------------------------------------------------

local iconNames = {} -- icon texture name -> { [name] = true }
-- The page as last seen: { items = { { icon, name, magnitude } }, at = when it last changed }.
-- It is only refilled when the player opens the magic menu.
local activePage = { items = {}, sig = nil, at = -1000 }

local function RefreshIconNames()
    local all = FindAllOf("VMagicMenuViewModel")
    if not all then return end
    for _, mm in ipairs(all) do
        if Valid(mm) and not IsTemplate(mm) then
            local items, parts = {}, {}
            for _, it in ipairs(ReadArray(mm.Inventory)) do
                pcall(function() RememberTexture(it.Icon) end)
                local okT, typ = pcall(function() return it.Type end)
                if okT and typ == 8 then -- ELegacyMagicMenuItemType::Active
                    local icon = NameOf(it.Icon)
                    local name = TextToString(it.Name)
                    if icon ~= "<invalid>" and name ~= "" then
                        -- An icon keeps every name ever seen for it.
                        iconNames[icon] = iconNames[icon] or {}
                        iconNames[icon][name] = true
                        local okP, mag = pcall(function() return tonumber(it.Property) end)
                        items[#items + 1] = { icon = icon, name = name, magnitude = okP and mag or nil }
                        parts[#parts + 1] = icon .. "=" .. name .. "=" .. tostring(okP and mag or "")
                    end
                end
            end
            -- The list is emptied when the menu closes: keep the last page seen.
            local sig = table.concat(parts, ";")
            if #items > 0 and sig ~= activePage.sig then
                activePage.items, activePage.sig, activePage.at = items, sig, Now()
                activePage.fresh = true
                Debug("active effects page: %s", table.concat(parts, ", "))
            end
            return
        end
    end
end

-- Permanent effects (enchanted gear, abilities, birthsign) are on the page too, merged with timed
-- ones of the same type ("Renfort : Agilité 20" = 10 from gear + 10 from a shrine). A baseline of
-- the page without unknown timed effects (name -> magnitude per icon) is kept in permanent.txt:
-- what rose above it belongs to the new effects.
local PERMANENT_FILE = (ModDir() or "") .. "permanent.txt"
local baseline = {} -- icon -> { [name] = magnitude }; an icon missing = no permanent effect
local baselineValid = false -- a page has been recorded at least once
local baselineHist = {} -- icon -> { { at, b = { [name] = magnitude } } }, recent captures

local function LoadBaseline()
    local f = io.open(PERMANENT_FILE, "r")
    if not f then return end
    baselineValid = true
    for line in f:lines() do
        local icon, name, mag = line:match("^(.-)\t(.-)\t(.*)$")
        if icon and tonumber(mag) then
            baseline[icon] = baseline[icon] or {}
            baseline[icon][name] = tonumber(mag)
        end
    end
    f:close()
    for icon, b in pairs(baseline) do
        local copy = {}
        for n, m in pairs(b) do copy[n] = m end
        baselineHist[icon] = { { at = Now(), b = copy } }
    end
end

local function SaveBaseline()
    local f = io.open(PERMANENT_FILE, "w")
    if not f then return end
    local icons = {}
    for icon in pairs(baseline) do icons[#icons + 1] = icon end
    table.sort(icons)
    for _, icon in ipairs(icons) do
        local names = {}
        for n in pairs(baseline[icon]) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do f:write(string.format("%s\t%s\t%s\n", icon, n, baseline[icon][n])) end
    end
    f:close()
end
pcall(LoadBaseline)

-- "Renfort : Volonté 100" -> "Renfort : Volonté", 100 (nil magnitude when there is none).
local function SplitMagnitude(label)
    local name, mag = label:match("^(.-)%s+(%d+)$")
    if name then return name, tonumber(mag) end
    return label, nil
end

-- Names for effects that are not from a recognized cast (potions, shrines, pools...), from the
-- active effects page. Only used when the page was seen after those effects appeared and the
-- counts agree; several unnamed effects of one icon must also have started together (same
-- fraction), so it does not matter which name goes on which line.
local function PageLabels(tracked)
    local out = {}
    local byIcon = {}
    for _, t in ipairs(tracked) do
        local g = byIcon[t.iconName] or { labeled = {}, unnamed = {} }
        byIcon[t.iconName] = g
        if t.effectLabel then g.labeled[#g.labeled + 1] = t else g.unnamed[#g.unnamed + 1] = t end
    end
    -- Rebuilt effects (hidden by the game's HUD) are on the page too.
    local present = {}
    for _, t in ipairs(tracked) do present[t] = true end
    for _, r in ipairs(RebuiltEffects(present)) do
        local g = byIcon[r.icon] or { labeled = {}, unnamed = {} }
        byIcon[r.icon] = g
        g.labeled[#g.labeled + 1] = { effectLabel = r.label }
    end
    local pageByIcon = {}
    for _, it in ipairs(activePage.items) do
        pageByIcon[it.icon] = pageByIcon[it.icon] or {}
        table.insert(pageByIcon[it.icon], it)
    end
    -- What labeled effects (recognized casts) add to the page, per name; false = unknown amount.
    local function Contributions(g)
        local add = {}
        for _, t in ipairs(g.labeled) do
            local name, mag = SplitMagnitude(t.effectLabel)
            if mag and add[name] ~= false then add[name] = (add[name] or 0) + mag else add[name] = false end
        end
        return add
    end

    -- A page just read (not later: effects may have ended since), with no unknown timed effect of
    -- an icon and nothing hidden by a full HUD, is a capture of that icon's permanent effects.
    -- The baseline is each name's lowest value over the captures of the last 30 minutes: a
    -- timed effect the game hid from the HUD (it happens) cannot raise it for long, and gear
    -- taken off lowers it at once.
    local function Remember(icon, b)
        local now = Now()
        baselineHist[icon] = baselineHist[icon] or {}
        local hist = baselineHist[icon]
        hist[#hist + 1] = { at = now, b = b }
        while #hist > 1 and now - hist[1].at > 1800 do table.remove(hist, 1) end
        -- b[name] = false: unknown in that capture (a cast adds to it), it does not count.
        local old = baseline[icon] or {}
        local names = {}
        for _, c in ipairs(hist) do for n in pairs(c.b) do names[n] = true end end
        for n in pairs(old) do names[n] = true end
        local min = {}
        for n in pairs(names) do
            local low, seen = nil, false
            for _, c in ipairs(hist) do
                local v = c.b[n]
                if v ~= false then
                    seen = true
                    v = v or 0
                    if not low or v < low then low = v end
                end
            end
            if not seen then low = old[n] end
            if low and low >= 1 then min[n] = low end
        end
        local changed = false
        for n, m in pairs(min) do if old[n] ~= m then changed = true end end
        for n in pairs(old) do if min[n] == nil then changed = true end end
        baseline[icon] = next(min) and min or nil
        return changed
    end
    local hudFull = #tracked >= config.HudLimit
    local justRead = activePage.fresh
    activePage.fresh = false
    if justRead and not hudFull then
        local changed = false
        for icon, items in pairs(pageByIcon) do
            local g = byIcon[icon] or { labeled = {}, unnamed = {} }
            local add = Contributions(g)
            local known = #g.unnamed == 0
            for _, v in pairs(add) do if v == false then known = false end end
            if known then
                -- Names that recognized casts also add to are unknown in this capture: the real
                -- magnitude can differ from the book's (spell effectiveness, e.g. 95 %).
                local b = {}
                for _, it in ipairs(items) do
                    if add[it.name] then
                        b[it.name] = false
                    elseif (it.magnitude or 0) >= 1 then
                        b[it.name] = it.magnitude
                    end
                end
                if Remember(icon, b) then changed = true end
            end
        end
        -- Icons no longer on the page (gear taken off): no permanent effect left.
        for icon in pairs(baseline) do
            local g = byIcon[icon]
            if not pageByIcon[icon] and not (g and (#g.unnamed > 0 or #g.labeled > 0)) then
                if Remember(icon, {}) then changed = true end
            end
        end
        if changed or not baselineValid then
            baselineValid = true
            pcall(SaveBaseline)
            Debug("permanent effects updated from the active effects page")
        end
    end

    for icon, g in pairs(byIcon) do
        if #g.unnamed > 0 then
            local fresh, together = true, true
            for _, t in ipairs(g.unnamed) do
                if not t.born or t.born > activePage.at then fresh = false end
                if math.abs(t.f - g.unnamed[1].f) > 0.005 then together = false end
            end
            local items = pageByIcon[icon] or {}
            local names = {}
            -- What rose above the permanent effects and the recognized casts. Without a recorded
            -- page the permanent effects are unknown: no names (rather than wrong ones).
            local base = baseline[icon] or (baselineValid and {} or nil)
            if base then
                local add = Contributions(g)
                for _, it in ipairs(items) do
                    if add[it.name] ~= false then
                        local cast = add[it.name] or 0
                        local extra = (it.magnitude or 0) - (base[it.name] or 0) - cast
                        if extra >= math.max(1, cast * 0.1) then names[#names + 1] = { name = it.name, magnitude = extra } end
                    end
                end
            end
            if base and fresh and together and #names == #g.unnamed then
                table.sort(names, function(a, b) return a.name < b.name end)
                table.sort(g.unnamed, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
                for k, t in ipairs(g.unnamed) do
                    local it = names[k]
                    local label = it.name
                    if config.ShowMagnitude and it.magnitude and it.magnitude >= 1 then
                        label = string.format("%s %d", label, Round(it.magnitude))
                    end
                    out[t] = label
                end
            end
        end
    end
    return out
end

local function CommonPrefix(list)
    local p = list[1]
    for i = 2, #list do
        local s = list[i]
        local k = 0
        while k < #p and k < #s and p:sub(k + 1, k + 1) == s:sub(k + 1, k + 1) do k = k + 1 end
        p = p:sub(1, k)
    end
    -- Keep whole UTF-8 characters.
    while #p > 0 and utf8.len(p) == nil do p = p:sub(1, -2) end
    -- Drop trailing separators: spaces, ":", "-", no-break spaces (French "Renfort : Force").
    local prev
    repeat
        prev = p
        p = p:gsub("[%s:%-]+$", ""):gsub("\xC2\xA0$", ""):gsub("\xE2\x80\xAF$", "")
    until p == prev
    return p
end

local function HumanizeIcon(iconName)
    local s = iconName:gsub("^T_", ""):gsub("_", " ")
    return (s:gsub("^%l", string.upper))
end

local function NameForIcon(iconName)
    local set = iconNames[iconName]
    local list = {}
    if set then
        for n in pairs(set) do list[#list + 1] = n end
        table.sort(list)
        if #list == 1 then return list[1] end
    end
    local fromBook = SpellbookLabelForIcon(iconName)
    if fromBook then return fromBook end
    if #list > 1 then
        local p = CommonPrefix(list)
        if #p >= 3 then return p end
    end
    return HumanizeIcon(iconName)
end

----------------------------------------------------------------------------------------------------
-- Source 3 (experimental): named effect list from the game's active-effects component
----------------------------------------------------------------------------------------------------

-- player:RequestActiveEffectsFromOG() crashes if called before the old engine thread runs (main
-- menu). It is only called once a save has been loaded, at most once per second, and given up
-- after a few calls that bring nothing.
local names = { requests = 0, lastRequest = 0, gaveUp = false, everFilled = false }

local function ReadNamedEffects(player)
    local comp = player.ActiveEffectsPairingComponent
    if not Valid(comp) then return {} end
    local effects = {}
    for i, d in ipairs(ReadArray(comp.ActiveEffectList)) do
        effects[#effects + 1] = {
            index = i,
            name = TextToString(d.EffectName),
            extra = TextToString(d.AdditionalEffectName),
            magnitude = d.Magnitude,
            remaining = d.RemainingDuration,
        }
    end
    return effects
end

local function MaybeRequestNames(player)
    if not config.TryEffectNames or names.gaveUp then return end
    if not InGameFor(3) then return end
    local now = Now()
    if now - names.lastRequest < 1.0 then return end
    names.lastRequest = now
    local ok, err = pcall(function() player:RequestActiveEffectsFromOG() end)
    names.requests = names.requests + 1
    if not ok then
        Log("RequestActiveEffectsFromOG failed: %s (names disabled)", tostring(err))
        names.gaveUp = true
    elseif not names.everFilled and names.requests >= 10 then
        Log("the game returned no named effects after %d requests; names disabled", names.requests)
        names.gaveUp = true
    end
end

----------------------------------------------------------------------------------------------------
-- Building the rows
----------------------------------------------------------------------------------------------------

local function IsPermanent(sec)
    return sec == nil or sec <= 0 or sec > 1e8
end

local function FormatTime(sec)
    sec = math.floor(sec + 0.5)
    if sec < 60 then return string.format("%ds", sec) end
    if sec < 3600 then return string.format("%d:%02d", sec // 60, sec % 60) end
    return string.format("%d:%02d:%02d", sec // 3600, (sec % 3600) // 60, sec % 60)
end

local function NamedLabel(e)
    local label = e.name
    if e.extra ~= "" and not string.find(label, e.extra, 1, true) then
        label = label .. " " .. e.extra
    end
    if config.ShowMagnitude and e.magnitude and e.magnitude >= 1 then
        label = string.format("%s %d", label, Round(e.magnitude))
    end
    return label
end

-- Order: effects of one cast stay together (sorted by name); casts are sorted by precise time
-- left, longest at the top. Two casts only swap when their order changes by more than
-- ORDER_HYSTERESIS seconds, so estimates that wobble around each other do not flip back and forth.
local ORDER_HYSTERESIS = 0.5
local previousGroupOrder = {}

local function RowTime(r)
    if r.permanent then return math.huge end
    if r.seconds then return r.seconds end
    return 1e7 + (r.fraction or 1) -- just cast, time not known yet: at the top
end

OrderRows = function(rows)
    local groups, byId = {}, {}
    for _, r in ipairs(rows) do
        local g = byId[r.group]
        if not g then
            g = { id = r.group, rows = {}, t = -math.huge }
            byId[r.group] = g
            groups[#groups + 1] = g
        end
        g.rows[#g.rows + 1] = r
        g.t = math.max(g.t, RowTime(r))
    end
    for _, g in ipairs(groups) do
        table.sort(g.rows, function(a, b)
            if a.label ~= b.label then return a.label < b.label end
            return a.order < b.order
        end)
    end

    -- Start from the previous order; new casts are inserted where their time puts them.
    local list = {}
    for _, id in ipairs(previousGroupOrder) do
        if byId[id] then list[#list + 1] = byId[id]; byId[id].placed = true end
    end
    for _, g in ipairs(groups) do
        if not g.placed then
            local at = #list + 1
            for i, other in ipairs(list) do
                if g.t > other.t then at = i break end
            end
            table.insert(list, at, g)
        end
    end
    -- Bubble pass: swap neighbours only when clearly out of order.
    local swapped = true
    while swapped do
        swapped = false
        for i = 1, #list - 1 do
            if list[i + 1].t > list[i].t + ORDER_HYSTERESIS then
                list[i], list[i + 1] = list[i + 1], list[i]
                swapped = true
            end
        end
    end

    previousGroupOrder = {}
    local out = {}
    for _, g in ipairs(list) do
        previousGroupOrder[#previousGroupOrder + 1] = g.id
        for _, r in ipairs(g.rows) do out[#out + 1] = r end
    end
    return out
end

local pageLabels = {}

local function RowLabel(t)
    local effect = t.effectLabel or pageLabels[t] or NameForIcon(t.iconName)
    if t.spell then return string.format("%s (%s)", effect, t.spell) end
    return effect
end

-- Rows: { icon, label, seconds (nil = not known yet), permanent, fraction, order }
local function BuildRows(tracked, named)
    local rows = {}
    local timedNamed = {}
    for _, e in ipairs(named) do
        if not IsPermanent(e.remaining) then timedNamed[#timedNamed + 1] = e end
    end

    if #timedNamed > 0 then
        -- Names known: one row per named effect; icons from the HUD, in cast order when the counts
        -- agree, otherwise by the closest estimated time left.
        local free = {}
        for i, t in ipairs(tracked) do free[i] = t end
        for i, e in ipairs(timedNamed) do
            local icon, fraction = nil, nil
            if #timedNamed == #tracked then
                icon, fraction = tracked[i].icon, tracked[i].f
            else
                local best, bestK = nil, nil
                for k, t in pairs(free) do
                    if t.duration then
                        local diff = math.abs(t.f * t.duration - e.remaining)
                        if diff < 3 and (not best or diff < best) then best, bestK = diff, k end
                    end
                end
                if bestK then icon, fraction = free[bestK].icon, free[bestK].f; free[bestK] = nil end
            end
            rows[#rows + 1] = { icon = icon, label = NamedLabel(e), seconds = e.remaining, fraction = fraction, order = i, group = "n" .. i }
        end
    else
        pageLabels = PageLabels(tracked)
        for i, t in ipairs(tracked) do
            if t.castGroup and supersededGroups[t.castGroup] then goto continue end
            rows[#rows + 1] = {
                icon = t.icon,
                label = RowLabel(t),
                seconds = t.duration and (t.f * t.duration) or nil,
                fraction = t.f,
                order = i,
                group = t.castGroup or ("effect" .. tostring(t.uid or i)),
            }
            ::continue::
        end
    end

    if config.ShowPermanentEffects then
        for i, e in ipairs(named) do
            if IsPermanent(e.remaining) then
                rows[#rows + 1] = { label = NamedLabel(e), permanent = true, order = 1000 + i, group = "p" .. i }
            end
        end
    end

    -- Sort: permanent first, then the longest time left at the top, the shortest at the bottom.
    -- Unknown times (just cast) go above timed ones, ordered by fraction left.
    local present = {}
    for _, t in ipairs(tracked) do present[t] = true end
    for _, r in ipairs(StandInRows(present)) do rows[#rows + 1] = r end
    rows = OrderRows(rows)
    while #rows > config.MaxRows do table.remove(rows, 1) end
    return rows
end

local function DumpData(named, tracked, why)
    Log("---- data dump (%s) ----", why)
    Log("named effects (%d), requests so far %d%s:", #named, names.requests, names.gaveUp and " (gave up)" or "")
    for _, e in ipairs(named) do
        Log("  N%d name='%s' extra='%s' magnitude=%s remaining=%s", e.index, e.name, e.extra,
            tostring(e.magnitude), tostring(e.remaining))
    end
    Log("HUD effects (%d):", #tracked)
    for i, t in ipairs(tracked) do
        Log("  H%d icon=%s fraction=%.3f duration=%s%s label='%s'", i, t.iconName, t.f,
            t.duration and string.format("%.1f", t.duration) or "?", t.knownDuration and " (exact)" or "", RowLabel(t))
    end
end

----------------------------------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------------------------------

local function SetVisible(w, visible)
    w:SetVisibility(visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
end

local function DrawRow(row, r)
    local last = row.last
    if not last.shown then
        SetVisible(row.icon, true); SetVisible(row.name, true); SetVisible(row.time, true)
        last.shown = true
        last.hasBar = nil -- the bar's visibility is set below
        last.icon = false -- force the icon refresh below
    end

    if last.icon ~= r.icon then
        if Valid(r.icon) then
            row.icon:SetBrushFromTexture(r.icon, false)
            pcall(function() row.icon:SetDesiredSizeOverride({ X = config.IconSize, Y = config.IconSize }) end)
            row.icon:SetVisibility(VIS_HIT_TEST_INVISIBLE)
        else
            row.icon:SetVisibility(VIS_HIDDEN) -- keep the space so names stay aligned
        end
        last.icon = r.icon
    end

    if last.label ~= r.label then
        row.name:SetText(FText(r.label))
        last.label = r.label
    end

    local timeText = ""
    if not r.permanent then timeText = r.seconds and FormatTime(r.seconds) or "..." end
    if last.timeText ~= timeText then
        row.time:SetText(FText(timeText))
        last.timeText = timeText
    end

    local warn = (not r.permanent) and r.seconds ~= nil and r.seconds <= config.WarningSeconds
    if last.warn ~= warn then
        local color = warn and config.WarningColor or config.TimeColor
        pcall(function() row.time:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
        if row.bar then
            pcall(function() row.bar:SetFillColorAndOpacity(warn and config.WarningColor or config.BarColor) end)
        end
        last.warn = warn
    end

    if row.bar then
        local hasBar = r.fraction ~= nil and not r.permanent
        if last.hasBar ~= hasBar then
            -- Hidden keeps the row height stable when a bar is missing.
            row.barBox:SetVisibility(hasBar and VIS_HIT_TEST_INVISIBLE or VIS_HIDDEN)
            last.hasBar = hasBar
        end
        if hasBar and (not last.fraction or math.abs(last.fraction - r.fraction) >= 0.001) then
            row.bar:SetPercent(math.max(0, math.min(1, r.fraction)))
            last.fraction = r.fraction
        end
    end
end

local function HideRow(row)
    if row.last.shown then
        SetVisible(row.icon, false); SetVisible(row.name, false); SetVisible(row.time, false)
        if row.barBox then SetVisible(row.barBox, false) end
        row.last.shown = false
        row.last.hasBar = nil
    end
end

local lastMenuRefresh = 0

local function Update()
    if inGame.reload then
        inGame.reload = false
        state.player, state.viewModel = nil, nil
        pcall(Detach)
        state.canvasVisible = nil
        local n = 0
        for _, w in ipairs(FindAllOf("WBP_ModernHud_EffectIcons_C") or {}) do
            if Valid(w) and not IsTemplate(w) then n = n + 1 end
        end
        state.lastDisplay = nil
        -- Across a loading screen (a loaded save, a door) magicka and the HUD's effects change
        -- without any cast: forget the last magicka value, and effects seen right after it are
        -- not new casts.
        cast.lastMagicka, cast.drop = nil, nil
        cast.reloadAt = Now()
        Debug("loading screen done: re-attaching (%d live HUD effect widgets)", n)
    end
    local player = GetPlayer()
    if not player then return end
    -- Wait until a save is loaded (the main menu also has a player character).
    if inGame.hooked and not InGameFor(1) then return end
    if not EnsureAttached() then return end

    local vm = GetViewModel()
    local menuMode = false
    pcall(function() menuMode = vm.bIsMenuMode == true end)
    local tracked = UpdateTracker(ReadHud(vm), inGame.active and not menuMode)
    AttributeCasts(tracked, vm)
    if hover.index ~= nil and Now() - hover.time < 30 then
        local okC, errC = pcall(CaptureSpell)
        if not okC then Note("error: %s", tostring(errC)) end
    end
    if config.Debug and #tracked > 0 and Now() - tracker.lastDiag >= 10 then
        tracker.lastDiag = Now()
        local gameT, realT = "?", "?"
        pcall(function()
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            gameT = string.format("%.2f", gs:GetTimeSeconds(player))
            realT = string.format("%.2f", gs:GetRealTimeSeconds(player))
        end)
        local t1 = tracked[1]
        Log("timing: os.clock=%.2f activeClock=%.2f ueGame=%s ueReal=%s changes=%d longGaps=%d maxGap=%.2f | H1 %s f=%.5f dur=%s",
            Now(), tracker.activeClock, gameT, realT, tracker.changes, tracker.longGaps, tracker.maxGap,
            t1.iconName, t1.f, t1.duration and string.format("%.1f", t1.duration) or "?")
    end

    local now = Now()
    if now - lastMenuRefresh >= 2.0 then
        lastMenuRefresh = now
        RefreshIconNames()
    end

    MaybeRequestNames(player)
    local named = ReadNamedEffects(player)
    if #named > 0 and not names.everFilled then
        names.everFilled = true
        Log("named effects available (%d entries)", #named)
    end

    if config.Debug then
        local parts = {}
        for _, t in ipairs(tracked) do parts[#parts + 1] = t.iconName end
        for _, e in ipairs(named) do parts[#parts + 1] = e.name .. "|" .. e.extra end
        local sig = table.concat(parts, ";")
        if sig ~= state.lastSignature then
            state.lastSignature = sig
            DumpData(named, tracked, "effects changed")
        end
    end

    local rows = BuildRows(tracked, named)
    for i, r in ipairs(rows) do
        local row = state.rows[i] or CreateRow(i)
        DrawRow(row, r)
    end
    for i = #rows + 1, #state.rows do
        HideRow(state.rows[i])
    end

    -- Show the table only once it is positioned.
    local placed = Place()
    local wantVisible = placed and #rows > 0
    if state.canvasVisible ~= wantVisible then
        state.table:SetVisibility(wantVisible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        state.canvasVisible = wantVisible
    end

    -- Log what is on screen whenever it changes (so a missing list can be diagnosed from the log).
    if config.Debug then
        local labels = {}
        for _, r in ipairs(rows) do labels[#labels + 1] = r.label end
        local desc = string.format("%d line(s), %s, placed=%s (%s) [%s]", #rows,
            wantVisible and "visible" or "hidden", tostring(placed), state.placeMode or "measured",
            table.concat(labels, " | "))
        if desc ~= state.lastDisplay then
            state.lastDisplay = desc
            Debug("display: %s", desc)
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Loop and hotkey
----------------------------------------------------------------------------------------------------

local function SafeUpdate()
    local ok, err = pcall(Update)
    if not ok then
        state.errors = state.errors + 1
        if state.errors <= 20 then Log("update error: %s", tostring(err)) end
        -- Start from scratch next time (the HUD may have been rebuilt).
        state.player, state.viewModel, state.canvasVisible = nil, nil, nil
        pcall(Detach)
    end
end

LoopAsync(config.UpdateIntervalMs, function()
    ExecuteInGameThread(SafeUpdate)
    return false
end)

-- Ctrl+F7: write everything we know to UE4SS.log (works even when Debug = false).
RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local effectIcons = FindLiveWidget("WBP_ModernHud_EffectIcons_C")
            if effectIcons then DumpLayout(effectIcons) else Log("live WBP_ModernHud_EffectIcons_C not found") end
            for _, bar in ipairs(state.bars) do
                local okR, x1, y1, x2, y2 = pcall(AbsRect, bar)
                Log("  bar %s rect=%s", NameOf(bar), okR and x1 and string.format("(%.1f,%.1f)-(%.1f,%.1f)", x1, y1, x2, y2) or tostring(x1))
            end
            if state.lastPos then Log("  list position (%.1f, %.1f)", state.lastPos.X, state.lastPos.Y) end
            local function Vis(w)
                if not Valid(w) then return "invalid" end
                local ok, v = pcall(function() return w:GetVisibility() end)
                local okO, o = pcall(function() return w:GetRenderOpacity() end)
                return string.format("vis=%s opacity=%s", ok and tostring(v) or "?", okO and tostring(o) or "?")
            end
            Log("  canvas %s (in %s), table %s, rows %d, last display: %s", Vis(state.canvas),
                Valid(state.canvas) and Valid(state.canvas.Slot) and NameOf(state.canvas.Slot.Parent) or "nothing",
                Vis(state.table), #state.rows, tostring(state.lastDisplay))
            if Valid(state.effectIcons) then
                pcall(function()
                    local main = state.effectIcons:GetOuter():GetOuter()
                    Log("  HUD main widget %s: %s", NameOf(main), Vis(main))
                end)
            end
            Log("  in game: active=%s, view model %s", tostring(inGame.active), tostring(state.viewModelName))
            local player = GetPlayer()
            if player then
                DumpData(ReadNamedEffects(player), tracker.entries, "Ctrl+F7")
            else
                Log("player not found")
            end
            Log("in game: hooked=%s active=%s", tostring(inGame.hooked), tostring(inGame.active))
        end)
        if not ok then Log("dump error: %s", tostring(err)) end
    end)
end)

Log("loaded (update every %d ms, debug=%s)", config.UpdateIntervalMs, tostring(config.Debug))
