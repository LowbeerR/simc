# ============================================================================
#  Nebulous Voidcore dungeon planner — "which dungeon should I spam?"
#
#  A Nebulous Voidcore spent after a Mythic+ run is a bonus roll: it ALWAYS
#  awards one item, drawn uniformly from that dungeon's loot table filtered by
#  your loot specialisation, at the GREAT VAULT item level for the key level
#  you completed (not the end-of-dungeon ilvl). Items you have already won with
#  a Voidcore are removed from the table (duplicate protection).
#
#  So the value of one Voidcore spent in dungeon D is
#
#        E[D]  =  (1 / N_D) * SUM over eligible items i of max(0, dps_gain_i)
#
#  where N_D is the size of your filtered table. A SMALL table with a few big
#  upgrades beats a big table with the same upgrades in it — dilution is the
#  whole game, which is why this is worth computing rather than guessing.
#
#  This script measures dps_gain_i by actually simming every eligible drop
#  (one simc invocation, same engine as gear-options.ps1), then ranks the
#  season's eight keystone dungeons and Monte-Carlos the "spam it N times"
#  curve, which accounts for the fact that a second drop in a slot you already
#  upgraded is worth far less than the first.
#
#  Usage:  voidcore-dungeons.ps1                      (clipboard, +10 key)
#          voidcore-dungeons.ps1 -KeyLevel 6
#          voidcore-dungeons.ps1 -InputFile my_characters\me.simc
#          voidcore-dungeons.ps1 -Owned 251080,251085  (dup protection)
#          voidcore-dungeons.ps1 -Refresh             (re-download loot tables)
# ============================================================================
param(
    [string]$InputFile,
    [int]$KeyLevel = 10,          # keystone level completed; 0 = Mythic 0
    [double]$TargetError = 0.15,  # sim precision for each candidate drop
    [string]$FightStyle,
    [int[]]$Owned = @(),          # item ids already won via Voidcore (removed from the table)
    [int]$Rolls = 8,              # how far to project the "spam it" curve
    [switch]$Fast,                # no sims: rank by chance of an ITEM LEVEL upgrade (instant)
    [switch]$Refresh,             # ignore the cached loot tables and re-download
    [switch]$NoBrowser,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$simcRoot = $PSScriptRoot
$simcExe  = Join-Path $simcRoot 'build\simc.exe'
$itemDb   = Join-Path $simcRoot 'engine\dbc\generated\item_data.inc'
$outDir   = Join-Path $simcRoot 'my_characters'
$cacheDir = Join-Path $outDir 'lootdata'

if (-not (Test-Path $simcExe)) { throw "simc.exe not found at $simcExe - build it first (see README-LOCAL.md)" }
New-Item -ItemType Directory -Force $outDir, $cacheDir | Out-Null

# Great Vault item level per keystone level (Midnight S1). A Voidcore M+ roll
# awards at the VAULT ilvl, which is why a +10 roll (Myth 1/6, 272) is worth
# so much more than the 266 that drops at the end of the same dungeon.
$vaultIlvl = @{ 0 = 256; 2 = 259; 3 = 259; 4 = 263; 5 = 263; 6 = 266; 7 = 269; 8 = 269; 9 = 269; 10 = 272 }
$vaultTrack = @{ 0 = 'Champion 4/6'; 2 = 'Hero 1/6'; 3 = 'Hero 1/6'; 4 = 'Hero 2/6'; 5 = 'Hero 2/6'
                 6 = 'Hero 3/6'; 7 = 'Hero 4/6'; 8 = 'Hero 4/6'; 9 = 'Hero 4/6'; 10 = 'Myth 1/6' }
$kl = if ($KeyLevel -ge 10) { 10 } elseif ($KeyLevel -le 0) { 0 } elseif ($KeyLevel -eq 1) { 2 } else { $KeyLevel }
$dropIlvl = $vaultIlvl[$kl]; $dropTrack = $vaultTrack[$kl]
$klLabel  = if ($kl -eq 0) { 'Mythic 0' } else { "+$KeyLevel" }

# ============================================================================
#  1) Season loot tables, from the live client DB2s via wago.tools
#
#  simc ships no journal (Adventure Guide) data, so the loot tables come from
#  wago.tools. Two things matter for correctness:
#    * PIN THE BUILD. The default wago build is whatever is newest, which is
#      usually a PTR build carrying NEXT season's dungeon pool. We ask the
#      builds API for the live "wow" product and pin every query to it.
#    * DERIVE THE POOL, don't hardcode it. Challenge-mode maps that are also
#      listed in the "Current Season" journal tier, deduped per map keeping the
#      highest RequiredWorldStateID, top 8 by that id == this season's pool.
#      (Old-season dungeons keep their worldstate id forever, so "nonzero"
#      alone is not a selector; the tier list alone still contains last
#      season's leftovers. The intersection is what pins it down.)
# ============================================================================
function Get-LiveBuild {
    $r = Invoke-RestMethod -Uri 'https://wago.tools/api/builds' -TimeoutSec 45
    $v = $r.wow[0].version
    if (-not $v) { throw 'could not determine the live build from wago.tools' }
    return $v
}
function Get-Db2([string]$table, [string]$build) {
    $u = "https://wago.tools/db2/$table/csv?build=$build"
    (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 120).Content | ConvertFrom-Csv
}

function Build-LootTables([string]$build) {
    Write-Host "Downloading season loot tables for build $build ..." -ForegroundColor Cyan
    $tier  = Get-Db2 'JournalTier'           $build
    $inst  = Get-Db2 'JournalInstance'       $build
    $tx    = Get-Db2 'JournalTierXInstance'  $build
    $enc   = Get-Db2 'JournalEncounter'      $build
    $jei   = Get-Db2 'JournalEncounterItem'  $build
    $mcm   = Get-Db2 'MapChallengeMode'      $build

    $curTier = ($tier | Where-Object { $_.Name_lang -eq 'Current Season' } | Select-Object -First 1).ID
    if (-not $curTier) { throw 'no "Current Season" journal tier found' }

    $instById = @{}; foreach ($i in $inst) { $instById[$i.ID] = $i }
    $seasonMaps = @{}
    foreach ($r in ($tx | Where-Object { $_.JournalTierID -eq $curTier })) {
        $ji = $instById[$r.JournalInstanceID]
        if ($ji -and $ji.MapID) { $seasonMaps[$ji.MapID] = $true }
    }
    $pool = $mcm | Where-Object { $_.RequiredWorldStateID -ne '0' -and $seasonMaps[$_.MapID] } |
            Group-Object MapID |
            ForEach-Object { $_.Group | Sort-Object { [int]$_.RequiredWorldStateID } | Select-Object -Last 1 } |
            Sort-Object { [int]$_.RequiredWorldStateID } | Select-Object -Last 8

    # loot rows, grouped per dungeon, tagged with the boss they come from
    $encByInst = @{}
    foreach ($e in $enc) {
        if (-not $encByInst.ContainsKey($e.JournalInstanceID)) { $encByInst[$e.JournalInstanceID] = @() }
        $encByInst[$e.JournalInstanceID] += $e
    }
    $itemsByEnc = @{}
    foreach ($r in $jei) {
        if (-not $itemsByEnc.ContainsKey($r.JournalEncounterID)) { $itemsByEnc[$r.JournalEncounterID] = @() }
        $itemsByEnc[$r.JournalEncounterID] += $r
    }

    $out = @()
    foreach ($d in $pool) {
        $ji = $inst | Where-Object { $_.MapID -eq $d.MapID } | Select-Object -First 1
        if (-not $ji) { continue }
        $raw = @()
        foreach ($e in @($encByInst[$ji.ID])) {
            foreach ($r in @($itemsByEnc[$e.ID])) {
                $raw += [pscustomobject]@{
                    ItemId = [int]$r.ItemID; Boss = $e.Name_lang
                    Wse    = [int]$r.WorldStateExpressionID
                    Mask   = [int]$r.DifficultyMask
                }
            }
        }
        # ---- keep only what actually drops in the CURRENT dungeon -----------
        # A revived dungeon keeps its whole history in the journal: the original
        # loot sits under a WorldStateExpression that is switched OFF, and the
        # modern replacement set sits under a newer one that is switched ON
        # (Skyreach: 202 Warlords items under 50187, 29 Midnight items under
        # 50188). We cannot evaluate world-state expressions offline, but the
        # newest gate is always the live one. Ungated rows are kept only when
        # they apply to every difficulty - a restricted DifficultyMask marks
        # the leftover Normal/Heroic or Timewalking tables (Pit of Saron's mask
        # 3 Wrath rows, its mask 0 Timewalking rows), which M+ never rolls.
        $gates = @($raw | Where-Object { $_.Wse -ne 0 } | ForEach-Object { $_.Wse } | Sort-Object -Unique)
        $live  = if ($gates.Count -gt 0) { $gates[-1] } else { 0 }
        $drops = @($raw | Where-Object { ($_.Wse -eq $live -and $live -ne 0) -or ($_.Wse -eq 0 -and $_.Mask -eq -1) })
        # the same item can be listed under several rows for one boss
        $drops = @($drops | Group-Object ItemId | ForEach-Object { $_.Group[0] })
        $out += [pscustomobject]@{
            Name     = $d.Name_lang
            MapId    = [int]$d.MapID
            Bosses   = @($encByInst[$ji.ID]).Count
            Legacy   = ([int]$d.ExpansionLevel -lt 11)
            RawRows  = $raw.Count
            Drops    = @($drops)
        }
    }
    [pscustomobject]@{ Build = $build; Fetched = (Get-Date).ToString('s'); Dungeons = $out }
}

$build = $null
try { $build = Get-LiveBuild } catch { Write-Host "  (could not reach wago.tools: $($_.Exception.Message))" -ForegroundColor DarkYellow }
$cacheFile = if ($build) { Join-Path $cacheDir "loot_v2_$build.json" } else { $null }
$loot = $null
if (-not $Refresh -and $cacheFile -and (Test-Path $cacheFile)) {
    $loot = Get-Content $cacheFile -Raw | ConvertFrom-Json
    Write-Host "Loot tables: cached (build $build)"
}
if (-not $loot -and $build) {
    $loot = Build-LootTables $build
    $loot | ConvertTo-Json -Depth 8 -Compress | Set-Content $cacheFile -Encoding UTF8
}
if (-not $loot) {
    # offline: fall back to the newest cache we have
    $newest = Get-ChildItem $cacheDir -Filter 'loot_v2_*.json' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $newest) { throw 'No loot tables cached and wago.tools is unreachable. Connect once to build the cache.' }
    $loot = Get-Content $newest.FullName -Raw | ConvertFrom-Json
    Write-Host "Loot tables: offline cache $($newest.Name)" -ForegroundColor DarkYellow
}
Write-Host "Season keystone pool ($($loot.Dungeons.Count) dungeons): $((@($loot.Dungeons).Name) -join ', ')"

# ============================================================================
#  2) Parse the SimC addon export (same format gear-options.ps1 reads)
# ============================================================================
if ($InputFile) { $text = Get-Content $InputFile -Raw; Write-Host "Input: $InputFile" }
else            { $text = Get-Clipboard -Raw;         Write-Host 'Input: clipboard' }

# simc writes the two-word classes WITHOUT an underscore ("demonhunter=Name",
# "deathknight=Name") in both the addon export and its own profiles, so accept
# those spellings and normalise to the underscored keys the tables below use.
$classNames = 'death_knight','demon_hunter','deathknight','demonhunter','druid','evoker','hunter','mage','monk','paladin','priest','rogue','shaman','warlock','warrior'
$classAlias = @{ deathknight = 'death_knight'; demonhunter = 'demon_hunter' }
$classRe = "^($($classNames -join '|'))=`"?([^`"]+)`"?\s*$"
$charClass = $null; $charName = $null
foreach ($l in ($text -split "`r?`n")) { if ($l -match $classRe) { $charClass = $Matches[1]; $charName = $Matches[2]; break } }
if ($charClass -and $classAlias[$charClass]) { $charClass = $classAlias[$charClass] }
if (-not $charClass) { throw "Input does not look like a SimC addon export (no 'class=`"Name`"' line). Copy the /simc text in-game first." }
$charSpec = if ($text -match '(?m)^spec=(\w+)\s*$') { $Matches[1] } else { '?' }
Write-Host "Character: $charName ($charClass, $charSpec)"

$unsimmable = @{ priest = 'discipline', 'holy'; paladin = @('holy'); monk = @('mistweaver') }
if ($unsimmable[$charClass] -and $charSpec -in $unsimmable[$charClass]) {
    throw "SimC cannot simulate healer specs - there is no $charSpec $charClass module. Log into a damage spec and run /simc again."
}

# Accept both flavours of item line: the addon export writes "head=,id=123,..."
# while simc's own profiles (profiles\PreRaids, profiles\MID1) write
# "head=item_name,id=123,..." and use the plural shoulders=/wrists=.
$slotRe = '^(?<slot>head|neck|shoulders?|back|chest|wrists?|hands|waist|legs|feet|finger[12]|trinket[12]|main_hand|off_hand)=(?<spec>.+)$'
$slotAlias = @{ shoulders = 'shoulder'; wrists = 'wrist' }
$nameRe = '^#\s+(?<name>.+?)\s+\((?<ilvl>\d+)\)\s*$'
$equipped = @{}
$section = 'equipped'; $pendingName = '?'; $pendingIlvl = 0
foreach ($l in ($text -split "`r?`n")) {
    if ($l -match '^###\s*Gear from Bags')        { $section = 'bags';     continue }
    if ($l -match '^###\s*Weekly Reward Choices') { $section = 'vault';    continue }
    if ($l -match '^###\s*End of Weekly Reward')  { $section = 'equipped'; continue }
    if ($l -match '^###\s*Additional')            { $section = 'done';     continue }
    if ($section -ne 'equipped') { continue }
    if ($l -match $nameRe) { $pendingName = "$($Matches.name) ($($Matches.ilvl))"; $pendingIlvl = [int]$Matches.ilvl; continue }
    if ($l -match $slotRe) {
        # capture before the nested -match below clobbers $Matches
        $slot = $Matches.slot; $spec = $Matches.spec
        if ($slotAlias[$slot]) { $slot = $slotAlias[$slot] }
        if ($spec -notmatch 'id=\d+') { continue }        # not an item line
        $id = if ($spec -match 'id=(\d+)') { [int]$Matches[1] } else { 0 }
        $equipped[$slot] = [pscustomobject]@{ Slot = $slot; Spec = $spec; Name = $pendingName; Id = $id; Ilvl = $pendingIlvl }
        $pendingName = '?'; $pendingIlvl = 0
    }
}
Write-Host "Equipped items: $($equipped.Count)"

# ============================================================================
#  3) Look every loot-table item up in simc's item DB and keep what this
#     character's loot specialisation can actually roll.
#
#  Armor uses ADAPTIVE primary stats (stat types 71-74 = the Agi/Str/Int
#  combos), so an armor piece only has to match your armor type - there is no
#  separate Int/Agi version. Weapons, trinkets and off-hands do carry explicit
#  or combined primary stats, so those get a primary-stat check too.
# ============================================================================
$classMaskBit = @{ warrior=0x1; paladin=0x2; hunter=0x4; rogue=0x8; priest=0x10; death_knight=0x20; shaman=0x40
                   mage=0x80; warlock=0x100; monk=0x200; druid=0x400; demon_hunter=0x800; evoker=0x1000 }
$armorSub = @{ mage=1; priest=1; warlock=1; rogue=2; monk=2; druid=2; demon_hunter=2
               hunter=3; shaman=3; evoker=3; warrior=4; paladin=4; death_knight=4 }[$charClass]
$weaponProf = @{
    death_knight = 0,1,4,5,6,7,8;      demon_hunter = 0,7,9,13,15
    druid        = 4,5,6,10,13,15;     evoker       = 0,1,4,5,7,8,10,13,15
    hunter       = 0,1,2,3,6,7,8,10,13,15,18
    mage         = 7,10,15,19;         monk         = 0,4,6,7,10,13
    paladin      = 0,1,4,5,6,7,8;      priest       = 4,10,15,19
    rogue        = 0,4,7,13,15;        shaman       = 0,1,4,5,10,13,15
    warlock      = 7,10,15,19;         warrior      = 0,1,2,3,4,5,6,7,8,10,13,15,18
}[$charClass]

# primary stat by spec (hybrids differ per spec; class default otherwise)
$intSpecs = 'balance','restoration','mistweaver','holy','discipline','shadow','elemental','arcane','fire','frost',
            'affliction','demonology','destruction','devastation','preservation','augmentation'
$strClasses = 'warrior','death_knight'
$agiClasses = 'rogue','hunter','demon_hunter'
$intClasses = 'mage','priest','warlock','evoker'
$primary =
    if     ($intClasses -contains $charClass) { 'Int' }
    elseif ($strClasses -contains $charClass) { 'Str' }
    elseif ($agiClasses -contains $charClass) { 'Agi' }
    elseif ($charClass -eq 'paladin') { if ($charSpec -eq 'holy') { 'Int' } else { 'Str' } }
    elseif ($charClass -eq 'druid')   { if ($charSpec -in 'balance','restoration') { 'Int' } else { 'Agi' } }
    elseif ($charClass -eq 'monk')    { if ($charSpec -eq 'mistweaver') { 'Int' } else { 'Agi' } }
    elseif ($charClass -eq 'shaman')  { if ($charSpec -in 'elemental','restoration') { 'Int' } else { 'Agi' } }
    else { 'Int' }
# stat type -> which primaries it can serve (71-74 are the adaptive combos)
$primaryOf = @{ 3 = @('Agi'); 4 = @('Str'); 5 = @('Int')
                71 = @('Agi','Str','Int'); 72 = @('Agi','Str'); 73 = @('Agi','Int'); 74 = @('Str','Int') }
$invSlot = @{ 1='head'; 2='neck'; 3='shoulder'; 5='chest'; 20='chest'; 6='waist'; 7='legs'; 8='feet'
              9='wrist'; 10='hands'; 11='finger'; 12='trinket'; 16='back' }

$wanted = @{}
foreach ($d in $loot.Dungeons) { foreach ($x in $d.Drops) { $wanted[[int]$x.ItemId] = $true } }
# equipped weapons too - we need to know whether the main hand is a two-hander
foreach ($e in $equipped.Values) { if ($e.Id) { $wanted[[int]$e.Id] = $true } }
Write-Host "Resolving $($wanted.Count) loot-table items against the item DB..."

$dbLines = [System.IO.File]::ReadAllLines($itemDb)
$info = @{}
foreach ($ln in $dbLines) {
    if ($ln -notmatch '^\s*\{\s*"(?<n>[^"]*)",\s*(?<id>\d+),\s*(?<rest>.*)$') { continue }
    $id = [int]$Matches.id
    if (-not $wanted[$id]) { continue }
    $name = $Matches.n
    $f = ($Matches.rest -split ',').ForEach({ $_.Trim() })
    $stats = @()
    if ($f[15] -match 'item_stats_data\[(\d+)\]') {
        $ix = [int]$Matches[1]; $cnt = [int]$f[16]
        if ($cnt -gt 0) {
            $stats = foreach ($s in $dbLines[($ix + 1)..($ix + $cnt)]) { if ($s -match '\{\s*(\d+),') { [int]$Matches[1] } }
        }
    }
    $cm = if ($f[17] -like '0x*') { [Convert]::ToUInt64($f[17].Substring(2), 16) } else { [uint64]$f[17] }
    $info[$id] = [pscustomobject]@{
        Name = $name; InvType = [int]$f[8]; ItemClass = [int]$f[9]; SubClass = [int]$f[10]
        ClassMask = $cm; Socket = (($f[19] -replace '\D', '') -ne '0'); Stats = @($stats)
    }
}

function Test-Eligible($i) {
    if (-not $i) { return $false }
    $bit = $classMaskBit[$charClass]
    if (($i.ClassMask -band 0xFFFFFFFFL) -ne 0xFFFFFFFFL -and -not ($i.ClassMask -band $bit)) { return $false }
    $prim = @($i.Stats | Where-Object { $primaryOf[$_] })
    if ($i.ItemClass -eq 2) {                                    # weapon
        if ($weaponProf -and $i.SubClass -notin $weaponProf) { return $false }
    } elseif ($i.ItemClass -eq 4) {                              # armor
        if ($i.SubClass -ge 1 -and $i.SubClass -le 4 -and $i.SubClass -ne $armorSub) { return $false }
    } else { return $false }
    # primary-stat check where the item actually carries one
    if ($prim.Count -gt 0) {
        $ok = $false
        foreach ($p in $prim) { if ($primaryOf[$p] -contains $primary) { $ok = $true } }
        if (-not $ok) { return $false }
    }
    return $true
}
# A Voidcore roll hands you ONE item. If you wield a two-hander, an off-hand
# drop is dead weight until you also find a one-hander, so it cannot be counted
# as an upgrade - simc will happily equip an off-hand next to a staff and report
# a fat (illegal) gain, which would otherwise dominate the whole ranking.
$mhInfo = if ($equipped['main_hand']) { $info[[int]$equipped['main_hand'].Id] } else { $null }
$mhTwoHand = ($mhInfo -and $mhInfo.InvType -in 15, 17, 26)
$offHandUsable = -not ($mhTwoHand -and -not $equipped['off_hand'])
if (-not $offHandUsable) {
    Write-Host "  main hand is a two-hander with no off-hand: off-hand drops excluded (unusable from a single roll)" -ForegroundColor DarkGray
}

# which equipped slot(s) a drop competes for
function Get-TargetSlots($i) {
    if ($i.ItemClass -eq 2) {
        if ($i.InvType -in 15, 17, 26) { return @('main_hand') }            # 2H / ranged
        if ($i.InvType -in 13, 21)     { return @('main_hand', 'off_hand') }
        if ($i.InvType -eq 22)         { return @('off_hand') }
        return @()
    }
    if ($i.InvType -in 14, 23) { return @('off_hand') }                     # shield / holdable
    $s = $invSlot[$i.InvType]
    if (-not $s) { return @() }
    if ($s -eq 'finger')  { return @('finger1', 'finger2') }
    if ($s -eq 'trinket') { return @('trinket1', 'trinket2') }
    return @($s)
}

$ownedSet = @{}; foreach ($o in $Owned) { $ownedSet[[int]$o] = $true }
$dungeons = @()
foreach ($d in $loot.Dungeons) {
    $elig = @()
    foreach ($x in $d.Drops) {
        $i = $info[[int]$x.ItemId]
        if (-not (Test-Eligible $i)) { continue }
        $slots = Get-TargetSlots $i
        if ($slots.Count -eq 0) { continue }                     # not gear you can equip at all
        if ($ownedSet[[int]$x.ItemId]) { continue }              # duplicate protection
        # An item you can loot but cannot currently place (off-hand while
        # wielding a staff) still sits in the table diluting every roll, so it
        # stays in the pool with no candidate placement and scores a flat 0.
        $usable = @($slots | Where-Object { $_ -ne 'off_hand' -or $offHandUsable })
        $elig += [pscustomobject]@{ Id = [int]$x.ItemId; Name = $i.Name; Boss = $x.Boss; Slots = $usable; Info = $i }
    }
    $dungeons += [pscustomobject]@{
        Name = $d.Name; Legacy = $d.Legacy; Bosses = $d.Bosses
        Total = @($d.Drops).Count; RawRows = $d.RawRows; Eligible = $elig
    }
}
foreach ($d in $dungeons) {
    Write-Host ("  {0,-26} {1,3} eligible / {2,3} current drops  (journal lists {3})" -f `
        $d.Name, $d.Eligible.Count, $d.Total, $d.RawRows)
}

# ---------------------------------------------- current ilvl per slot ------
# The addon export carries the ilvl in the "# Name (272)" comment above each
# item; simc's own profiles carry it as ilevel= instead.
$slotIlvl = @{}
foreach ($s in $equipped.Keys) {
    $iv = [int]$equipped[$s].Ilvl
    if (-not $iv -and $equipped[$s].Spec -match 'ilevel=(\d+)') { $iv = [int]$Matches[1] }
    $slotIlvl[$s] = $iv
}
# Where a drop would actually land: for a paired family (rings, trinkets,
# weapons) you replace your WEAKEST piece, so that is the slot to price against.
function Get-BestPlacement($e) {
    $bestSlot = $null; $bestIlvl = [int]::MaxValue
    foreach ($s in $e.Slots) {
        $iv = if ($slotIlvl.ContainsKey($s)) { $slotIlvl[$s] } else { 0 }
        if ($iv -lt $bestIlvl) { $bestIlvl = $iv; $bestSlot = $s }
    }
    if (-not $bestSlot) { return $null }
    [pscustomobject]@{ Slot = $bestSlot; Ilvl = $bestIlvl }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$base  = Join-Path $outDir ("{0}_voidcore_{1}" -f ($charName -replace '[^\w-]', ''), $stamp)
$genFile = "$base.simc"; $txtFile = "$base.txt"; $reportFile = "$base`_report.html"

if ($Fast) {
    # ------------------------------------------------------- instant mode ----
    # No sims: score purely on item level. "Is this drop an upgrade?" becomes
    # "is ilvl $dropIlvl higher than what I already have in that slot?", which
    # needs nothing but the export, so it returns immediately. Blind to stats
    # and trinket procs - use the full sim run when the answer is close.
    $gain = @{}
    foreach ($d in $dungeons) {
        foreach ($e in $d.Eligible) {
            if ($gain.ContainsKey($e.Id)) { continue }
            $p = Get-BestPlacement $e
            if (-not $p) { continue }              # no usable placement -> scored 0 below
            $gain[$e.Id] = [pscustomobject]@{ Pct = [double]($dropIlvl - $p.Ilvl); Slot = $p.Slot }
        }
    }
    $metricLabel = 'ilvl'; $metricUnit = ''; $baseDps = 0
    Write-Host "Instant mode: ranking $($gain.Count) drops by item level (no sims)." -ForegroundColor Cyan
} else {

# ============================================================================
#  4) Sim every distinct eligible drop at the vault ilvl for this key level.
#     One profileset per (item, candidate slot); the item's value is the best
#     of its placements. Enchant/gem of the displaced item is carried over so
#     we compare like with like.
# ============================================================================
$gen = [System.Collections.Generic.List[string]]::new()
$psKey = @{}                                   # profileset name -> @{Id; Slot}
$seen  = @{}
foreach ($d in $dungeons) {
    foreach ($e in $d.Eligible) {
        foreach ($slot in $e.Slots) {
            $k = "$($e.Id)|$slot"
            if ($seen[$k]) { continue }
            $seen[$k] = $true
            $cur = $equipped[$slot]
            $extra = ''
            if ($cur) {
                if ($cur.Spec -match 'enchant_id=(\d+)') { $extra += ",enchant_id=$($Matches[1])" }
                if ($e.Info.Socket -and $cur.Spec -match 'gem_id=(\d+)') { $extra += ",gem_id=$($Matches[1])" }
            }
            $ov = @("$slot=,id=$($e.Id),ilevel=$dropIlvl$extra")
            # a 2H displaces the off-hand
            if ($slot -eq 'main_hand' -and $e.Info.InvType -in 15, 17, 26 -and $equipped['off_hand']) { $ov += 'off_hand=' }
            $nm = ("$($e.Id) $slot $($e.Name)" -replace '[",]', '') -replace '\s+', ' '
            foreach ($o in $ov) { $gen.Add("profileset.`"$nm`"+=$o") }
            $psKey[$nm] = [pscustomobject]@{ Id = $e.Id; Slot = $slot }
        }
    }
}
# baseline as its own profileset so we compare median to median (simc reports
# profilesets as median but the actor table as mean)
$anySlot = @($equipped.Keys)[0]
$gen.Add("profileset.`"CURRENT GEAR (baseline)`"+=$anySlot=$($equipped[$anySlot].Spec)")
Write-Host "Candidate drops to sim: $($psKey.Count) (at ilvl $dropIlvl, $dropTrack, key $klLabel)" -ForegroundColor Cyan
Set-Content -Path $genFile -Encoding UTF8 -Value ($text.TrimEnd() + "`n`n# ---- generated by voidcore-dungeons.ps1 ----`n" + ($gen -join "`n") + "`n")
if ($DryRun) { Write-Host "Dry run - wrote $genFile"; return }

$simArgs = @($genFile, "target_error=$TargetError", 'threads=0', "output=$txtFile")
if ($FightStyle) { $simArgs += "fight_style=$FightStyle" }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$simErrors = [System.Collections.Generic.List[string]]::new()
& $simcExe @simArgs 2>&1 | ForEach-Object {
    if ($_ -match 'error') { $simErrors.Add([string]$_) }
    if ($_ -match 'Generating|Profileset.+\d+/\d+|ERROR') { Write-Host "  $_" }
}
if ($LASTEXITCODE -ne 0) { throw "simc failed (exit $LASTEXITCODE): $($simErrors -join ' | ')" }
$sw.Stop(); Write-Host ("Sim done in {0:n1}s." -f $sw.Elapsed.TotalSeconds)

# -------------------------------------------------------------- results ----
$out = Get-Content $txtFile
$rows = @{}; $inPs = $false; $baseDps = $null
foreach ($l in $out) {
    if ($l -match '^Profilesets') { $inPs = $true; continue }
    if ($inPs) {
        if ($l -match '^\s*([\d.]+)\s*:\s*(.+?)\s*$') {
            $dps = [double]$Matches[1]; $opt = $Matches[2]
            if ($opt -eq 'CURRENT GEAR (baseline)') { $baseDps = $dps } else { $rows[$opt] = $dps }
        } elseif ($l -notmatch '\S') { if ($rows.Count -gt 0) { break } }
    }
}
if (-not $baseDps) { throw 'could not read the baseline dps from the sim output' }

# per item: best placement
$gain = @{}
foreach ($k in $rows.Keys) {
    $m = $psKey[$k]; if (-not $m) { continue }
    $pct = ($rows[$k] - $baseDps) / $baseDps * 100.0
    if (-not $gain.ContainsKey($m.Id) -or $pct -gt $gain[$m.Id].Pct) {
        $gain[$m.Id] = [pscustomobject]@{ Pct = $pct; Slot = $m.Slot }
    }
}
$metricLabel = 'DPS'; $metricUnit = '%'

}   # end of the simmed (non -Fast) path

# ============================================================================
#  5) Score. E[one voidcore] is the plain mean of max(0, gain) over the table,
#     because the roll is uniform and always awards something.
#
#     For "spam it", gains do NOT add up: a second drop into a slot you already
#     upgraded is only worth the difference. So we Monte-Carlo the draws
#     without replacement (that is what duplicate protection does) and keep the
#     best item per slot. Cross-slot secondary-stat overlap is not modelled, so
#     the multi-roll curve is a mild over-estimate.
# ============================================================================
$rand = [Random]::new(20260727)
foreach ($d in $dungeons) {
    $items = @()
    foreach ($e in $d.Eligible) {
        $g = $gain[$e.Id]
        # no measured placement = lootable but not equippable right now: it still
        # occupies a slot in the table, so it counts toward N at zero value
        if ($g) { $items += [pscustomobject]@{ Id = $e.Id; Name = $e.Name; Boss = $e.Boss; Slot = $g.Slot; Pct = $g.Pct } }
        else    { $items += [pscustomobject]@{ Id = $e.Id; Name = $e.Name; Boss = $e.Boss; Slot = '-';     Pct = 0.0 } }
    }
    $n = $items.Count
    $d | Add-Member Items $items -Force
    $d | Add-Member N $n -Force
    if ($n -eq 0) { $d | Add-Member EV 0.0 -Force; $d | Add-Member PUp 0.0 -Force; $d | Add-Member Curve @() -Force; continue }
    $ups = @($items | Where-Object { $_.Pct -gt 0 })
    # NB: [math]::Max(0, $x) binds the int overload in PowerShell and truncates
    # a fractional gain to 0 - keep the literal typed, or every EV comes out 0.
    $d | Add-Member EV  (($items | ForEach-Object { [math]::Max([double]0, [double]$_.Pct) } | Measure-Object -Sum).Sum / $n) -Force
    $d | Add-Member PUp ($ups.Count / [double]$n) -Force

    $maxR = [math]::Min($Rolls, $n)
    $tot = New-Object 'double[]' ($maxR + 1)
    $trials = 4000
    for ($t = 0; $t -lt $trials; $t++) {
        $bag = [System.Collections.ArrayList]::new($items)
        $best = @{}
        for ($r = 1; $r -le $maxR; $r++) {
            $pick = $bag[$rand.Next($bag.Count)]; $bag.Remove($pick)
            if ($pick.Pct -gt 0 -and (-not $best.ContainsKey($pick.Slot) -or $pick.Pct -gt $best[$pick.Slot])) {
                $best[$pick.Slot] = $pick.Pct
            }
            $s = 0.0; foreach ($v in $best.Values) { $s += $v }
            $tot[$r] += $s
        }
    }
    $curve = @(); for ($r = 1; $r -le $maxR; $r++) { $curve += [math]::Round($tot[$r] / $trials, 3) }
    $d | Add-Member Curve $curve -Force
}

# In instant mode the headline question is "how likely is a roll to land in a
# slot where I have lower?", so rank by that; EV breaks ties. The simmed mode
# ranks by expected value, where a 0.1% upgrade and a 12% one are not equal.
$ranked = if ($Fast) { @($dungeons | Sort-Object @{e={$_.PUp}; d=$true}, @{e={$_.EV}; d=$true}) }
          else       { @($dungeons | Sort-Object EV -Descending) }

# ------------------------------------------------------------- console ----
Write-Host ''
Write-Host "  BEST DUNGEON TO SPAM WITH NEBULOUS VOIDCORES" -ForegroundColor Green
Write-Host "  $charName - $charClass $charSpec - key $klLabel -> ilvl $dropIlvl ($dropTrack)" -ForegroundColor DarkGray
if ($Fast) { Write-Host "  INSTANT MODE - ranked by chance of an item-level upgrade (no sims)" -ForegroundColor DarkYellow }
Write-Host ''
$evHdr = if ($Fast) { 'E[+ilvl]' } else { 'E[+%DPS]' }
Write-Host ("  {0,-26} {1,9} {2,8} {3,9} {4,7}" -f 'Dungeon', 'P(upgrade)', $evHdr, 'best drop', 'pool')
Write-Host ('  ' + ('-' * 74))
foreach ($d in $ranked) {
    $bestItem = $d.Items | Sort-Object Pct -Descending | Select-Object -First 1
    $bn = if ($bestItem -and $bestItem.Pct -gt 0) { $bestItem.Name } else { '-' }
    $bp = if (-not $bestItem -or $bestItem.Pct -le 0) { '       -' }
          elseif ($Fast) { '{0,7:n0} ilvl' -f $bestItem.Pct }
          else           { '{0,8:n2}%' -f $bestItem.Pct }
    $ev = if ($Fast) { '{0,8:n1}' -f $d.EV } else { '{0,8:n3}%' -f $d.EV }
    Write-Host ("  {0,-26} {1,9:p0} {2} {3} {4,3}/{5,-3}" -f `
        $d.Name, $d.PUp, $ev, $bp, $d.N, $d.Total) `
        -ForegroundColor $(if ($d -eq $ranked[0]) { 'Green' } else { 'Gray' })
    Write-Host ("      best drop: $bn") -ForegroundColor DarkGray
}
Write-Host ''
$top = $ranked[0]
if ($Fast) {
    Write-Host ("  -> Spam $($top.Name): {0:p0} chance each Voidcore lands in a slot where you have lower (avg +{1:n1} ilvl)." -f $top.PUp, $top.EV) -ForegroundColor Green
    # flag when "most likely" and "most valuable" disagree - a table full of
    # +2 ilvl trinkets can out-rank one holding a single +40 weapon
    $byEv = @($dungeons | Sort-Object EV -Descending)[0]
    if ($byEv.Name -ne $top.Name) {
        Write-Host ("     Note: $($byEv.Name) is likelier to matter - lower odds ({0:p0}) but a bigger average jump (+{1:n1} ilvl)." -f $byEv.PUp, $byEv.EV) -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  -> Spam $($top.Name): $('{0:n3}' -f $top.EV)% expected DPS per Voidcore." -ForegroundColor Green
    if ($top.Curve.Count -ge 1) {
        Write-Host ("     Spamming it: " + (( 1..$top.Curve.Count | ForEach-Object { "$_ roll$(if($_ -gt 1){'s'}) +$('{0:n2}' -f $top.Curve[$_-1])%" }) -join ' | ')) -ForegroundColor DarkGray
    }
}
Write-Host ''

# ============================================================================
#  6) Self-contained interactive HTML report (embedded CSS/JS, no internet),
#     styled to match the gear-scanner report.
# ============================================================================
function New-VoidcoreReport {
    param($Path, $Meta, $Rows)
    function ConvertTo-JsonArray($items) {
        if (-not $items -or @($items).Count -eq 0) { return '[]' }
        '[' + ((@($items) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
    }
    $tpl = @'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root{
  --bg:#14161c; --panel:#1c1f29; --panel2:#232734; --text:#e6e8ee; --muted:#9aa0ad;
  --gain:#39d98a; --loss:#ff6b6b; --accent:#7aa2ff; --warn:#ffd24a; --dim:#6f7787;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:22px}
h1{font-size:22px;margin:0 0 2px}
.sub{color:var(--muted);font-size:13px;margin-bottom:18px}
.sub b{color:var(--text)}
.panel{background:var(--panel);border:1px solid #2a2f3b;border-radius:12px;padding:18px;margin-bottom:20px}
.panel h2{font-size:15px;margin:0 0 14px;letter-spacing:.3px;text-transform:uppercase;color:var(--muted)}
.head{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
.big{font-size:34px;font-weight:700;color:var(--gain);line-height:1.1}
.headname{font-size:20px;font-weight:600}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #262b36;vertical-align:middle}
th{font-size:11px;text-transform:uppercase;letter-spacing:.4px;color:var(--muted);font-weight:600}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
tr.d{cursor:pointer}
tr.d:hover{background:#20242f}
tr.top td{background:#1b2b23}
.bar{height:9px;border-radius:5px;background:#2a3040;overflow:hidden;min-width:60px}
.bar>i{display:block;height:100%;background:var(--gain)}
.bar.neg>i{background:var(--loss)}
.pill{display:inline-block;padding:1px 7px;border-radius:6px;font-size:11px;font-weight:600;
  border:1px solid #3a4150;color:var(--muted);white-space:nowrap}
.pill.legacy{color:var(--warn);border-color:var(--warn)}
.pill.slot{color:var(--accent);border-color:var(--accent)}
.det{display:none;background:#171a22}
.det.open{display:table-row}
.det td{padding:0 10px 12px 34px}
.det table{margin-top:4px}
.det th,.det td{border-bottom:1px solid #21252e;padding:5px 8px}
.zero{color:var(--dim)}
.note{color:var(--muted);font-size:12.5px}
.note b{color:var(--text)}
.legend{display:flex;gap:16px;flex-wrap:wrap;margin:10px 0 4px;font-size:12px;color:var(--muted)}
.legend span{display:flex;align-items:center;gap:6px}
.legend i{width:12px;height:3px;border-radius:2px;display:inline-block}
.caret{display:inline-block;width:10px;color:var(--muted)}
</style></head><body><div class="wrap">
<h1>__TITLE__</h1>
<div class="sub">__SUBTITLE__</div>

<div class="panel">
  <h2>Verdict</h2>
  <div class="head"><div class="big" id="hEv"></div><div><div class="headname" id="hName"></div>
  <div class="note" id="hWhy"></div></div></div>
</div>

<div class="panel">
  <h2>Every dungeon, ranked by expected DPS per Voidcore</h2>
  <table id="tbl"><thead><tr>
    <th></th><th>Dungeon</th><th class="num" id="thEv"></th><th style="width:150px"></th>
    <th class="num">P(upgrade)</th><th class="num">Pool</th><th>Best drop in table</th>
  </tr></thead><tbody></tbody></table>
  <div class="note" style="margin-top:12px">Click a dungeon to see every item its table can hand you.</div>
</div>

<div class="panel">
  <h2>Spamming it: expected total gain after N Voidcores</h2>
  <svg id="chart" width="100%" height="260" role="img"></svg>
  <div class="legend" id="legend"></div>
  <div class="note">Draws without replacement (duplicate protection), keeping the best item per slot.
  Gains do not simply add: a second drop into a slot you already upgraded is worth only the difference.
  Cross-slot secondary-stat overlap is not modelled, so this curve reads slightly high.</div>
</div>

<div class="panel">
  <h2>How this was computed</h2>
  <div class="note" id="method"></div>
</div>
</div>
<script>
const DATA = __ROWS__, META = __META__;
const FAST = META.Metric === 'ilvl';
// instant mode measures item levels, simmed mode measures percent DPS
const f2 = x => FAST ? ((x>=0?'+':'') + Math.round(x) + ' ilvl')
                     : ((x>=0?'+':'') + x.toFixed(2) + '%');
const evTxt = x => FAST ? ('+' + x.toFixed(1) + ' ilvl') : (x.toFixed(3) + '%');
document.getElementById('thEv').textContent = FAST ? 'E[+ilvl]' : 'E[+% DPS]';
const tb = document.querySelector('#tbl tbody');
const maxEv = Math.max(...DATA.map(d=>d.EV), 0.0001);

DATA.forEach((d,ix)=>{
  const tr = document.createElement('tr');
  tr.className = 'd' + (ix===0?' top':'');
  const best = d.Items.slice().sort((a,b)=>b.Pct-a.Pct)[0];
  const bestTxt = best && best.Pct>0 ? `${best.Name} <span class="pill slot">${best.Slot}</span> ${f2(best.Pct)}` : '<span class="zero">nothing is an upgrade</span>';
  tr.innerHTML = `<td><span class="caret">&#9656;</span></td>
    <td>${d.Name} ${d.Legacy?'<span class="pill legacy">revived</span>':''}</td>
    <td class="num"><b>${evTxt(d.EV)}</b></td>
    <td><div class="bar"><i style="width:${(d.EV/maxEv*100).toFixed(1)}%"></i></div></td>
    <td class="num">${Math.round(d.PUp*100)}%</td>
    <td class="num">${d.N}<span class="zero">/${d.Total}</span></td>
    <td>${bestTxt}</td>`;
  const det = document.createElement('tr');
  det.className = 'det';
  const items = d.Items.slice().sort((a,b)=>b.Pct-a.Pct);
  const mx = Math.max(...items.map(i=>Math.abs(i.Pct)), 0.0001);
  det.innerHTML = `<td colspan="7"><table><thead><tr><th>Item</th><th>Boss</th><th>Slot</th>
    <th class="num">${FAST?'&Delta; ilvl':'&Delta; DPS'}</th><th style="width:130px"></th><th class="num">roll chance</th></tr></thead><tbody>` +
    items.map(i=>`<tr><td>${i.Name}</td><td class="zero">${i.Boss}</td>
      <td>${i.Slot==='-'?'<span class="zero">unusable</span>':'<span class="pill slot">'+i.Slot+'</span>'}</td>
      <td class="num" style="color:${i.Pct>0.001?'var(--gain)':(i.Pct<-0.001?'var(--loss)':'var(--dim)')}">${i.Pct>0.001||i.Pct<-0.001?f2(i.Pct):'0'}</td>
      <td><div class="bar${i.Pct<0?' neg':''}"><i style="width:${(Math.abs(i.Pct)/mx*100).toFixed(1)}%"></i></div></td>
      <td class="num zero">${(100/d.N).toFixed(1)}%</td></tr>`).join('') + `</tbody></table></td>`;
  tr.onclick = ()=>{ det.classList.toggle('open'); tr.querySelector('.caret').innerHTML = det.classList.contains('open')?'&#9662;':'&#9656;'; };
  tb.appendChild(tr); tb.appendChild(det);
});

// instant mode leads with the odds, simmed mode with the expected value
document.getElementById('hEv').textContent = FAST ? Math.round(DATA[0].PUp*100) + '%' : evTxt(DATA[0].EV);
document.getElementById('hName').textContent = FAST
  ? 'of rolls land in a slot where you have lower - ' + DATA[0].Name
  : 'per Voidcore in ' + DATA[0].Name;
document.getElementById('hWhy').innerHTML = FAST
  ? `${DATA[0].N} items can drop for you there; the ones that beat what you wear average ${evTxt(DATA[0].EV)} across the whole table.`
  : `${DATA[0].N} items can drop for you there, ${Math.round(DATA[0].PUp*100)}% of them an upgrade. ` +
    (DATA[1] ? `That is ${(DATA[0].EV/Math.max(DATA[1].EV,1e-6)).toFixed(2)}x the next best (${DATA[1].Name}, ${evTxt(DATA[1].EV)}).` : '');

// ---- spam curve -----------------------------------------------------------
const COLORS = ['#39d98a','#7aa2ff','#ffd24a','#ff7062','#b07cff'];
const top = DATA.slice(0,5).filter(d=>d.Curve.length);
const svg = document.getElementById('chart');
const W = svg.clientWidth || 1100, H = 260, PL = 46, PR = 12, PT = 12, PB = 30;
const maxN = Math.max(...top.map(d=>d.Curve.length), 1);
const maxY = Math.max(...top.flatMap(d=>d.Curve), 0.0001) * 1.08;
const X = i => PL + (maxN<=1?0:(i/(maxN-1))*(W-PL-PR));
const Y = v => H - PB - (v/maxY)*(H-PT-PB);
let s = '';
for (let g=0; g<=4; g++){ const v = maxY*g/4, y = Y(v);
  s += `<line x1="${PL}" y1="${y}" x2="${W-PR}" y2="${y}" stroke="#262b36"/>`;
  s += `<text x="${PL-8}" y="${y+4}" fill="#9aa0ad" font-size="11" text-anchor="end">${FAST?Math.round(v):v.toFixed(1)+'%'}</text>`; }
for (let i=0;i<maxN;i++){ s += `<text x="${X(i)}" y="${H-10}" fill="#9aa0ad" font-size="11" text-anchor="middle">${i+1}</text>`; }
s += `<text x="${(W+PL)/2}" y="${H-0}" fill="#6f7787" font-size="11" text-anchor="middle"></text>`;
top.forEach((d,i)=>{
  const pts = d.Curve.map((v,j)=>`${X(j)},${Y(v)}`).join(' ');
  s += `<polyline points="${pts}" fill="none" stroke="${COLORS[i%5]}" stroke-width="2.5" stroke-linejoin="round"/>`;
  d.Curve.forEach((v,j)=>{ s += `<circle cx="${X(j)}" cy="${Y(v)}" r="3" fill="${COLORS[i%5]}"><title>${d.Name}: ${(j+1)} voidcores -> ${f2(v)}</title></circle>`; });
});
svg.innerHTML = s;
document.getElementById('legend').innerHTML =
  top.map((d,i)=>`<span><i style="background:${COLORS[i%5]}"></i>${d.Name}</span>`).join('') +
  '<span style="color:#6f7787">x axis = Voidcores spent</span>';

document.getElementById('method').innerHTML = META.Method;
</script></body></html>
'@
    $html = $tpl.
        Replace('__TITLE__',    $Meta.Title).
        Replace('__SUBTITLE__', $Meta.Subtitle).
        Replace('__ROWS__',     (ConvertTo-JsonArray $Rows)).
        Replace('__META__',     ($Meta | ConvertTo-Json -Compress -Depth 5))
    Set-Content -Path $Path -Value $html -Encoding UTF8
}

$method = if ($Fast) { @"
<b>Instant mode</b> (-Fast): no simulations. A drop counts as an upgrade purely on
item level &mdash; is <b>ilvl $dropIlvl ($dropTrack)</b>, what a Voidcore roll awards at key $klLabel,
higher than what you currently wear in that slot? For paired slots (rings, trinkets,
weapons) it prices against your <b>weakest</b> piece, since that is the one a drop replaces.
<br><br>
A Voidcore roll always awards one item, drawn uniformly from your loot-spec-filtered
table, so <b>P(upgrade)</b> is literally the share of that dungeon's table that beats your
current gear, and <b>E[+ilvl]</b> averages the item-level jump across the whole table
(non-upgrades counted as zero, because they still consume the roll).
<br><br>
<b>This is blind to stats and trinket procs.</b> A same-ilvl trinket with a far better effect
scores 0 here, and a higher-ilvl piece with the wrong secondaries can be a DPS loss.
When two dungeons are close, or when weapons and trinkets are involved, drop the
-Fast switch and let it sim &mdash; that run measures actual DPS.
<br><br>
Loot tables come from the live client DB2s (build $($loot.Build)) via wago.tools; the season
pool is derived from MapChallengeMode rather than hardcoded, and for revived dungeons
only the currently-enabled loot set is counted. Items you can loot but not equip right
now (off-hands while you wield a two-hander) stay in the pool at zero value, because
they still dilute every roll.
"@ } else { @"
A Nebulous Voidcore spent after a Mythic+ run is a bonus roll that <b>always</b> awards one item,
drawn uniformly from that dungeon's loot table filtered by your loot specialisation, at the
<b>Great Vault</b> item level for the key you completed &mdash; <b>ilvl $dropIlvl ($dropTrack)</b> at key $klLabel,
not the $(if($kl -ge 10){266}else{'end-of-dungeon'}) ilvl that drops from the chest.
So one Voidcore in dungeon D is worth <b>E[D] = (1/N) &times; &Sigma; max(0, gain)</b> over its N eligible items:
a small table with a few big upgrades beats a large table holding the same upgrades.
<br><br>
Each of the $($psKey.Count) candidate drops was simulated by simc at target_error=$TargetError
against your current gear (baseline $([math]::Round($baseDps)) DPS), placed in its best slot, carrying over
the enchant and gem of the piece it displaces. Loot tables come from the live client DB2s
(build $($loot.Build)) via wago.tools; the season pool is derived from MapChallengeMode rather than
hardcoded, and for revived dungeons only the currently-enabled loot set is counted.
<br><br>
<b>Caveats.</b> Items you can loot but not equip right now (off-hands while you wield a two-hander)
stay in the pool at zero value, because they still dilute every roll. Duplicate protection is modelled
by removing items you pass via <code>-Owned</code>. Trinket and weapon values are sim-measured, so
proc-driven items are handled properly, but the multi-roll curve ignores secondary-stat overlap
between slots and therefore reads slightly high.
"@ }

$reportRows = @($ranked | ForEach-Object {
    [pscustomobject]@{
        Name = $_.Name; EV = [math]::Round($_.EV, 4); PUp = [math]::Round($_.PUp, 4)
        N = $_.N; Total = $_.Total; Legacy = [bool]$_.Legacy; Curve = @($_.Curve)
        Items = @($_.Items | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Boss = $_.Boss; Slot = $_.Slot; Pct = [math]::Round($_.Pct, 3) } })
    }
})
$howMeasured = if ($Fast) { "<b>instant mode</b> (item level only, no sims)" }
               else { "$($psKey.Count) drops simmed at target_error $TargetError" }
$meta = [pscustomobject]@{
    Title    = "Voidcore plan - $charName"
    Subtitle = "<b>$charName</b> &middot; $charClass $charSpec &middot; key <b>$klLabel</b> &rarr; drops at <b>ilvl $dropIlvl</b> ($dropTrack) &middot; $howMeasured &middot; client build $($loot.Build) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Method   = $method
    Metric   = $metricLabel
}
New-VoidcoreReport -Path $reportFile -Meta $meta -Rows $reportRows
Write-Host "Report: $reportFile" -ForegroundColor Cyan
if (-not $NoBrowser) { Start-Process $reportFile }
