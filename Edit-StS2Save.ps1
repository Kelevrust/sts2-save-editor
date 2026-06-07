<#
.SYNOPSIS
    Tier-2 save helper for Slay the Spire 2 (current_run.save).

.DESCRIPTION
    The save is plain pretty-printed JSON (schema_version 16) with no checksum
    or encryption, so this just loads it, applies the edits you ask for, and
    writes it back -- after taking a timestamped backup.

    EDITS apply to players[0] (the single-player run) unless you pass -PlayerIndex.

.EXAMPLE
    # Just look -- no changes written
    .\Edit-StS2Save.ps1

.EXAMPLE
    .\Edit-StS2Save.ps1 -Gold 999 -Heal

.EXAMPLE
    .\Edit-StS2Save.ps1 -MaxHp 120 -AddRelic RELIC.AKABEKO,RELIC.PEAR -AddPotion POTION.ENERGY_POTION

.NOTES
    *** Steam Cloud ***  This folder is Cloud-synced. Quit the game (ideally
    set Steam offline, or disable Cloud sync for StS2) BEFORE editing, or the
    cloud copy can overwrite your change / trigger a sync conflict.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $SavePath,             # optional; auto-detected from Steam if omitted
    [int]      $PlayerIndex = 0,

    [Nullable[int]] $Gold,
    [Nullable[int]] $CurrentHp,
    [Nullable[int]] $MaxHp,
    [switch]   $Heal,                 # set current_hp = max_hp (after any -MaxHp change)
    [Nullable[int]] $Ascension,       # top-level field

    [string[]] $AddRelic  = @(),      # e.g. RELIC.AKABEKO
    [string[]] $AddPotion = @(),      # e.g. POTION.ENERGY_POTION

    [switch]   $NoBackup
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'StS2Common.ps1')

function Write-Note($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host $msg -ForegroundColor Yellow }

# --- sanity ---------------------------------------------------------------
if (-not $SavePath) { $SavePath = Find-Sts2Save }
if (-not $SavePath -or -not (Test-Path -LiteralPath $SavePath)) {
    throw "No active run (current_run.save) found. Start a run in StS2, or pass -SavePath explicitly."
}

# Warn if the game looks like it's running (avoids Cloud clobber).
$running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'spire' -or $_.MainWindowTitle -match 'Spire' }
if ($running) {
    Write-Warn "!! Slay the Spire appears to be running. Quit it before editing or Steam Cloud may overwrite your change."
    Write-Warn "   (processes: $($running.ProcessName -join ', '))"
}

# --- load -----------------------------------------------------------------
$raw  = Get-Content -LiteralPath $SavePath -Raw -Encoding UTF8
$save = $raw | ConvertFrom-Json   # PSCustomObject, preserves property order

if ($PlayerIndex -ge $save.players.Count) {
    throw "PlayerIndex $PlayerIndex out of range (run has $($save.players.Count) player(s))."
}
$p = $save.players[$PlayerIndex]

# --- current summary ------------------------------------------------------
Write-Note "`n=== current_run.save ==="
Write-Host ("character : {0}" -f $p.character_id)
Write-Host ("ascension : {0}" -f $save.ascension)
Write-Host ("gold      : {0}" -f $p.gold)
Write-Host ("hp        : {0} / {1}" -f $p.current_hp, $p.max_hp)
Write-Host ("deck      : {0} cards" -f $p.deck.Count)
Write-Host ("relics    : {0}" -f $p.relics.Count)
Write-Host ("potions   : {0} / {1}" -f $p.potions.Count, $p.max_potion_slot_count)

# Did the user actually ask for any edit?
$wantsEdit = $PSBoundParameters.ContainsKey('Gold') -or
             $PSBoundParameters.ContainsKey('CurrentHp') -or
             $PSBoundParameters.ContainsKey('MaxHp') -or
             $PSBoundParameters.ContainsKey('Ascension') -or
             $Heal -or $AddRelic.Count -or $AddPotion.Count

if (-not $wantsEdit) {
    Write-Note "`nNo edit flags passed -- view only. Run with -? for examples."
    return
}

# --- apply edits ----------------------------------------------------------
$changes = @()

if ($PSBoundParameters.ContainsKey('Gold'))      { $changes += "gold $($p.gold) -> $Gold";            $p.gold       = [int]$Gold }
if ($PSBoundParameters.ContainsKey('MaxHp'))     { $changes += "max_hp $($p.max_hp) -> $MaxHp";       $p.max_hp     = [int]$MaxHp }
if ($PSBoundParameters.ContainsKey('CurrentHp')) { $changes += "current_hp $($p.current_hp) -> $CurrentHp"; $p.current_hp = [int]$CurrentHp }
if ($Heal)                                       { $changes += "heal: current_hp -> $($p.max_hp)";     $p.current_hp = [int]$p.max_hp }
if ($PSBoundParameters.ContainsKey('Ascension')){ $changes += "ascension $($save.ascension) -> $Ascension"; $save.ascension = [int]$Ascension }

# floor to stamp new items with: highest floor seen in the deck (cosmetic/stats field)
$floor = ($p.deck | ForEach-Object { [int]$_.floor_added_to_deck } | Measure-Object -Maximum).Maximum
if (-not $floor) { $floor = 1 }

foreach ($r in $AddRelic) {
    $id = if ($r -like 'RELIC.*') { $r } else { "RELIC.$($r.ToUpper())" }
    $p.relics += [pscustomobject][ordered]@{ floor_added_to_deck = $floor; id = $id }
    $changes += "add relic $id"
}

if ($AddPotion.Count) {
    $used = @($p.potions | ForEach-Object { [int]$_.slot_index })
    foreach ($pot in $AddPotion) {
        $id = if ($pot -like 'POTION.*') { $pot } else { "POTION.$($pot.ToUpper())" }
        # next free slot within the player's potion belt
        $slot = 0; while ($used -contains $slot) { $slot++ }
        if ($slot -ge $p.max_potion_slot_count) {
            Write-Warn "  (potion belt full -- adding $id at slot $slot anyway; in-game it may not show)"
        }
        $used += $slot
        $p.potions += [pscustomobject][ordered]@{ id = $id; slot_index = $slot }
        $changes += "add potion $id (slot $slot)"
    }
}

Write-Note "`nPlanned changes:"
$changes | ForEach-Object { Write-Host "  - $_" }

if (-not $PSCmdlet.ShouldProcess($SavePath, "write edited save")) { return }

# --- backup ---------------------------------------------------------------
if (-not $NoBackup) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bdir   = Join-Path $PSScriptRoot 'backups'
    if (-not (Test-Path $bdir)) { New-Item -ItemType Directory -Path $bdir | Out-Null }
    $bpath  = Join-Path $bdir "current_run.$stamp.save"
    Copy-Item -LiteralPath $SavePath -Destination $bpath
    Write-Note "Backup -> $bpath"
}

# --- write ----------------------------------------------------------------
# Depth must be high: the save nests ~10 levels deep.
$json = $save | ConvertTo-Json -Depth 100
# ConvertTo-Json emits UTF-8; write without BOM to match the original.
[System.IO.File]::WriteAllText($SavePath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Note "Saved. Re-launch the game to see the changes."
