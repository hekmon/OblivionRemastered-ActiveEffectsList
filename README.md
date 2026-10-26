# Active Effects List (Oblivion Remastered, UE4SS)

Replaces the HUD row of active-effect icons with a column above the health / magicka / fatigue bars:

    [icon] Vision nocturne (Regard du néant)          2:09
           ─────────────────────────
    [icon] Arc lié (Arc enchanté)                       42s
           ──────────────
    [icon] Renfort : Agilité 100 (Arc enchanté)         42s   <- expires first, closest to the bars
           ──────────────

- One line per effect: icon, effect name (with the spell that cast it), time left, and a bar that
  drains as the effect runs out. The time and bar turn red in the last 10 seconds.
- Sorted by time left: the effect that expires first is at the bottom, next to the bars. Effects
  of the same cast stay together.
- Shows more than the game's 8 effects (see below).

Made to sit on top of [Better HUD](https://www.nexusmods.com/oblivionremastered/mods/13) (also
works with the vanilla HUD), without modifying it.

## Tips
- **Hover each of your buff spells once** in the magic menu, for half a second (custom spells
  too, and again after creating a new one). The mod then knows their effects, names and
  durations for good. See [the spell book](#the-spell-book-hover-your-spells-once).
- **Open the magic menu once after a potion, scroll, shrine or pool.** Effects that share an icon
  (all the fortify effects do) then each get their own name ("Renfort : Force 20" instead of
  "Renfort"). See [effects that are not your spells](#effects-that-are-not-your-spells).
- **When updating, only replace the `Scripts` folder**: `spellbook.txt` holds what the mod learned.

## How it works

### What the game gives
The game's HUD only receives, for each timed effect, an **icon** and the **fraction of its
duration left** (1.0 down to 0.0). No name, no seconds. And it receives **at most 8 effects**:
beyond that, effects are still active on your character but the game does not send them to the
interface. Worse, once that list has overflowed it stays unreliable: it can go back down to 3 or
4 effects while still hiding the others and the new ones.

### The spell book: hover your spells once
When you hover a spell in the magic menu, its detail panel lists its effects (name, magnitude,
duration, icon, range). The mod records them, with the spell's magicka cost, in
`ActiveEffectsList/spellbook.txt`. **Hover each of your buff spells once**, for half a second:
it is remembered for good, custom spells included.

### Recognizing your casts
When new effects appear on the HUD as your magicka drops, the mod finds the spell in the spell
book whose effects have those icons. Ties (spells with the same icons) are broken by the equipped
spell's icon, the magicka spent, then the duration. The effects then get their exact name and
duration, e.g. "Renfort : Agilité 100 (Arc enchanté)".

### Effects the game hides ("hidden casts")
The mod rebuilds what the game does not send:
- **Partly hidden cast**: only some of a spell's effects reach the HUD (e.g. 3 of the 5 pieces of
  a bound armor spell). The spell is recognized from the visible ones, and its other effects are
  listed anyway, timed from the same cast.
- **Entirely hidden cast**: magicka drops but nothing new appears. The spell is found from the
  equipped spell's icon and the magicka spent (the spell's cost). Its effects are listed with
  their exact duration. The log calls it a "hidden cast".
- **Late effects**: when a hidden effect finally shows up in the game's data, it takes over its
  rebuilt line (no duplicate).

Effects that end early (dispelled, cured) are not rebuilt: after a dispel, the rebuilt effects
are removed too.

Casting a spell again replaces its previous cast (in Oblivion the same spell does not stack: its
duration restarts), so it stays on one line.

Spell costs change as your skills go up: when a cast is recognized by its effects, the recorded
cost is updated from the magicka actually spent.

### Effects that are not your spells
Potions, scrolls, shrines and enemy spells do not use your magicka, so they cannot be matched to a
cast. (Effects without a duration, like abilities, constant-effect enchantments and diseases, are
not listed at all: the game's HUD only reports timed effects.)

Their names come from the magic menu's Active Effects page, or from the spell book when one spell
matches their icon and duration. **Open the magic menu once after drinking a potion or using a
shrine**: several effects with the same icon (all the fortify effects share one) then each get
their own name with its magnitude, e.g. "Renfort : Force 20" instead of "Renfort". Their time
left is estimated from how fast the bar drains (shown as `...` for about a second).

## Limits
- A spell never hovered in the magic menu is unknown: if the game hides its effects, the mod cannot
  show them, and visible ones only get a generic name.
- Effects hidden by the game that are not your own casts (potions, enemy spells...) cannot be
  rebuilt.
- Fortify effects all share one icon. Without the spell book, or the magic menu opened after
  they started, they only show as "Renfort" (Fortify), not which attribute or skill.

## Requirements
- UE4SS for Oblivion Remastered (3.0.x)

## Install
Copy the `ActiveEffectsList` folder into
`OblivionRemastered/Binaries/Win64/ue4ss/Mods/`.
It is enabled by its `enabled.txt`.
When updating, only replace the `Scripts` folder: keep your `spellbook.txt`.

## Settings
`ActiveEffectsList/Scripts/config.lua`: font and icon size, list width and position, bars, colors,
spell names, how many effects the game's HUD holds (`HudLimit`), debug logging.

## Troubleshooting
With `Debug = true`, the mod logs to `OblivionRemastered/Binaries/Win64/ue4ss/UE4SS.log`
(lines start with `[ActiveEffectsList]`): what it displays, each cast and magicka drop and how it
was interpreted, each spell learned. Press **Ctrl+F7** in game to also write the HUD layout and the
raw effect data.

`TryEffectNames` is an experiment that stays off: the game function it calls crashes the game
at the main menu and returns nothing in game.
