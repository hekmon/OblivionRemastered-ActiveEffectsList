-- Active Effects List - settings
return {
    -- true = only log the game's active-effect data to UE4SS.log (read-only, draws nothing).
    ProbeOnly = false,

    -- EXPERIMENTAL: ask the game for its named effect list (exact names and seconds).
    -- Only done once a save is loaded (it crashes the game at the main menu).
    -- Tested in game: no crash, but the game returned nothing, so it is off by default.
    TryEffectNames = false,

    -- How often the list is refreshed, in milliseconds.
    UpdateIntervalMs = 250,

    -- Maximum number of lines shown (extra effects are dropped from the top).
    MaxRows = 20,

    -- Icon size and font size, in HUD units (the HUD scales them with resolution).
    IconSize = 30,
    FontSize = 14,

    -- Prefix effects with the name of the spell that created them ("My Spell - Renfort").
    -- Detected when new effects appear as magicka drops, using the equipped spell.
    ShowSpellNames = true,

    -- How many effects the game's HUD list can hold (effects beyond are hidden by the game).
    -- When a recognized cast has effects the HUD cannot show, they are listed anyway.
    HudLimit = 8,

    -- Append the magnitude to the effect name ("Fortify Strength 20") when names are available.
    ShowMagnitude = true,

    -- Effects with no timer (abilities, birthsign, constant-effect enchantments), only available
    -- with TryEffectNames: true = listed at the top without a time, false = not listed.
    ShowPermanentEffects = false,

    -- Width of the list (same as the bars), the times are aligned on its right edge.
    -- 0 = as narrow as the text.
    ListWidth = 322,

    -- Placement: the list's bottom-left corner follows the top-left corner of the bars.
    -- Space between the list and the bars, and an extra nudge (positive X = right, positive Y = down).
    GapAboveBars = 6,
    OffsetX = 0,
    OffsetY = 0,
    -- Used only if the bars' position cannot be measured: distance of the list's bottom-left
    -- corner from the bottom-left corner of the HUD.
    FallbackLeft = 32,
    FallbackBottom = 115,

    -- Bar under each effect showing how much of its duration is left.
    ShowBar = true,
    BarHeight = 3,
    -- Space below each bar (between two effects).
    RowSpacing = 4,
    BarColor           = { R = 0.85, G = 0.78, B = 0.55, A = 0.90 },
    BarBackgroundColor = { R = 0.0,  G = 0.0,  B = 0.0,  A = 0.45 },

    -- Hide the original row of icons.
    HideOriginalIcons = true,

    -- Times at or below this many seconds are drawn in the warning color.
    WarningSeconds = 10,

    -- Colors (R, G, B, A from 0 to 1).
    NameColor    = { R = 0.93, G = 0.90, B = 0.82, A = 1.0 },
    TimeColor    = { R = 0.85, G = 0.78, B = 0.55, A = 1.0 },
    WarningColor = { R = 0.95, G = 0.40, B = 0.30, A = 1.0 },

    -- Write diagnostic information to UE4SS.log.
    Debug = true,
}
