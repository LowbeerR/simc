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
