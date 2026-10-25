# AGENTS.md

Notes for coding agents working on this repository. Read this before changing anything: most of
what is below was learned through in-game crashes, and each in-game test costs the user a game
restart.

## Project

A UE4SS Lua mod for **The Elder Scrolls IV: Oblivion Remastered** (Unreal Engine 5.3 on top of the
original Gamebryo engine, called "OG" in the game's code). It replaces the HUD's row of
active-effect icons with a column above the health / magicka / fatigue bars:

    [icon] Effect name      time left

sorted so the effect expiring first is at the bottom. It runs on top of the user's
[Better HUD](https://www.nexusmods.com/oblivionremastered/mods/13) pak mod without modifying it.

- `ActiveEffectsList/Scripts/main.lua`: the mod.
- `ActiveEffectsList/Scripts/config.lua`: user settings.
- `ActiveEffectsList/Scripts/probe.lua`: read-only data logger (`ProbeOnly = true` in config).
- `ActiveEffectsList/enabled.txt`: enables the mod in UE4SS.
- `tests/mock_ue4ss.lua`: fake UE4SS + game environment to run the mod outside the game.

The user plays the game in French, so names in logs are French ("Renfort : Volonté").

## Environment

- Development happens in WSL; the game runs on Windows.
- Game: `/mnt/c/Program Files (x86)/Steam/steamapps/common/Oblivion Remastered/`
- UE4SS 3.0.1 (Lua 5.4): `.../OblivionRemastered/Binaries/Win64/ue4ss/`
  - Installed copy of the mod: `ue4ss/Mods/ActiveEffectsList/`
  - Log: `ue4ss/UE4SS.log` (our lines start with `[ActiveEffectsList]`)
  - No hot reload: mods load at game start only. Copying files while the game runs is harmless.
- Game crash reports: `/mnt/c/Users/<user>/Documents/My Games/Oblivion Remastered/Saved/Crashes/UECC-*/`
  (`CrashContext.runtime-xml` and `UEMinidump.dmp`).
- Better HUD pak: `.../Content/Paks/~mods/000_BetterHUD_P.{pak,utoc,ucas}` (IoStore).
- Other mods installed alongside: UltraPlusExtensions (uses Alt+F8, F10, F12, Alt+F6, Alt+=),
  MagicSkillLevelingFixed, SimplySwimUp, etc. Our debug hotkey is Ctrl+F7.
- Scratch space: use `~/.cache/obr/`. `/tmp` was wiped by a reboot once and the tools were lost.

## Workflow

1. Edit files in this repository.
2. Syntax check and run the simulation (build Lua 5.4 from lua.org into `~/.cache/obr/tools` if needed):

       luac -p ActiveEffectsList/Scripts/*.lua
       cp -r ActiveEffectsList ~/.cache/obr/test/mod/   # the mod writes spellbook.txt: use a copy
       lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok
       lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames broken
       FULL=1 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok     # HUD limit
       PARTIAL=1 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok  # one effect of two visible
       RELOAD=1 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok   # loading screen, new view model
       STUCK=1 HUD_CAP=3 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok  # HUD hides casts below 8, enemy drain
       RECAST=1 STUCK=1 HUD_CAP=3 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok  # same spell cast twice
       DISPEL=1 FULL=1 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok   # dispel with rebuilt effects
       VRECAST=1 FULL=1 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok  # visible recast keeps others
       BOW=1 lua tests/mock_ue4ss.lua ~/.cache/obr/test/mod/ActiveEffectsList/Scripts nonames ok      # effects of one cast 0.3 s apart, same-icon spells

   Check every scenario for "update error" in the verbose output (set QUIET = false in a copy):
   a wrong edit can delete functions and the mod then fails silently in game. Compare the list of
   functions with the installed copy before installing.

   The mock raises an error if a widget is ever constructed inside a blueprint template.
3. Install: `cp ActiveEffectsList/Scripts/*.lua "<game>/.../ue4ss/Mods/ActiveEffectsList/Scripts/"`.
   Only copy the scripts: never overwrite the user's `spellbook.txt` in the installed folder.
4. Ask the user to restart the game and test, then read `UE4SS.log` directly from `/mnt/c`
   (the user does not need to send logs). If the game crashed, check the crash reports.

Do not install or reinstall something risky while the user is playing without telling them.

## Verified facts (in game)

### Things that crash the game
- **`player:RequestActiveEffectsFromOG()` at the main menu.** It dereferences a global "GameSync"
  service (exe `0x92ce738`, read by getter `0x4593de0`) that is only created when the game's
  `OblivionThread` starts. Proven from two minidumps: both crashed at `exe+0x4702a8a` called from
  the function's implementation at `0x4863b90`.
  Called in game, after a save is loaded, it did not crash, but `ActiveEffectList` stayed empty.
  It is useless, so `TryEffectNames = false`.
- **Modifying blueprint template widgets.** `FindAllOf` also returns objects inside
  `WBP_..._C:WidgetTree` (the class template). Adding children to those crashed the game at
  startup. Skip any object whose full name contains `_C:` or `Default__` (`IsTemplate`).
- The main menu already has a `BP_OblivionPlayerCharacter_C`, so "a player exists" does not mean a
  save is loaded. Gate on the hook `/Script/Altar.VLevelChangeData:OnFadeToGameBeginEventReceived`
  (and `OnFadeToBlackBeginEventReceived` to stop).

### Data sources
- **`VHUDMainViewModel`** (`FindAllOf`, skip templates):
  - `EffectsIcons`: `TArray<UTexture2D*>`, one per timed effect, in cast order (expired ones are
    removed, new ones appended).
  - `EffectsTimeLeft`: `TArray<double>` holding the **fraction** of the duration left (1.0 down to 0.0),
    not seconds. The array is not trimmed, so only the first `#EffectsIcons` entries are valid.
  - Fractions freeze while the game is paused (menus).
  - Seconds are estimated as `fraction * duration`, with `duration = active time / fraction used`.
    The estimate matches `GameplayStatics:GetTimeSeconds`.
- **`VMagicMenuViewModel.Inventory`**: items with `Type == 8` are the Active Effects page. It has
  `Name`, `Icon`, `Property` (= summed magnitude), but **no duration**, and it merges effects of
  the same type. Many effects share an icon (all fortify attribute/skill effects use
  `T_fortify_restoration`), so names are matched by icon, using the common prefix when an icon is
  ambiguous ("Renfort"). French text uses a no-break space before ":".
  Filled when the player opens the magic menu.
- **Spell book (`spellbook.txt` next to the Scripts folder, written by the mod):** when a spell is
  hovered in the magic menu, the game fills `VAddedEffectsListViewModel.ModernAddedItemEffectsList`
  (`FModernEffectItemData`: `EffectName`, `AdditionalEffectName`, `Magnitude`, `Duration` in
  seconds, `Image`, `Range`). The hovered item is known by hooking
  `/Script/Altar.VMagicMenuViewModel:RegisterSendItemHoverHandler` (index = `InventoryIndex`) and
  reading `VMagicMenuViewModel.CurrentPageInventory`. A spell is only learned once hover and list
  have been stable for 0.5 s, and only if its list icon is one of its effects' icons.
  The detail panel widget is `WBP_ModernMenu_MagicDetails` > `WBP_ModernMenu_Added_Effects_List`.
- **Casts:** new HUD effects appearing while `VHUDMainViewModel.CurrentMagickaValue` drops are a
  cast. The spell is the one in the book whose self-range timed effects have exactly the new
  effects' icons, with ties broken by the HUD's live `SpellIcon`, then by
  `VMagicMenuViewModel.CurrentSpellEquiped`. That value is stale until the magic menu is reopened,
  so it is only trusted when its icon equals `SpellIcon`. Matched effects get the exact label and
  duration from the book. Potions, scrolls and shrines (no magicka drop) keep generic names.
- **Loading screens:** after entering a cave, the cached `VHUDMainViewModel` stayed "valid" but
  reported 0 effects forever. The game had evidently made a new one at load. The view model is
  now read on every update from the attached HUD widget (`WBP_ModernHud_Main.HUDMainViewModel`),
  and caches are reset when the fade-to-game hook fires. Do not cache game objects across
  loading screens.
- **HUD limit: the game's HUD list holds at most 8 effects** (`HudLimit`). Further effects are
  hidden by the game and appear later, already part-way through their timer, as others expire.
  Recognized casts are kept as cast records (spell + start time). Their effects that are missing
  from a full HUD are shown as stand-in rows, timed from the cast. A hidden effect that surfaces
  later "joins" its cast record (same icon, fraction where the cast's timer is) and replaces the
  stand-in. Once the list has overflowed, it **stays unreliable**: in a fight it went back down
  to 3-5 visible effects while hidden ones never resurfaced, and new casts stayed hidden. So a cast
  that is entirely hidden (magicka drop, nothing new on the HUD) is checked for every drop, not
  only when 8 are shown. It is identified from the HUD's equipped `SpellIcon` plus the magicka
  spent.
- **Recasts:** casting a spell again replaces its previous cast (same-spell effects do not stack in
  Oblivion; the duration restarts). A new cast record removes older records of the same spell,
  and HUD entries of replaced casts are hidden. Otherwise a recast whose effects the game hides
  shows twice (seen in a fight with "Daywalker").
- **Removed effects (dispel, cure, recast):** an entry that leaves the HUD with more than 1.5 s
  left was removed, not expired; its slot is never rebuilt. If all the visible effects of a cast
  are removed, the whole cast is dropped (its rebuilt effects too). If effects of two or more
  casts go at once, it is a dispel: every rebuilt effect is dropped (seen in game: after
  "Dissipation suprême" the rebuilt Daedric Armor pieces stayed, frozen). Removals within 3 s of
  a loading screen are ignored. When the HUD reports no effect at all, the mod's clock follows
  real time (unless `bIsMenuMode`), otherwise rebuilt effects freeze.
- **Spell costs:** the list item's `Property` is the magicka cost (confirmed: the drops measured in
  game equal the costs shown in the menu, e.g. 141, 263, 280). Costs change as skills go up (one
  spell went 300 -> 263), so a cast identified by its effects updates the recorded cost from the
  magicka spent. When the HUD is not full, a hidden cast needs a strict cost match (2 points /
  2 %), so enemy magicka drains do not create effects.
- **Ties between spells with the same icons and durations** ("Arc enchanté": bound weapon +
  fortify, 50 s, cost 284; "Masse enchantée": same, cost 281) are settled by the closest recorded
  cost once the drop is complete (both are within the cost tolerance). The first duration
  estimates are rough (44 s for 50 s), so a duration filter that leaves no spell keeps waiting
  instead of rejecting all. A single candidate whose durations contradict the estimate (more than
  30 % / 5 s off) is rejected.
- **Effects of one cast can appear a few updates apart** (in game, the fortify came 0.3 s before
  the bound bow). The 8 s give-up timer counts from the first effect of the group, so the group
  gives up together. Before this, the fortify gave up alone and the lone bow was matched to
  "Épée liée" (15 s), the only spell with just a bound weapon.
- **Leftovers:** effects not claimed by a cast within 8 s (e.g. already active when the mod
  started) are matched to the spell book by icon and estimated duration when only one spell fits.
- **Learning is strict:** the hovered name must be found in the magic menu's spell lists, with a
  list icon that is one of the effects' icons. The detail panel can show another tab's item; a
  "Caméléon" entry once got another item's effects before this rule.
- **Ordering:** effects of one recognized cast form a block, sorted by name. Blocks and lone
  effects are sorted by precise time left, longest at the top. Neighbours only swap when they
  differ by more than 0.5 s, so near-equal times never flip back and forth.
  Do not group effects by "first seen at the same time": effects already active when the mod
  starts are all first seen together.
- **`player.ActiveEffectsPairingComponent.ActiveEffectList`** (`FVActiveEffectsData`: `EffectName`,
  `AdditionalEffectName`, `Magnitude`, `RemainingDuration`): always empty in practice (see above).
- Exact per-spell effect names would need an OBSE64 (C++) plugin reading the OG engine directly.
  The Nexus mod "Active Effects HUD Icons Fix" (#4994) is an OBSE64 plugin working in this area.

### HUD layout (Better HUD version of `WBP_ModernHud_Main`)

    MainRoot (Overlay)
      hudmain_root (VerticalBox)
        StatGrid (GridPanel), all in row 0:
          col 0: SizeBox_0 > WBP_ModernHud_EffectIcons (CommonListView "ActiveSpellListView")
          col 1: HorizontalBox_2 > Health, Magicka, Fatigue
          col 2: HorizontalBox_1 > DamageIndicators, WeaponIcon, MagicIcon
        Spacer_89
        Overlay_0 > LevelUpGauge, Compass
      TutorialRoot (Overlay)

Better HUD stacks the bars and lifts the icon row using negative slot paddings and render
transforms (icons scaled 0.78, health bar flipped). The SizeBox is 380 x 125, which is why only 5
icons fit.

The mod adds a full-size `CanvasPanel` to `MainRoot`, with a `GridPanel` table inside. Each
effect uses two grid rows: icon (spanning both rows) | name | time, then a thin depleting bar
(`SizeBox` > `ProgressBar`) under name and time. The original icons' SizeBox is set to **Hidden** (not Collapsed), so the
bars do not move.

### UE4SS API quirks seen on this build
- `TextBlock:SetFont(table)` fails with `push_objectproperty`. Write fields of `tb.Font` directly
  before the widget is first drawn instead.
- A **Collapsed** widget has no cached geometry; do not collapse something you need to measure.
- Measuring the bars with `GetCachedGeometry` + `SlateBlueprintLibrary` returned no size, so the
  fixed fallback position (`FallbackLeft` / `FallbackBottom`, HUD units from the bottom-left) is
  what is actually used.
- `FName("x")` only finds existing names; use `FName("x", EFindName.FNAME_Add)` for new ones.
- `print` needs an explicit `"\n"`.

## Reverse-engineering tools (recreate in `~/.cache/obr` if needed)
- `retoc` (github.com/trumank/retoc, prebuilt Linux release): `retoc to-legacy --version UE5_3`
  converts the IoStore paks to legacy `.uasset`. For base game assets, put `global.utoc/ucas` next
  to the container. Use `-f <name>` to filter.
- Class headers from a UE4SS dump of this game: github.com/nathtest/UProjOblivionRemastered
  (`Source/Altar/Public/*.h`; fetch single files from raw.githubusercontent.com).
- The `.uasset` files are unversioned (no `.usmap` is publicly downloadable). The widget tree was
  rebuilt by reading the export table: each slot's outer is its parent panel, and each widget's
  data references its slot.
- Python venv with `minidump`, `capstone` and `pefile` to read crash minidumps and disassemble the
  game exe (UFunction native thunks are found through `{name, exec function}` pointer pairs in
  `.rdata`).
