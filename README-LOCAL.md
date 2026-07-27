# SimulationCraft — local setup (quickstart)

Built locally on this machine from the `midnight` branch (CLI only, no Qt GUI).
The executable is at `build\simc.exe`.

## The easy way: the "WoW Gear Scanner" desktop shortcut

1. In WoW, type `/simc` and press `Ctrl+C`.
2. Double-click **WoW Gear Scanner** on the desktop (or `WoW Gear Scanner.bat`
   here). The window pre-fills from the clipboard - otherwise paste with
   `Ctrl+V`.
3. Pick precision/fight style if you like, hit **Run all sims**.
4. A console shows progress and the ranked upgrade table; the HTML report
   opens in the browser. It sims *everything*: bag swaps, ring/trinket pairs,
   weapon combos, crafted candidates, Great Vault choices, Voidforge upgrades
   (details under "Gear scanner" below).

## Simming your own character (single report, no gear comparison)

1. Install the **"Simulationcraft"** addon in WoW (available on CurseForge /
   WowUp / Wago — it's the official companion addon by the SimC team).
2. In-game, type `/simc` — a window pops up with your character as text.
   Press `Ctrl+C` to copy it.
3. Paste it into a new file in the `my_characters\` folder, e.g.
   `my_characters\mychar.simc`.
4. Drag that file onto **`run-sim.bat`** (or run
   `run-sim.bat my_characters\mychar.simc` in a terminal).
5. An HTML report opens in your browser with DPS, scale factors, buffs, etc.

> Why an addon export instead of fetching from the Armory? The armory option
> requires your own Blizzard API client id/secret. The addon export also
> captures things the Armory misses (exact talents, gear in bags).

## Gear scanner (sim-gear.bat)

Copy the `/simc` export to the clipboard (or save it to a file) and run
`sim-gear.bat` — it sims every gear alternative in one go and prints a ranked
table:

* every bag item swapped into its slot (as-is **and** fully crest-upgraded on
  its track), all ring/trinket pairs, all legal weapon combos
* crest upgrades for the gear you are wearing now (anything not yet at rank 6)
* every secondary-stat mix of your equipped crafted items
* **every craftable current-tier item for your armor type** (e.g. the Martyr's
  set for cloth) plus crafted neck/ring/cloak, simmed at ilvl 285 — items with
  selectable stats get all six stat mixes; fixed-stat items show their stats
  in `[brackets]`. Enchant/gem of the displaced item is carried over.
* **every Great Vault choice**, three ways: as it drops, `MAXED` (fully
  upgraded on its track, ignoring crest costs), and for Hero/Myth weapons and
  trinkets `MAX+VOIDFORGED` (Ascendant Voidcore, ilvl 298).
  ⚠ The addon only exports the vault while rewards are **unclaimed** — run
  `/simc` *before* picking your vault reward.
* **Voidforge upgrades for gear you already own**: equipped/bag weapons and
  trinkets on a maxed Hero/Myth track get a `voidforge` variant (ilvl 298);
  rank-5 crafted gets +10 ilvls. Already-forged items are skipped.

After the scan it runs one extra sim with the **best upgrade of every slot
combined** (only winners that clearly beat the sim noise), so the table also
shows what everything stacked together is worth — usually less than the sum
of the parts because of secondary-stat diminishing returns.

To keep runs fast, alternatives that stay below your lowest equipped ilvl
*even when fully upgraded* are skipped by default. Pass `-MinIlvl 0` to sim
everything (do that when a lower-ilvl trinket effect might still compete),
or `-MinIlvl 270` for a custom floor.

Options: `gear-options.ps1 -CraftedIlvl 0` skips the crafted scan,
`-CraftedIlvl 290` sims them at another ilvl, `-TargetError 0.1` for more
precision, `-FightStyle DungeonSlice` for an M+-ish fight, `-DryRun` to only
generate the profileset file without simulating.

## Voidcore dungeon planner (voidcore-dungeons.ps1)

Answers "which Mythic+ dungeon should I spam my Nebulous Voidcores in?"

A Voidcore spent after an M+ run is a bonus roll: it **always** awards one
item, drawn uniformly from that dungeon's loot table filtered by your loot
spec, at the **Great Vault** item level for the key you finished — *not* the
lower end-of-dungeon ilvl. So one Voidcore in dungeon D is worth

```
E[D] = (1 / N) x SUM over its N eligible items of max(0, dps gain)
```

which means a **small** table with a few big upgrades beats a large table
holding the same upgrades. That dilution is the whole point of computing this
instead of guessing: in testing, Seat of the Triumvirate held the single
biggest upgrade available (+20.8%) yet ranked 4th, because its 16-item pool
made any particular item unlikely.

Copy the `/simc` export to the clipboard and double-click **`voidcore.bat`** —
same pattern as `sim-gear.bat`. You can also drag a `.simc` file onto it.

```
voidcore.bat                                (clipboard export, +10 key)
voidcore.bat -Fast                          (instant: no sims, item level only)
voidcore.bat -KeyLevel 6                    (rolls award ilvl 266 instead of 272)
voidcore.bat my_characters\me.simc          (or drag the file onto voidcore.bat)
voidcore.bat -Owned 251080,251085           (duplicate protection: already won these)
voidcore.bat -Refresh                       (re-download the loot tables)
```

### Instant mode: which dungeon is likeliest to drop a Myth item in a weak slot

Double-click **`voidcore-fast.bat`** (clipboard export, same as the other
launchers, or drag a `.simc` onto it). It is just `voidcore.bat` with `-Fast`,
and takes the same switches:

```
voidcore-fast.bat                           (clipboard export, +10 key)
voidcore-fast.bat -KeyLevel 6               (rolls award ilvl 266)
voidcore-fast.bat my_characters\me.simc
```

`-Fast` skips simc entirely and answers in ~3 seconds: **how likely is one
Voidcore to land in a slot where you currently have lower item level?** It
compares the roll's ilvl against what you wear, pricing paired slots (rings,
trinkets, weapons) against your *weakest* piece, since that is the one a drop
replaces. It ranks by that probability and shows the average item-level jump
next to it.

The trade-off is that it is blind to stats and trinket procs, and the two modes
genuinely disagree. On a geared Vengeance DH, `-Fast` picked Pit of Saron (71%
chance of an ilvl upgrade) while the full sim picked Windrunner Spire — because
Windrunner's Emberwing Feather is a *same-ilvl* trinket, so it scores zero on
item level yet sims as the single biggest DPS gain available. Use `-Fast` to
decide quickly, drop the switch when the answer is close or when weapons and
trinkets are in play.

The `.bat` just forwards to `voidcore-dungeons.ps1`, so every switch above works
if you call the script directly too. Runs on both `pwsh` 7 and Windows
PowerShell 5.1 (the launcher prefers `pwsh` when present).

It sims every eligible drop at the vault ilvl, ranks all eight season dungeons
by expected DPS per Voidcore, and writes an interactive
`*_voidcore_*_report.html` with a per-item breakdown and a "spam it N times"
curve.

Key-level → roll ilvl (Midnight S1): M0 256, +2-3 259, +4-5 263, +6 266,
+7-9 269, +10 and up 272 (Myth 1/6).

Loot tables come from the live client DB2s via wago.tools, cached under
`my_characters\lootdata\`. Two things it gets right that are easy to get
wrong: it **pins the live build** (the newest build on wago is usually a PTR
one carrying *next* season's dungeon pool), and it **derives** the eight-dungeon
pool from `MapChallengeMode` rather than hardcoding it. For revived dungeons
only the currently-enabled loot set is counted — Skyreach's journal entry still
lists 424 rows of Warlords loot that no longer drops, against 29 that do.

If everything comes back at ~0%, that is the real answer: your gear is already
above the ilvl the roll awards. Try a lower `-KeyLevel` to confirm, or spend
the cores on an alt.

## Useful extras

Add options at the end of the command line, e.g.:

```
run-sim.bat my_characters\mychar.simc        (basic run)
build\simc.exe my_characters\mychar.simc iterations=10000 html=report.html
build\simc.exe my_characters\mychar.simc calculate_scale_factors=1 html=report.html   (stat weights, slow)
build\simc.exe my_characters\mychar.simc fight_style=DungeonSlice html=report.html    (M+-ish fight)
```

Bundled reference profiles for every spec live in `profiles\MID1\` and
`profiles\PreRaids\` — drag any of them onto `run-sim.bat` to try.

## This fork + staying up to date

This checkout uses two remotes:

* **`upstream`** = the official `simulationcraft/simc` repo (engine + game data)
* **`origin`** = your own fork (where your scanner tooling is backed up)

The engine changes constantly with patches, so pull `upstream` often. **You live
on the `personal` branch** (it has your scanner scripts); the engine updates are
merged straight into it. Don't `checkout midnight` for normal use — the scripts
are tracked on `personal` only, so switching away hides them from the folder.

**One-time setup** (after clicking *Fork* on the simc GitHub page):

```powershell
git -C C:\Users\Rikard\Documents\GitHub\simc remote rename origin upstream
git -C C:\Users\Rikard\Documents\GitHub\simc remote add origin https://github.com/<your-user>/simc.git
git -C C:\Users\Rikard\Documents\GitHub\simc push -u origin personal
```

**Each update** (stay on `personal`; merge the latest engine, then rebuild):

```powershell
git pull upstream midnight         # merge the latest engine into personal (no conflicts - your files are all new)
git push origin personal           # back up to your fork
cmd /c '"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul && cmake --build C:\Users\Rikard\Documents\GitHub\simc\build'
```

(The CMake configure step only needs rerunning if it complains:
`cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF -DBUILD_TESTING=OFF`
from a VS developer prompt.)

`my_characters\` (your character exports + generated reports) is kept out of git
via `.git\info\exclude`, and `build\` is ignored by simc's own `.gitignore`, so
neither ends up on your fork.
