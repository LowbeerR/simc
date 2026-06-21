# ============================================================================
#  WoW Gear Scanner - paste window for gear-options.ps1
#
#  Opens a window: paste your /simc addon export (pre-filled from the
#  clipboard when possible), pick precision + fight style, hit Run.
#  Progress shows in a console window; the ranked table + HTML report follow.
#
#  Launched by "WoW Gear Scanner.bat" / the desktop shortcut.
# ============================================================================
param([switch]$SelfTest)   # build everything and do a -DryRun scan, no window

$ErrorActionPreference = 'Stop'
$simcRoot = $PSScriptRoot
$scanner  = Join-Path $simcRoot 'gear-options.ps1'
$outDir   = Join-Path $simcRoot 'my_characters'
New-Item -ItemType Directory -Force $outDir | Out-Null

$classNames = 'death_knight','demon_hunter','druid','evoker','hunter','mage','monk','paladin','priest','rogue','shaman','warlock','warrior'
$classRe = "(?m)^($($classNames -join '|'))=`"?([^`"\r\n]+)`"?\s*$"

function Get-ExportCharacter([string]$text) {
    if ($text -and $text -match $classRe) {
        $c = @{ Class = $Matches[1]; Name = $Matches[2]; Spec = '?' }
        if ($text -match '(?m)^spec=(\w+)\s*$') { $c.Spec = $Matches[1] }
        return $c
    }
    return $null
}

# specs simc has no module for at all (see gear-options.ps1)
$unsimmable = @{ priest = 'discipline', 'holy'; paladin = @('holy'); monk = @('mistweaver') }
function Test-Unsimmable($char) {
    return [bool]($unsimmable[$char.Class] -and $char.Spec -in $unsimmable[$char.Class])
}

function Start-Scan([string]$text, [double]$targetError, [string]$fightStyle, [switch]$Test) {
    $char = Get-ExportCharacter $text
    $file = Join-Path $outDir "$(($char.Name -replace '[^\w-]', ''))_pasted.simc"
    Set-Content -Path $file -Value $text -Encoding UTF8
    $cmd = "& '$scanner' -InputFile '$file' -TargetError $targetError"
    if ($fightStyle) { $cmd += " -FightStyle $fightStyle" }
    if ($Test) {
        & $scanner -InputFile $file -TargetError $targetError -DryRun
        return
    }
    # keep the console open even when the scan fails, so errors stay readable
    $cmd = "try { $cmd } catch { Write-Host `$_ -ForegroundColor Red }; Write-Host ''; Read-Host 'Press Enter to close'"
    $engine = (Get-Process -Id $PID).Path
    Start-Process $engine -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd -WorkingDirectory $simcRoot
}

if ($SelfTest) {
    $sample = Get-Content (Join-Path $outDir 'heerria.simc') -Raw
    $char = Get-ExportCharacter $sample
    if (-not $char) { throw 'SelfTest: character detection failed' }
    Write-Host "SelfTest: detected $($char.Name) ($($char.Class))"
    Start-Scan $sample 0.2 '' -Test
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form                 = New-Object Windows.Forms.Form
$form.Text            = 'WoW Gear Scanner'
$form.Size            = New-Object Drawing.Size(780, 660)
$form.MinimumSize     = New-Object Drawing.Size(560, 420)
$form.StartPosition   = 'CenterScreen'
$icoFile = Join-Path $simcRoot 'qt\icon\simc.ico'
if (Test-Path $icoFile) { $form.Icon = New-Object Drawing.Icon($icoFile) }

$lbl              = New-Object Windows.Forms.Label
$lbl.Text         = 'Paste your SimC addon export below  (in WoW: /simc, then Ctrl+C - then Ctrl+V here):'
$lbl.Location     = New-Object Drawing.Point(12, 9)
$lbl.AutoSize     = $true

$txt              = New-Object Windows.Forms.TextBox
$txt.Multiline    = $true
$txt.ScrollBars   = 'Both'
$txt.WordWrap     = $false
$txt.Font         = New-Object Drawing.Font('Consolas', 9)
$txt.Location     = New-Object Drawing.Point(12, 30)
$txt.Size         = New-Object Drawing.Size(740, 510)
$txt.Anchor       = 'Top,Bottom,Left,Right'

$status           = New-Object Windows.Forms.Label
$status.Location  = New-Object Drawing.Point(12, 552)
$status.AutoSize  = $true
$status.Anchor    = 'Bottom,Left'

$lblSpeed          = New-Object Windows.Forms.Label
$lblSpeed.Text     = 'Precision:'
$lblSpeed.Location = New-Object Drawing.Point(12, 585)
$lblSpeed.AutoSize = $true
$lblSpeed.Anchor   = 'Bottom,Left'

$cmbSpeed          = New-Object Windows.Forms.ComboBox
$cmbSpeed.DropDownStyle = 'DropDownList'
[void]$cmbSpeed.Items.AddRange(@('Fast (~1 min)', 'Normal (recommended)', 'Precise (slow)'))
$cmbSpeed.SelectedIndex = 1
$cmbSpeed.Location = New-Object Drawing.Point(75, 581)
$cmbSpeed.Width    = 165
$cmbSpeed.Anchor   = 'Bottom,Left'

$lblFight          = New-Object Windows.Forms.Label
$lblFight.Text     = 'Fight:'
$lblFight.Location = New-Object Drawing.Point(258, 585)
$lblFight.AutoSize = $true
$lblFight.Anchor   = 'Bottom,Left'

$cmbFight          = New-Object Windows.Forms.ComboBox
$cmbFight.DropDownStyle = 'DropDownList'
[void]$cmbFight.Items.AddRange(@('Single target (raid boss)', 'Mythic+ style (DungeonSlice)'))
$cmbFight.SelectedIndex = 0
$cmbFight.Location = New-Object Drawing.Point(295, 581)
$cmbFight.Width    = 190
$cmbFight.Anchor   = 'Bottom,Left'

$btn               = New-Object Windows.Forms.Button
$btn.Text          = 'Run all sims'
$btn.Font          = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$btn.Size          = New-Object Drawing.Size(180, 34)
$btn.Location      = New-Object Drawing.Point(572, 576)
$btn.Anchor        = 'Bottom,Right'
$btn.Enabled       = $false

$validate = {
    $char = Get-ExportCharacter $txt.Text
    if ($char -and (Test-Unsimmable $char)) {
        $status.Text      = "$($char.Name) is in $($char.Spec) - SimC cannot simulate healer specs. Log into a damage spec (e.g. shadow) and /simc again."
        $status.ForeColor = [Drawing.Color]::Firebrick
        $btn.Enabled      = $false
    } elseif ($char) {
        $extra = if ($txt.Text -notmatch '###\s*Weekly Reward Choices') {
            '   (no Great Vault section - export before claiming rewards to include it)' } else { '' }
        $status.Text      = "Character detected: $($char.Name) ($($char.Class), $($char.Spec))$extra"
        $status.ForeColor = [Drawing.Color]::DarkGreen
        $btn.Enabled      = $true
    } else {
        $status.Text      = 'Waiting for a valid /simc export...'
        $status.ForeColor = [Drawing.Color]::Gray
        $btn.Enabled      = $false
    }
}
$txt.add_TextChanged($validate)

$btn.add_Click({
    # filter-scan precision only; winners are always refined to 0.05 regardless
    $te = @(0.5, 0.3, 0.1)[$cmbSpeed.SelectedIndex]
    $fight = if ($cmbFight.SelectedIndex -eq 1) { 'DungeonSlice' } else { '' }
    Start-Scan $txt.Text $te $fight
    $form.Close()
})

# pre-fill from clipboard if it already holds an export
try {
    $clip = Get-Clipboard -Raw -ErrorAction Stop
    if (Get-ExportCharacter $clip) { $txt.Text = $clip }
} catch {}

$form.Controls.AddRange(@($lbl, $txt, $status, $lblSpeed, $cmbSpeed, $lblFight, $cmbFight, $btn))
& $validate
if ($env:GEARGUI_UITEST) {   # build-only smoke test, no window
    $txt.Text = Get-Content (Join-Path $outDir 'heerria.simc') -Raw
    Write-Host "UI built OK. Status: '$($status.Text)' RunEnabled: $($btn.Enabled)"
    $healerFile = Join-Path $outDir 'lowbeer.simc'
    if (Test-Path $healerFile) {
        $txt.Text = Get-Content $healerFile -Raw
        Write-Host "Healer paste -> Status: '$($status.Text)' RunEnabled: $($btn.Enabled)"
    }
    $form.Dispose()
} else {
    [void]$form.ShowDialog()
}
