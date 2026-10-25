--[[
    Read-only probe: logs the game's active-effect data to UE4SS.log.
    It creates no widgets and calls no game functions; it only reads properties.
    Used to learn how the data behaves before drawing anything.
]]

local config = require("config")
local MOD = "[ActiveEffectsList:probe]"

local function Log(fmt, ...)
    print(string.format("%s " .. fmt .. "\n", MOD, ...))
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
    if not Valid(obj) then return "nil" end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return ok and n or "<?>"
end

local function IsTemplate(obj)
    local full = FullName(obj)
    return string.find(full, "_C:", 1, true) ~= nil or string.find(full, "Default__", 1, true) ~= nil
end

local function Text(t)
    if t == nil then return "" end
    local ok, s = pcall(function() return t:ToString() end)
    return ok and s or "<?>"
end

local function ReadArray(arr)
    local out = {}
    if arr == nil then return out end
    pcall(function() arr:ForEach(function(_, elem) out[#out + 1] = elem:get() end) end)
    return out
end

local function FirstLive(className)
    for _, o in ipairs(FindAllOf(className) or {}) do
        if Valid(o) and not IsTemplate(o) then return o end
    end
    return nil
end

local function Fmt(x)
    if type(x) == "number" then return string.format("%.2f", x) end
    return tostring(x)
end

local lastEffectsSig, lastIconsSig, lastMenuSig = nil, nil, nil
local lastFullDump = 0
local dumps = 0
local tick = 0

local function Probe()
    tick = tick + 1
    local player = FirstLive("BP_OblivionPlayerCharacter_C")
    if not player then return end

    -- 1. ActiveEffectsPairingComponent.ActiveEffectList (names + remaining time)
    local effects = {}
    local comp = player.ActiveEffectsPairingComponent
    if Valid(comp) then
        for i, d in ipairs(ReadArray(comp.ActiveEffectList)) do
            effects[i] = { name = Text(d.EffectName), extra = Text(d.AdditionalEffectName),
                           mag = d.Magnitude, rem = d.RemainingDuration }
        end
    end
    local parts = {}
    for _, e in ipairs(effects) do parts[#parts + 1] = e.name .. "|" .. e.extra end
    local effectsSig = table.concat(parts, ";")

    -- 2. HUD view model (icons + time left the vanilla HUD uses)
    local vm = FirstLive("VHUDMainViewModel")
    local icons, times = {}, {}
    if vm then
        icons = ReadArray(vm.EffectsIcons)
        times = ReadArray(vm.EffectsTimeLeft)
    end
    local iparts = {}
    for _, t in ipairs(icons) do iparts[#iparts + 1] = NameOf(t) end
    local iconsSig = table.concat(iparts, ";")

    -- Full dump when the set changes, and every 5 s while something is active (max 200 dumps).
    local changed = effectsSig ~= lastEffectsSig or iconsSig ~= lastIconsSig
    local periodic = (#effects > 0 or #icons > 0) and (tick - lastFullDump) >= 5
    if (changed or periodic) and dumps < 200 then
        dumps = dumps + 1
        lastFullDump = tick
        Log("==== t=%ds %s ====", tick, changed and "CHANGED" or "periodic")
        Log("ActiveEffectList (%d):", #effects)
        for i, e in ipairs(effects) do
            Log("  E%d name='%s' extra='%s' magnitude=%s remaining=%s", i, e.name, e.extra, Fmt(e.mag), Fmt(e.rem))
        end
        Log("HUD icons (%d) / times (%d):", #icons, #times)
        for i = 1, math.max(#icons, #times) do
            Log("  H%d icon=%s timeLeft=%s", i, NameOf(icons[i]), Fmt(times[i]))
        end
    end
    lastEffectsSig, lastIconsSig = effectsSig, iconsSig

    -- 3. Magic menu "Active" page items (name + icon), when the menu has data.
    local mm = FirstLive("VMagicMenuViewModel")
    if mm then
        local items = {}
        for _, it in ipairs(ReadArray(mm.Inventory)) do
            local okT, typ = pcall(function() return it.Type end)
            if okT and typ == 8 then
                items[#items + 1] = string.format("'%s' icon=%s property=%s value=%s", Text(it.Name), NameOf(it.Icon),
                    Fmt(it.Property), tostring(it.EffectValue))
            end
        end
        local menuSig = table.concat(items, ";")
        if menuSig ~= lastMenuSig and #items > 0 then
            Log("==== magic menu Active items (%d) ====", #items)
            for i, s in ipairs(items) do Log("  M%d %s", i, s) end
        end
        lastMenuSig = menuSig
    end
end

-- Log when the game itself asks for a refresh of the active effects (we never call it).
local okHook, errHook = pcall(function()
    RegisterHook("/Script/Altar.VPairedPawn:RequestActiveEffectsFromOG", function(ctx)
        local who = "?"
        pcall(function() who = NameOf(ctx:get()) end)
        Log("game called RequestActiveEffectsFromOG on %s", who)
    end)
end)
Log("hook on RequestActiveEffectsFromOG: %s", okHook and "ok" or tostring(errHook))

LoopAsync(1000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(Probe)
        if not ok then Log("probe error: %s", tostring(err)) end
    end)
    return false
end)

Log("probe loaded (read-only, logging every second when data changes)")
