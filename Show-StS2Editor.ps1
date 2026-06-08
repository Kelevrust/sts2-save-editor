<#
.SYNOPSIS
    One-screen WinForms editor for a Slay the Spire 2 current_run.save.
.DESCRIPTION
    The VB6-flashback window: gold / HP / ascension boxes plus add-remove lists
    for relics and potions. Backs up before every save (backups\ folder), writes
    UTF-8 no-BOM JSON, warns if the game is running (Steam Cloud will clobber).

    Launch under Windows PowerShell (STA) for a reliable window:
        powershell.exe -NoProfile -STA -File Show-StS2Editor.ps1
    The save and game .pck are auto-detected from Steam; pass -SavePath to override.
#>
param(
    [string] $SavePath   # optional; auto-detected from Steam if omitted
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'StS2Common.ps1')

# ---- crash capture -------------------------------------------------------
# Global net for the PS 5.1 click-only crashes the parse/AST tests can't reach:
# event-handler exceptions are dispatched by the WinForms message loop, so one
# ThreadException registration catches them all. Logs next to the editor and
# shows a copyable dialog; the app keeps running so the user can report + retry.
$script:CrashLog = Join-Path $PSScriptRoot 'crash-log.txt'

function Build-CrashReport($err, $context) {
    $ex    = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { $err }
    $msg   = if ($ex) { $ex.Message } else { "$err" }
    $type  = if ($ex) { $ex.GetType().FullName } else { 'unknown' }
    $stack = if (($err -is [System.Management.Automation.ErrorRecord]) -and $err.ScriptStackTrace) { $err.ScriptStackTrace } elseif ($ex -and $ex.StackTrace) { $ex.StackTrace } else { '(no stack)' }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    return @"
==== StS2 Save Editor crash ====
Time     : $stamp
Version  : $STS2_TOOL_VERSION
Context  : $context
PSVersion: $($PSVersionTable.PSVersion)
OS       : $([System.Environment]::OSVersion.VersionString)
Type     : $type
Message  : $msg
Stack    :
$stack
================================
"@
}

function Show-CrashDialog($report) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "StS2 Save Editor - something went wrong"
    $dlg.Size = New-Object System.Drawing.Size(580, 440); $dlg.StartPosition = 'CenterScreen'
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline=$true; $tb.ReadOnly=$true; $tb.ScrollBars='Both'; $tb.WordWrap=$false; $tb.Dock='Fill'
    $tb.Font = New-Object System.Drawing.Font("Consolas", 9)
    $tb.Text = ($report -replace "`n","`r`n")
    $bar = New-Object System.Windows.Forms.Panel; $bar.Dock='Bottom'; $bar.Height=66
    $lbl = New-Object System.Windows.Forms.Label; $lbl.SetBounds(8,6,560,20)
    $lbl.Text = "Saved to: $script:CrashLog   -   please copy this and report it."
    $bCopy = New-Object System.Windows.Forms.Button; $bCopy.Text='Copy to clipboard'; $bCopy.SetBounds(8,32,150,26)
    $bOk   = New-Object System.Windows.Forms.Button; $bOk.Text='Close';             $bOk.SetBounds(164,32,90,26)
    $bCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($tb.Text); $lbl.Text = "Copied to clipboard.  ($script:CrashLog)" })
    $bOk.Add_Click({ $dlg.Close() })
    $bar.Controls.AddRange(@($lbl,$bCopy,$bOk))
    $dlg.Controls.Add($tb); $dlg.Controls.Add($bar)
    [void]$dlg.ShowDialog()
}

function Write-CrashLog($err, $context, [switch]$Quiet) {
    $report = $null
    try {
        $report = Build-CrashReport $err $context
        [System.IO.File]::AppendAllText($script:CrashLog, $report + "`r`n`r`n", [System.Text.UTF8Encoding]::new($false))
    } catch {
        if (-not $report) { $report = "StS2 crash (report build failed): $err" }
    }
    if ($Quiet) { return }
    try { Show-CrashDialog $report }
    catch { try { [System.Windows.Forms.MessageBox]::Show("$report", "StS2 crash") | Out-Null } catch {} }
}

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-CrashLog $e.Exception 'UI event' })
[System.AppDomain]::CurrentDomain.add_UnhandledException({ param($s, $e) Write-CrashLog $e.ExceptionObject 'fatal/non-UI' -Quiet })

# ---- last-writer detection ----------------------------------------------
# Stamp the SHA we wrote on each save, so on a later load we can tell whether
# the save still holds the user's edit - and if not, pin who clobbered it
# (Steam Cloud restoring the server copy is the usual culprit). Stamps live in
# the editor folder, keyed by save path.
$script:EditStampPath = Join-Path $PSScriptRoot '.last-edits.json'

function Save-EditStamp($savePath, $sha) {
    if (-not $savePath -or -not $sha) { return }
    $stamps = @{}
    if (Test-Path -LiteralPath $script:EditStampPath) {
        try {
            $obj = Get-Content -LiteralPath $script:EditStampPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($pr in $obj.PSObject.Properties) { $stamps[$pr.Name] = $pr.Value }
        } catch {}
    }
    $stamps[$savePath.ToLower()] = [pscustomobject]@{ sha = $sha; time = (Get-Date).ToString('o') }
    try { ($stamps | ConvertTo-Json) | Set-Content -LiteralPath $script:EditStampPath -Encoding UTF8 } catch {}
}

function Get-EditStamp($savePath) {
    if (-not $savePath -or -not (Test-Path -LiteralPath $script:EditStampPath)) { return $null }
    try {
        $obj  = Get-Content -LiteralPath $script:EditStampPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $prop = $obj.PSObject.Properties[$savePath.ToLower()]
        if ($prop) { return $prop.Value }
    } catch {}
    return $null
}

# Returns a warning string if the save changed since our last edit, naming the
# likely writer; $null when the edit is intact or we've never saved this file.
function Get-LastWriterWarning {
    if (-not $script:SavePath -or -not (Test-Path -LiteralPath $script:SavePath)) { return $null }
    $stamp = Get-EditStamp $script:SavePath
    if (-not $stamp) { return $null }                    # nothing we wrote to compare against
    $fileSha = Get-Sts2FileSha $script:SavePath
    if (-not $fileSha -or $fileSha -eq $stamp.sha) { return $null }   # edit still intact
    $cloud = Get-Sts2CloudCacheInfo $script:SavePath
    if ($cloud -and $cloud.CachedSha -and ($fileSha -eq $cloud.CachedSha.ToLower())) {
        return "Your last edit was OVERWRITTEN - the save now matches Steam's cloud copy, so Steam Cloud reverted it. Turn Cloud OFF (game Properties AND Steam > Settings > Cloud), then re-edit."
    }
    if (Test-GameRunning) {
        return "This save changed since your last edit and StS2 is running - the game rewrote it. Quit StS2, then edit."
    }
    return "This save changed since your last edit - something rewrote it (a played turn, or Steam Cloud). Re-check before relying on your edits."
}

# ---- shared state --------------------------------------------------------
# Auto-detect the active run save unless one was passed in.
# NOTE: no -Prompt here on purpose - never throw a confusing file dialog at a
# new user. If there's no run, the editor opens in a friendly "no run" state.
if (-not $SavePath) { $SavePath = Find-Sts2Save }
$script:SavePath = $SavePath
$script:save     = $null   # whole deserialized save
$script:p        = $null   # players[0] shortcut
$script:schema   = $null   # this save's schema_version

# Canonical id lists mined from the game's pck (relic/potion atlases).
# NOTE: -Encoding UTF8 is required - Windows PowerShell 5.1 defaults to ANSI,
# which mangles the em-dashes in builds.json into mojibake.
$idsPath = Join-Path $PSScriptRoot 'sts2-ids.json'
$script:ids = if (Test-Path $idsPath) { Get-Content $idsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

# Editable build cheatsheet (shown by the Builds button).
$buildsPath = Join-Path $PSScriptRoot 'builds.json'
$script:builds = if (Test-Path $buildsPath) { Get-Content $buildsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

# "RELIC.AMETHYST_AUBERGINE" -> "Amethyst Aubergine"
function Get-Friendly($id) {
    $name = ($id -split '\.', 2)[-1]
    $words = ($name -split '_') | ForEach-Object {
        if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() } else { $_ }
    }
    return ($words -join ' ')
}

# Build ComboBox items that display the friendly name but carry the raw id.
function New-IdItem($id) {
    $o = New-Object psobject -Property @{ Id = $id; Display = (Get-Friendly $id) }
    $o | Add-Member -MemberType ScriptMethod -Name ToString -Force -Value { $this.Display }
    return $o
}
function Fill-Combo($combo, $ids) {
    $combo.Items.Clear()
    if ($ids) { foreach ($id in $ids) { [void]$combo.Items.Add((New-IdItem $id)) } }
}

# Card combo item: display "Backstab (Silent)" so name-search works, carry raw id.
function New-CardItem($id, $cls) {
    $clsCap = $cls.Substring(0,1).ToUpper() + $cls.Substring(1)
    $o = New-Object psobject -Property @{ Id = $id; Display = "$(Get-Friendly $id) ($clsCap)" }
    $o | Add-Member -MemberType ScriptMethod -Name ToString -Force -Value { $this.Display }
    return $o
}
function Fill-CardCombo($combo, $cardsObj) {
    $combo.Items.Clear()
    if (-not $cardsObj) { return }
    foreach ($cls in $cardsObj.PSObject.Properties) {
        foreach ($id in $cls.Value) { [void]$combo.Items.Add((New-CardItem $id $cls.Name)) }
    }
}

# ---- id-list refresh: re-mine the game's .pck (post-patch) ---------------
function Get-PckPath { Find-Sts2Pck -Prompt }

# Stream the (huge) pck in chunks and pull atlas sprite ids. Pure .NET, no rg.
function Scan-Pck($pck) {
    $relics  = New-Object 'System.Collections.Generic.HashSet[string]'
    $potions = New-Object 'System.Collections.Generic.HashSet[string]'
    $allowed = 'silent','ironclad','defect','regent','necrobinder','colorless','curse','status'
    $cards   = @{}; foreach ($c in $allowed) { $cards[$c] = New-Object 'System.Collections.Generic.HashSet[string]' }

    # One combined pass per chunk: type=relic/potion/card, optional class (cards), name.
    $re  = [regex]'(relic|potion|card)_atlas\.sprites/(?:([a-z_]+)/)?([a-z0-9_]+)\.tres'
    $enc = [System.Text.Encoding]::GetEncoding(28591)   # Latin1: 1 byte -> 1 char

    $fs = [System.IO.File]::OpenRead($pck)
    try {
        $size = 16MB
        $buf  = New-Object byte[] $size
        $tail = ""
        while (($read = $fs.Read($buf, 0, $size)) -gt 0) {
            $chunk = $tail + $enc.GetString($buf, 0, $read)
            foreach ($m in $re.Matches($chunk)) {
                $name = $m.Groups[3].Value.ToUpper()
                switch ($m.Groups[1].Value) {
                    'relic'  { [void]$relics.Add($name) }
                    'potion' { [void]$potions.Add($name) }
                    'card'   { $cls = $m.Groups[2].Value
                               if ($cls -and $cards.ContainsKey($cls)) { [void]$cards[$cls].Add($name) } }
                }
            }
            $tail = if ($chunk.Length -gt 120) { $chunk.Substring($chunk.Length - 120) } else { $chunk }
        }
    } finally { $fs.Dispose() }

    $obj = [ordered]@{
        relics  = @($relics  | Sort-Object | ForEach-Object { "RELIC.$_" })
        potions = @($potions | Sort-Object | ForEach-Object { "POTION.$_" })
        cards   = [ordered]@{}
    }
    foreach ($c in $allowed) { if ($cards[$c].Count) { $obj.cards[$c] = @($cards[$c] | Sort-Object | ForEach-Object { "CARD.$_" }) } }
    return $obj
}

# Resolve whatever the user picked/typed in a combo to a normalized "PREFIX.NAME" id.
function Resolve-ComboId($combo, $prefix) {
    if ($combo.SelectedItem -and ($combo.SelectedItem.PSObject.Properties['Id'])) {
        return $combo.SelectedItem.Id
    }
    $text = "$($combo.Text)".Trim()
    if (-not $text) { return $null }
    foreach ($it in $combo.Items) {                       # typed a friendly name?
        if ($it.Display -ieq $text) { return $it.Id }
    }
    if ($text -like "$prefix.*") { return $text.ToUpper() }   # typed a raw id
    return "$prefix." + ($text.ToUpper() -replace '\s+','_') # typed a bare name
}

function Load-Save {
    if (-not $script:SavePath -or -not (Test-Path -LiteralPath $script:SavePath)) {
        $script:save = $null; $script:p = $null; $script:schema = $null
        return $false   # caller puts the UI into the friendly "no run" state
    }
    $script:save   = (Get-Content -LiteralPath $script:SavePath -Raw -Encoding UTF8) | ConvertFrom-Json
    $script:p      = $script:save.players[0]
    $script:schema = $script:save.schema_version
    return $true
}

function Refresh-Fields {
    $lblChar.Text  = "Character: $($script:p.character_id)   Seed: $($script:save.rng.seed)"
    $tbGold.Text   = "$($script:p.gold)"
    $tbCur.Text    = "$($script:p.current_hp)"
    $tbMax.Text    = "$($script:p.max_hp)"
    $tbAsc.Text    = "$($script:save.ascension)"
    $v = [int64]$script:save.rng.counters.shuffle
    if ($v -lt 0) { $v = 0 } elseif ($v -gt 2147483647) { $v = 2147483647 }
    $nudShuffle.Value = [decimal]$v
    $lstRelics.Items.Clear()
    foreach ($r in $script:p.relics) { $lstRelics.Items.Add($r.id) | Out-Null }
    $lstPotions.Items.Clear()
    foreach ($pot in $script:p.potions) { $lstPotions.Items.Add("$($pot.id) (slot $($pot.slot_index))") | Out-Null }
    $lstDeck.Items.Clear()
    foreach ($c in $script:p.deck) {
        $up = if ($c.current_upgrade_level -gt 0) { "+" } else { "" }
        $lstDeck.Items.Add("$($c.id)$up") | Out-Null
    }
    $lblStatus.Text = "Loaded. deck: $($script:p.deck.Count) cards | relics: $($script:p.relics.Count) | potions: $($script:p.potions.Count)/$($script:p.max_potion_slot_count)"
}

# Enable/disable the run-editing controls and show the right message.
# Builds always works (no run needed); editing only when a run is loaded.
function Set-RunState($hasRun) {
    $editCtrls = @(
        $tbGold,$tbCur,$tbMax,$tbAsc,$btnHeal,$nudShuffle,$btnReshuffle,
        $cbAddRelic,$btnAddRelic,$btnDelRelic,
        $cbAddPotion,$btnAddPotion,$btnDelPotion,
        $cbAddCard,$chkUpg,$btnAddCard,$btnDelCard,
        $btnApply,$btnMap
    )
    foreach ($c in $editCtrls) { $c.Enabled = $hasRun }
    if ($hasRun) {
        Refresh-Fields
    } else {
        $lblChar.Text = "No active run loaded"
        $tbGold.Text=''; $tbCur.Text=''; $tbMax.Text=''; $tbAsc.Text=''
        $lstRelics.Items.Clear(); $lstPotions.Items.Clear(); $lstDeck.Items.Clear()
        $lblStatus.Text = "No run found. Start a run in StS2 (just enter Act 1), then click Reload. You can still browse Builds."
    }
}

# Build the warning banner (game running / schema / multiplayer).
function Set-Warnings {
    $warn = @()
    if (Test-GameRunning) { $warn += "StS2 is running - quit first (Steam Cloud will overwrite)." }
    if ($script:save) {
        if ($script:schema -ne $STS2_KNOWN_SCHEMA) { $warn += "Save schema $($script:schema) != tested $STS2_KNOWN_SCHEMA - edits risky." }
        if ($script:save.players.Count -gt 1) { $warn += "Multiplayer save ($($script:save.players.Count) players) - editing untested." }
        # Steam Cloud is the #1 cause of "my edit reverted on load": if this save is
        # cloud-tracked, Steam can pull the server copy down over your edit at launch.
        $cloud = Get-Sts2CloudCacheInfo $script:SavePath
        if ($cloud) { $warn += "Steam Cloud is tracking this save - turn Cloud OFF (game Properties AND Steam > Settings > Cloud) or edits get overwritten on launch." }
        $lastWriter = Get-LastWriterWarning
        if ($lastWriter) { $warn += $lastWriter }
    }
    $lblWarn.Text = ($warn -join "  |  ")
}

function Test-GameRunning {
    $r = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'spire' }
    return [bool]$r
}

# ---- form ----------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "StS2 Save Editor"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"   # resizable; AutoScroll covers small screens
$form.MaximizeBox = $false
$form.AutoScroll = $true             # scrollbar if the window is shorter than the content
# Fit the screen's WORKING area (excludes the taskbar) so the Apply button is never hidden.
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.ClientSize = New-Object System.Drawing.Size(440, [Math]::Min(840, $wa.Height - 40))
$form.MinimumSize = New-Object System.Drawing.Size(456, 360)

$y = 10
function New-Label($text, $x, $yy, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Left = $x; $l.Top = $yy; $l.Width = $w; $l.AutoSize = $false
    $form.Controls.Add($l); return $l
}
function New-Text($x, $yy, $w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Left = $x; $t.Top = $yy; $t.Width = $w
    $form.Controls.Add($t); return $t
}
function New-Button($text, $x, $yy, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Left = $x; $b.Top = $yy; $b.Width = $w
    $form.Controls.Add($b); return $b
}

# Cloud-warning banner
$lblWarn = New-Label "" 10 $y 410
$lblWarn.ForeColor = [System.Drawing.Color]::Firebrick
$lblWarn.Font = New-Object System.Drawing.Font($lblWarn.Font, [System.Drawing.FontStyle]::Bold)
$y += 22

# Update-available notice (hidden until a newer release is found)
$llUpdate = New-Object System.Windows.Forms.LinkLabel
$llUpdate.Left = 10; $llUpdate.Top = $y; $llUpdate.Width = 410; $llUpdate.Height = 18; $llUpdate.AutoSize = $false
$llUpdate.Visible = $false
$llUpdate.Add_LinkClicked({ Start-Process $STS2_RELEASES_URL })
$form.Controls.Add($llUpdate)
$y += 20

$lblChar = New-Label "" 10 $y 300
$btnRefresh = New-Button "Refresh IDs" 315 ($y-2) 105
$y += 26

New-Label "Gold"          10 ($y+3) 90 | Out-Null
$tbGold = New-Text 100 $y 90
New-Label "Ascension"     210 ($y+3) 70 | Out-Null
$tbAsc  = New-Text 285 $y 60
$y += 30

New-Label "Current HP"    10 ($y+3) 90 | Out-Null
$tbCur  = New-Text 100 $y 90
New-Label "Max HP"        210 ($y+3) 70 | Out-Null
$tbMax  = New-Text 285 $y 60
$btnHeal = New-Button "Full Heal" 355 ($y-1) 65
$btnHeal.Add_Click({ $tbCur.Text = $tbMax.Text })
$y += 30

# Reshuffle: bump the shuffle RNG counter, then relaunch for a fresh draw on that fight.
New-Label "Shuffle" 10 ($y+3) 55 | Out-Null
$nudShuffle = New-Object System.Windows.Forms.NumericUpDown
$nudShuffle.SetBounds(68, $y, 72, 24)
$nudShuffle.Minimum = 0; $nudShuffle.Maximum = [decimal]2147483647; $nudShuffle.Increment = 1
$form.Controls.Add($nudShuffle)
$btnReshuffle = New-Button "Reshuffle" 148 ($y-1) 95
$lblShuf = New-Label "quit game first, then relaunch" 250 ($y+3) 175
$lblShuf.ForeColor = [System.Drawing.Color]::Gray
$y += 34

# Relics
New-Label "Relics" 10 $y 200 | Out-Null
$y += 20
$lstRelics = New-Object System.Windows.Forms.ListBox
$lstRelics.Left = 10; $lstRelics.Top = $y; $lstRelics.Width = 410; $lstRelics.Height = 90
$form.Controls.Add($lstRelics)
$y += 95
$cbAddRelic = New-Object System.Windows.Forms.ComboBox
$cbAddRelic.Left = 10; $cbAddRelic.Top = $y; $cbAddRelic.Width = 250
$cbAddRelic.DropDownStyle = 'DropDown'
$cbAddRelic.Sorted = $true
$cbAddRelic.AutoCompleteMode = 'SuggestAppend'
$cbAddRelic.AutoCompleteSource = 'ListItems'
$cbAddRelic.MaxDropDownItems = 20
$form.Controls.Add($cbAddRelic)
Fill-Combo $cbAddRelic ($script:ids.relics)
$btnAddRelic = New-Button "Add" 265 ($y-1) 70
$btnDelRelic = New-Button "Remove" 340 ($y-1) 80
$y += 36

# Potions
New-Label "Potions" 10 $y 200 | Out-Null
$y += 20
$lstPotions = New-Object System.Windows.Forms.ListBox
$lstPotions.Left = 10; $lstPotions.Top = $y; $lstPotions.Width = 410; $lstPotions.Height = 70
$form.Controls.Add($lstPotions)
$y += 75
$cbAddPotion = New-Object System.Windows.Forms.ComboBox
$cbAddPotion.Left = 10; $cbAddPotion.Top = $y; $cbAddPotion.Width = 250
$cbAddPotion.DropDownStyle = 'DropDown'
$cbAddPotion.Sorted = $true
$cbAddPotion.AutoCompleteMode = 'SuggestAppend'
$cbAddPotion.AutoCompleteSource = 'ListItems'
$cbAddPotion.MaxDropDownItems = 20
$form.Controls.Add($cbAddPotion)
Fill-Combo $cbAddPotion ($script:ids.potions)
$btnAddPotion = New-Button "Add" 265 ($y-1) 70
$btnDelPotion = New-Button "Remove" 340 ($y-1) 80
$y += 40

# Cards (deck)
New-Label "Deck (cards)" 10 $y 200 | Out-Null
$y += 20
$lstDeck = New-Object System.Windows.Forms.ListBox
$lstDeck.Left = 10; $lstDeck.Top = $y; $lstDeck.Width = 410; $lstDeck.Height = 90
$form.Controls.Add($lstDeck)
$y += 95
$cbAddCard = New-Object System.Windows.Forms.ComboBox
$cbAddCard.Left = 10; $cbAddCard.Top = $y; $cbAddCard.Width = 200
$cbAddCard.DropDownStyle = 'DropDown'
$cbAddCard.Sorted = $true
$cbAddCard.AutoCompleteMode = 'SuggestAppend'
$cbAddCard.AutoCompleteSource = 'ListItems'
$cbAddCard.MaxDropDownItems = 20
$form.Controls.Add($cbAddCard)
Fill-CardCombo $cbAddCard ($script:ids.cards)
$chkUpg = New-Object System.Windows.Forms.CheckBox
$chkUpg.Text = "Upg"; $chkUpg.Left = 214; $chkUpg.Top = ($y+2); $chkUpg.Width = 48
$form.Controls.Add($chkUpg)
$btnAddCard = New-Button "Add" 265 ($y-1) 70
$btnDelCard = New-Button "Remove" 340 ($y-1) 80
$y += 40

# Info / utility buttons
$btnMap    = New-Button "Run Map"      10 $y 100
$btnBuilds = New-Button "Builds"      115 $y 62
$btnFind   = New-Button "Find..."     182 $y 62   # opt-in manual locate (auto-detect fallback)
$y += 32

# Action buttons
$btnReload = New-Button "Reload"       10 $y 90
$btnApply  = New-Button "Apply + Save" 110 $y 130
$btnApply.Font = New-Object System.Drawing.Font($btnApply.Font, [System.Drawing.FontStyle]::Bold)
$btnClose  = New-Button "Close"        250 $y 90
$y += 34

$lblStatus = New-Label "" 10 $y 410

# ---- relic / potion handlers --------------------------------------------
$btnAddRelic.Add_Click({
    $id = Resolve-ComboId $cbAddRelic 'RELIC'
    if (-not $id) { $lblStatus.Text = "Pick or type a relic first."; return }
    $floor = ($script:p.deck | ForEach-Object { [int]$_.floor_added_to_deck } | Measure-Object -Maximum).Maximum
    if (-not $floor) { $floor = 1 }
    $obj = New-Object psobject -Property ([ordered]@{ floor_added_to_deck = $floor; id = $id })
    $script:p.relics = @($script:p.relics) + $obj
    $lstRelics.Items.Add($id) | Out-Null
})
$btnDelRelic.Add_Click({
    $i = $lstRelics.SelectedIndex
    if ($i -lt 0) { return }
    $script:p.relics = @($script:p.relics | Where-Object { $true })  # ensure array
    $script:p.relics = @($script:p.relics[0..($script:p.relics.Count-1)] | Select-Object -Index (0..($script:p.relics.Count-1) | Where-Object { $_ -ne $i }))
    $lstRelics.Items.RemoveAt($i)
})
$btnAddPotion.Add_Click({
    $id = Resolve-ComboId $cbAddPotion 'POTION'
    if (-not $id) { $lblStatus.Text = "Pick or type a potion first."; return }
    $used = @($script:p.potions | ForEach-Object { [int]$_.slot_index })
    $slot = 0; while ($used -contains $slot) { $slot++ }
    $obj = New-Object psobject -Property ([ordered]@{ id = $id; slot_index = $slot })
    $script:p.potions = @($script:p.potions) + $obj
    $lstPotions.Items.Add("$id (slot $slot)") | Out-Null
})
$btnDelPotion.Add_Click({
    $i = $lstPotions.SelectedIndex
    if ($i -lt 0) { return }
    $keep = 0..($script:p.potions.Count-1) | Where-Object { $_ -ne $i }
    $script:p.potions = @($script:p.potions | Select-Object -Index $keep)
    $lstPotions.Items.RemoveAt($i)
})

# ---- card handlers ------------------------------------------------------
$btnAddCard.Add_Click({
    $id = Resolve-ComboId $cbAddCard 'CARD'
    if (-not $id) { $lblStatus.Text = "Pick or type a card first."; return }
    $floor = ($script:p.deck | ForEach-Object { [int]$_.floor_added_to_deck } | Measure-Object -Maximum).Maximum
    if (-not $floor) { $floor = 1 }
    $props = [ordered]@{ floor_added_to_deck = $floor; id = $id }
    if ($chkUpg.Checked) { $props = [ordered]@{ current_upgrade_level = 1; floor_added_to_deck = $floor; id = $id } }
    $script:p.deck = @($script:p.deck) + (New-Object psobject -Property $props)
    $up = if ($chkUpg.Checked) { "+" } else { "" }
    $lstDeck.Items.Add("$id$up") | Out-Null
})
$btnDelCard.Add_Click({
    $i = $lstDeck.SelectedIndex
    if ($i -lt 0) { return }
    $keep = 0..($script:p.deck.Count-1) | Where-Object { $_ -ne $i }
    $script:p.deck = @($script:p.deck | Select-Object -Index $keep)
    $lstDeck.Items.RemoveAt($i)
})

# ---- refresh ids from the game's pck -----------------------------------
$btnRefresh.Add_Click({
    $pck = Get-PckPath
    if (-not $pck) { $lblStatus.Text = "Refresh cancelled (no .pck)."; return }
    $btnRefresh.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $lblStatus.Text = "Scanning $([System.IO.Path]::GetFileName($pck)) (1-2 min, window will be busy)..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $obj = Scan-Pck $pck
        $json = $obj | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($idsPath, $json, [System.Text.UTF8Encoding]::new($false))
        $script:ids = $obj
        Fill-Combo     $cbAddRelic  $script:ids.relics
        Fill-Combo     $cbAddPotion $script:ids.potions
        Fill-CardCombo $cbAddCard   $script:ids.cards
        $cardTotal = ($script:ids.cards.PSObject.Properties | ForEach-Object { $_.Value.Count } | Measure-Object -Sum).Sum
        $lblStatus.Text = "IDs refreshed: $($script:ids.relics.Count) relics, $($script:ids.potions.Count) potions, $cardTotal cards."
    } catch {
        $lblStatus.Text = "Refresh failed: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnRefresh.Enabled = $true
    }
})

# ---- builds cheatsheet (anchored, non-modal drawer) --------------------
$script:buildsWin = $null
$script:mapWin    = $null   # non-modal Run Map window (single instance, like Builds)

# Render one archetype (build): quick-glance lists on top, the play below.
function Format-Archetype($a) {
    if (-not $a) { return "" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($a.name)
    [void]$sb.AppendLine(("=" * 46))
    # --- fast reference first ---
    if ($a.cards  -and $a.cards.Count) {
        [void]$sb.AppendLine("KEY CARDS")
        foreach ($x in $a.cards)  { [void]$sb.AppendLine("  - $(($x -split (' ' + [char]0x2014 + ' '),2)[0])") }   # name only, drop the effect tail
        [void]$sb.AppendLine("")
    }
    if ($a.relics -and $a.relics.Count) {
        [void]$sb.AppendLine("KEY RELICS")
        foreach ($x in $a.relics) { [void]$sb.AppendLine("  - $(($x -split (' ' + [char]0x2014 + ' '),2)[0])") }
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine(("-" * 46))
    # --- the play / breakdown below ---
    [void]$sb.AppendLine("THE PLAY")
    [void]$sb.AppendLine($a.summary)
    if ($a.cards  -and $a.cards.Count) { [void]$sb.AppendLine(""); [void]$sb.AppendLine("CARDS IN DETAIL");  foreach ($x in $a.cards)  { [void]$sb.AppendLine("  - $x") } }
    if ($a.relics -and $a.relics.Count){ [void]$sb.AppendLine(""); [void]$sb.AppendLine("RELICS IN DETAIL"); foreach ($x in $a.relics) { [void]$sb.AppendLine("  - $x") } }
    if ($a.combos -and $a.combos.Count){ [void]$sb.AppendLine(""); [void]$sb.AppendLine("COMBOS");           foreach ($x in $a.combos) { [void]$sb.AppendLine("  - $x") } }
    if ($a.pitfalls)                   { [void]$sb.AppendLine(""); [void]$sb.AppendLine("WATCH OUT"); [void]$sb.AppendLine("  $($a.pitfalls)") }
    return $sb.ToString()
}

# Keep the drawers pinned to the editor: Builds on the right, Run Map on the
# left, both matching the editor's height so they read as attached panels.
function Set-DrawerPosition {
    if ($script:buildsWin -and -not $script:buildsWin.IsDisposed) {
        $script:buildsWin.Location = New-Object System.Drawing.Point(($form.Location.X + $form.Width), $form.Location.Y)
        $script:buildsWin.Height   = $form.Height
    }
    if ($script:mapWin -and -not $script:mapWin.IsDisposed) {
        $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        $x  = $form.Location.X - $script:mapWin.Width
        if ($x -lt $wa.Left) { $x = $wa.Left }   # keep on-screen if editor hugs the left edge
        $script:mapWin.Location = New-Object System.Drawing.Point($x, $form.Location.Y)
        $script:mapWin.Height   = $form.Height
    }
}
$form.Add_Move({   Set-DrawerPosition })
$form.Add_Resize({ Set-DrawerPosition })

$btnBuilds.Add_Click({
    if (-not $script:builds) { $lblStatus.Text = "builds.json not found."; return }
    if ($script:buildsWin -and -not $script:buildsWin.IsDisposed) { $script:buildsWin.Activate(); return }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Build Cheatsheet"
    $dlg.FormBorderStyle = 'SizableToolWindow'
    $dlg.StartPosition = 'Manual'
    $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(464, 600)

    # NOTE: script-scoped so the SelectedIndexChanged handlers still resolve them
    # after this (non-modal) click handler returns and its locals are gone.
    $A = [System.Windows.Forms.AnchorStyles]
    $script:dChar  = New-Object System.Windows.Forms.ComboBox
    $script:dChar.SetBounds(8, 8, 448, 24);  $script:dChar.DropDownStyle = 'DropDownList'
    $script:dChar.Anchor  = $A::Top -bor $A::Left -bor $A::Right
    $script:dBuild = New-Object System.Windows.Forms.ComboBox
    $script:dBuild.SetBounds(8, 38, 448, 24); $script:dBuild.DropDownStyle = 'DropDownList'
    $script:dBuild.Anchor = $A::Top -bor $A::Left -bor $A::Right
    $script:dText = New-Object System.Windows.Forms.TextBox
    $script:dText.SetBounds(8, 70, 448, 522)
    $script:dText.Multiline=$true; $script:dText.ReadOnly=$true; $script:dText.ScrollBars='Vertical'; $script:dText.WordWrap=$true
    $script:dText.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:dText.Anchor = $A::Top -bor $A::Bottom -bor $A::Left -bor $A::Right

    foreach ($prop in $script:builds.PSObject.Properties) {
        if ($prop.Name -like 'CHARACTER.*') {
            $it = New-Object psobject -Property @{ Key = $prop.Name; Display = $prop.Value.name }
            $it | Add-Member -MemberType ScriptMethod -Name ToString -Force -Value { $this.Display }
            [void]$script:dChar.Items.Add($it)
        }
    }

    # build dropdown renders the chosen archetype
    $script:dBuild.Add_SelectedIndexChanged({
        $i = $script:dBuild.SelectedIndex
        if ($i -lt 0 -or -not $script:dChar.SelectedItem) { return }
        $arche = $script:builds.($script:dChar.SelectedItem.Key).archetypes
        if ($arche -and $i -lt $arche.Count) { $script:dText.Text = (Format-Archetype $arche[$i]) -replace "`n","`r`n" }
    })

    # class dropdown drives the build dropdown (dynamic)
    $script:dChar.Add_SelectedIndexChanged({
        $arche = $script:builds.($script:dChar.SelectedItem.Key).archetypes
        $script:dBuild.Items.Clear()
        if ($arche -and $arche.Count) {
            foreach ($a in $arche) { [void]$script:dBuild.Items.Add($a.name) }
            $script:dBuild.Enabled = $true
            $script:dBuild.SelectedIndex = 0     # triggers the render above
        } else {
            $script:dBuild.Enabled = $false
            $script:dText.Text = "(Coming soon - this class isn't written up yet.)"
        }
    })

    $dlg.Controls.AddRange(@($script:dChar, $script:dBuild, $script:dText))
    $script:buildsWin = $dlg
    $dlg.Add_FormClosed({ $script:buildsWin = $null })

    # default to the current run's character
    $want = if ($script:p) { $script:p.character_id } else { $null }
    $idx = 0
    for ($i = 0; $i -lt $script:dChar.Items.Count; $i++) { if ($script:dChar.Items[$i].Key -eq $want) { $idx = $i; break } }

    Set-DrawerPosition
    $dlg.Show($form)          # non-modal: editor stays usable
    Set-DrawerPosition
    if ($script:dChar.Items.Count) { $script:dChar.SelectedIndex = $idx }
})

# ---- upcoming queues (what's in the RNG pools per act) ------------------
function Format-WhatAhead($save) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("WHAT YOU'LL DRAW   (the map sets room types; these pools are drawn in this order as you enter rooms)")
    [void]$sb.AppendLine("")
    $ai = [int]$save.current_act_index
    $cats = @(
        @('normal_encounter_ids','normal_encounters_visited','Fights'),
        @('elite_encounter_ids','elite_encounters_visited','Elites'),
        @('event_ids','events_visited','Events'))
    for ($k = $ai; $k -lt $save.acts.Count; $k++) {
        $act = $save.acts[$k]; $r = $act.rooms
        $tag = if ($k -eq $ai) { " (current)" } else { "" }
        [void]$sb.AppendLine("=== $($act.id)$tag ===")
        # Likely-next summary: the very next draw from each pool (current act = honors progress).
        [void]$sb.AppendLine("  Likely next:")
        foreach ($cat in $cats) {
            $ids = $r.($cat[0]); $v = if ($k -eq $ai) { [int]$r.($cat[1]) } else { 0 }
            $nxt = @($ids | Select-Object -Skip $v | Select-Object -First 1)
            $name = if ($nxt.Count) { Clean-ModelId $nxt[0] '' } else { '(none left)' }
            [void]$sb.AppendLine(("     {0,-7} {1}" -f ($cat[2] + ':'), $name))
        }
        [void]$sb.AppendLine("")
        # Full draw order for each pool.
        foreach ($cat in $cats) {
            $ids = $r.($cat[0]); $v = if ($k -eq $ai) { [int]$r.($cat[1]) } else { 0 }
            $upcoming = @($ids | Select-Object -Skip $v | Select-Object -First 8)
            [void]$sb.AppendLine("  $($cat[2]) (draw order):")
            foreach ($x in $upcoming) { [void]$sb.AppendLine("     " + (Clean-ModelId $x '')) }
        }
        [void]$sb.AppendLine("  BOSS: " + (Clean-ModelId $r.boss_id ''))
        [void]$sb.AppendLine("")
    }
    return $sb.ToString()
}

# ---- run map (ASCII + Mermaid export) -----------------------------------
$Global:STS2_SYM = @{ monster='M'; elite='E'; event='?'; ancient='N'; shop='$'; rest_site='R'; treasure='T'; boss='B' }
function Get-NodeRt($n) { if ($n.rooms) { $n.rooms.room_type } else { $n.map_point_type } }
function Clean-ModelId($mid, $rt) {
    if (-not $mid) { return (Get-Culture).TextInfo.ToTitleCase(($rt -replace '_',' ')) }
    $core = ($mid -split '\.',2)[-1]; $tier = ''
    if ($core -match '_(WEAK|NORMAL|ELITE|BOSS)$') { $tier = $matches[1].ToLower(); $core = $core -replace '_(WEAK|NORMAL|ELITE|BOSS)$','' }
    $name = (Get-Culture).TextInfo.ToTitleCase(($core -replace '_',' ').ToLower())
    if ($tier -and $tier -ne 'normal') { $name = "$name ($tier)" }
    return $name
}
function Format-RunMap($save) {
    $sb = New-Object System.Text.StringBuilder
    $char = $save.players[0].character_id -replace '^CHARACTER\.',''
    [void]$sb.AppendLine("RUN MAP  -  $char  -  Seed $($save.rng.seed)  -  Ascension $($save.ascension)")
    [void]$sb.AppendLine(('=' * 52))
    $acts = $save.map_point_history; $lastA = $acts.Count - 1
    for ($a=0; $a -lt $acts.Count; $a++) {
        [void]$sb.AppendLine(""); [void]$sb.AppendLine("ACT $($a+1)")
        $nodes = $acts[$a]; $lastN = $nodes.Count - 1
        for ($i=0; $i -lt $nodes.Count; $i++) {
            $n = $nodes[$i]; $rt = Get-NodeRt $n
            $s = if ($STS2_SYM.ContainsKey($rt)) { $STS2_SYM[$rt] } else { '.' }
            $name = Clean-ModelId ($n.rooms.model_id) $rt
            $mark = if ($a -eq $lastA -and $i -eq $lastN) { '   <= latest' } else { '' }
            [void]$sb.AppendLine(("  {0,2}  [{1}] {2,-26} hp {3}{4}" -f ($i+1),$s,$name,$n.player_stats.current_hp,$mark))
        }
    }
    [void]$sb.AppendLine(""); [void]$sb.AppendLine("[M]onster [E]lite [?]event [`$]shop [R]est [T]reasure [B]oss [N]eow")
    return $sb.ToString()
}
function Format-RunMapMermaid($save) {
    $cls = @{ monster='monster'; elite='elite'; event='event'; ancient='event'; shop='shop'; rest_site='rest'; treasure='treasure'; boss='boss' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('graph TD')
    foreach ($d in @('boss fill:#c0392b,color:#fff','elite fill:#e67e22,color:#fff','monster fill:#7f8c8d,color:#fff','event fill:#2980b9,color:#fff','shop fill:#27ae60,color:#fff','rest fill:#8e44ad,color:#fff','treasure fill:#f1c40f,color:#000')) {
        [void]$sb.AppendLine("  classDef $d;")
    }
    $prev = $null; $acts = $save.map_point_history
    for ($a=0; $a -lt $acts.Count; $a++) {
        $nodes = $acts[$a]
        for ($i=0; $i -lt $nodes.Count; $i++) {
            $n = $nodes[$i]; $rt = Get-NodeRt $n; $id = "a$($a+1)f$($i+1)"
            $name = (Clean-ModelId ($n.rooms.model_id) $rt) -replace '"',''
            [void]$sb.AppendLine("  $id[`"A$($a+1).$($i+1) $name (hp $($n.player_stats.current_hp))`"]")
            $c = if ($cls.ContainsKey($rt)) { $cls[$rt] } else { 'monster' }
            [void]$sb.AppendLine("  class $id $c;")
            if ($prev) { [void]$sb.AppendLine("  $prev --> $id") }
            $prev = $id
        }
    }
    return $sb.ToString()
}
# Branching ASCII map of the current act (from saved_map), boss at top, path solid.
function Format-RunMapGraph($save) {
    $ai = [int]$save.current_act_index
    $sm = $save.acts[$ai].saved_map
    if (-not $sm -or -not $sm.points) { return "(no map data for this act)" }
    $sym = @{ monster='M'; unknown='?'; rest_site='R'; elite='E'; shop='$'; treasure='T'; boss='B' }
    $grid = @{}; foreach ($n in $sm.points) { $grid["$($n.coord.col),$($n.coord.row)"] = $n }
    if ($sm.boss) { $grid["$($sm.boss.coord.col),$($sm.boss.coord.row)"] = $sm.boss }
    $vis = @{}; foreach ($v in $save.visited_map_coords) { $vis["$($v.col),$($v.row)"] = $true }
    $lastV = if ($save.visited_map_coords.Count) { $save.visited_map_coords[-1] } else { $null }
    $w = [int]$sm.width; $maxr = 0
    foreach ($k in $grid.Keys) { $rr = [int]((("$k") -split ',')[1]); if ($rr -gt $maxr) { $maxr = $rr } }
    $body = @()
    for ($r=0; $r -le $maxr; $r++) {
        $line = (' ' * ($w*4)).ToCharArray()
        for ($c=0; $c -lt $w; $c++) {
            $n = $grid["$c,$r"]; if (-not $n) { continue }
            $t = $sym[$n.type]; if (-not $t) { $t = '.' }
            $lb='['; $rb=']'
            if ($vis["$c,$r"]) { $lb='('; $rb=')' }
            if ($lastV -and $lastV.col -eq $c -and $lastV.row -eq $r) { $lb='*'; $rb='*' }
            $b = $c*4; $line[$b]=[char]$lb; $line[$b+1]=[char]$t; $line[$b+2]=[char]$rb
        }
        $body += ("{0,2} " -f $r) + (-join $line)
        if ($r -lt $maxr) {
            $cl = (' ' * ($w*4)).ToCharArray()
            for ($c=0; $c -lt $w; $c++) {
                $n = $grid["$c,$r"]; if (-not $n) { continue }
                foreach ($ch in $n.children) {
                    $cc = [int]$ch.col; $dc = $cc - $c; $b = $c*4
                    if     ($dc -eq 0) { $cl[$b+1]=[char]'|' }
                    elseif ($dc -gt 0) { $cl[$b+3]=[char]'\' }
                    else               { if ($b-1 -ge 0) { $cl[$b-1]=[char]'/' } }
                }
            }
            $body += "   " + (-join $cl)
        }
    }
    [array]::Reverse($body)   # boss at top
    $flip = $body | ForEach-Object { (($_ -replace '/',[char]1) -replace '\\','/') -replace ([char]1),'\' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("MAP - $($save.acts[$ai].id)    ( )=visited  *=you are here  / \ |=branches")
    [void]$sb.AppendLine("")
    $flip | ForEach-Object { [void]$sb.AppendLine($_) }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("M enemy  E elite  ? unknown  `$ merchant  R rest  T treasure  B boss")
    return $sb.ToString()
}
# Mermaid of the current act graph (bottom-to-top), visited nodes outlined.
function Format-RunMapGraphMermaid($save) {
    $ai = [int]$save.current_act_index; $sm = $save.acts[$ai].saved_map
    if (-not $sm -or -not $sm.points) { return "graph BT`n  x[No map data]" }
    $cls = @{ monster='enemy'; unknown='unknown'; rest_site='rest'; elite='elite'; shop='merchant'; treasure='treasure'; boss='boss' }
    $vis = @{}; foreach ($v in $save.visited_map_coords) { $vis["$($v.col),$($v.row)"] = $true }
    $nodes = @($sm.points); if ($sm.boss) { $nodes += $sm.boss }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('graph BT')
    foreach ($d in @('enemy fill:#9aa,color:#000','elite fill:#8e44ad,color:#fff','unknown fill:#b7950b,color:#fff','rest fill:#c0392b,color:#fff','merchant fill:#27ae60,color:#fff','treasure fill:#7f8c8d,color:#fff','boss fill:#111,color:#fff','visited stroke:#000,stroke-width:4px')) { [void]$sb.AppendLine("  classDef $d;") }
    foreach ($n in $nodes) {
        $id = "n$($n.coord.col)_$($n.coord.row)"
        $k = $cls[$n.type]; if (-not $k) { $k = 'unknown' }
        $lbl = $k.Substring(0,1).ToUpper() + $k.Substring(1)
        [void]$sb.AppendLine("  $id([`"$lbl`"])")
        $klass = $k; if ($vis["$($n.coord.col),$($n.coord.row)"]) { $klass = "$k,visited" }
        [void]$sb.AppendLine("  class $id $klass;")
    }
    foreach ($n in $nodes) {
        $id = "n$($n.coord.col)_$($n.coord.row)"
        foreach ($ch in $n.children) { [void]$sb.AppendLine("  $id --> n$($ch.col)_$($ch.row)") }
    }
    return $sb.ToString()
}
$btnMap.Add_Click({
    if (-not $script:save) { $lblStatus.Text = "No run loaded."; return }
    # Regenerate from the current save every open (so edits/progress show).
    $div   = "`r`n" + ('-' * 52) + "`r`n`r`n"
    $ascii = (Format-RunMapGraph $script:save) + $div + (Format-WhatAhead $script:save) + $div + (Format-RunMap $script:save)
    $script:mapMermaid = Format-RunMapGraphMermaid $script:save

    # Already open? Refresh its contents and bring it forward (matches Builds).
    if ($script:mapWin -and -not $script:mapWin.IsDisposed) {
        $script:mapTb.Text = ($ascii -replace "`n","`r`n")
        $script:mapLbl.Text = ""
        $script:mapWin.Activate()
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Run Map  (seed $($script:save.rng.seed))"
    $dlg.Size = New-Object System.Drawing.Size(520, 660); $dlg.StartPosition = "Manual"
    $dlg.FormBorderStyle = 'SizableToolWindow'
    $dlg.ShowInTaskbar = $false
    # script-scoped so the toolbar handlers still resolve them after this
    # (non-modal) click handler returns and its locals are gone.
    $script:mapTb = New-Object System.Windows.Forms.TextBox
    $script:mapTb.Multiline=$true; $script:mapTb.ReadOnly=$true; $script:mapTb.ScrollBars='Vertical'; $script:mapTb.Dock='Fill'
    $script:mapTb.Font = New-Object System.Drawing.Font("Consolas", 9); $script:mapTb.Text = ($ascii -replace "`n","`r`n")
    $bar = New-Object System.Windows.Forms.Panel; $bar.Dock='Bottom'; $bar.Height=40
    $bExp  = New-Object System.Windows.Forms.Button; $bExp.Text='Export .md';        $bExp.SetBounds(8,8,100,26)
    $bLink = New-Object System.Windows.Forms.Button; $bLink.Text='Copy render link';  $bLink.SetBounds(114,8,130,26)
    $script:mapLbl = New-Object System.Windows.Forms.Label; $script:mapLbl.SetBounds(250,12,250,22)
    $bExp.Add_Click({
        $fence = [string][char]96 * 3
        $md = "# StS2 Run Map`r`n`r`nPaste the block below at https://kelevrust.github.io/sts2-save-editor/map.html (or https://mermaid.live) to view/download it.`r`n`r`n${fence}mermaid`r`n$($script:mapMermaid)`r`n${fence}`r`n"
        $p = Join-Path ([Environment]::GetFolderPath('Desktop')) 'StS2-run-map.md'
        [System.IO.File]::WriteAllText($p, $md, [System.Text.UTF8Encoding]::new($false))
        $script:mapLbl.Text = "Saved -> Desktop\StS2-run-map.md"
    })
    $bLink.Add_Click({
        $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:mapMermaid)) -replace '\+','-' -replace '/','_' -replace '=',''
        [System.Windows.Forms.Clipboard]::SetText("https://kelevrust.github.io/sts2-save-editor/map.html#m=$b")
        $script:mapLbl.Text = "Render link copied to clipboard"
    })
    $bar.Controls.AddRange(@($bExp,$bLink,$script:mapLbl))
    $dlg.Controls.Add($script:mapTb); $dlg.Controls.Add($bar)
    $script:mapWin = $dlg
    $dlg.Add_FormClosed({ $script:mapWin = $null })
    Set-DrawerPosition
    $dlg.Show($form)          # non-modal: editor stays usable (like Builds)
    Set-DrawerPosition        # re-pin: some props settle only after Show
})

# ---- reload / find / apply / close --------------------------------------
$btnReload.Add_Click({
    $script:SavePath = Find-Sts2Save     # re-detect: picks up a run you just started
    $found = Load-Save
    Set-RunState $found
    Set-Warnings
    if (-not $found) { $lblStatus.Text = "Still no run found. Start one in StS2 (enter Act 1), then click Reload again." }
})
$btnFind.Add_Click({
    # opt-in manual locate, for the rare case auto-detect misses the save
    $picked = Find-Sts2Save -Prompt
    if (-not $picked -or -not (Test-Path -LiteralPath $picked)) { return }  # cancelled
    $script:SavePath = $picked
    $found = Load-Save
    Set-RunState $found
    Set-Warnings
})
$btnClose.Add_Click({ $form.Close() })

$btnApply.Add_Click({
    # validate numerics
    $g=0;$c=0;$m=0;$a=0
    if (-not [int]::TryParse($tbGold.Text,[ref]$g)) { $lblStatus.Text="Gold must be a number."; return }
    if (-not [int]::TryParse($tbCur.Text,[ref]$c))  { $lblStatus.Text="Current HP must be a number."; return }
    if (-not [int]::TryParse($tbMax.Text,[ref]$m))  { $lblStatus.Text="Max HP must be a number."; return }
    if (-not [int]::TryParse($tbAsc.Text,[ref]$a))  { $lblStatus.Text="Ascension must be a number."; return }
    $sh = [int]$nudShuffle.Value

    if ($script:schema -ne $STS2_KNOWN_SCHEMA) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "This save is schema_version $($script:schema), but the editor was built/tested for $STS2_KNOWN_SCHEMA.`n`nA game update may have changed the save format - writing could corrupt this run (a backup is still made).`n`nSave anyway?",
            "Unrecognized save version", [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $lblStatus.Text="Cancelled (schema mismatch)."; return }
    }

    if (Test-GameRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Slay the Spire 2 looks like it's running. Steam Cloud may overwrite this edit on exit.`n`nSave anyway?",
            "Game running", [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $lblStatus.Text="Cancelled."; return }
    }

    $script:p.gold       = $g
    $script:p.current_hp = $c
    $script:p.max_hp     = $m
    $script:save.ascension = $a
    $script:save.rng.counters.shuffle = $sh

    # backup
    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bdir  = Join-Path $PSScriptRoot 'backups'
        if (-not (Test-Path $bdir)) { New-Item -ItemType Directory -Path $bdir | Out-Null }
        Copy-Item -LiteralPath $script:SavePath -Destination (Join-Path $bdir "current_run.$stamp.save")
    } catch {
        $lblStatus.Text = "Backup failed: $($_.Exception.Message)"; return
    }

    # write
    try {
        $json = $script:save | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($script:SavePath, $json, [System.Text.UTF8Encoding]::new($false))
        Save-EditStamp $script:SavePath (Get-Sts2FileSha $script:SavePath)   # remember what we wrote (last-writer detection)
        $lblStatus.Text = "Saved $stamp. Re-launch the game. (backup kept)"
    } catch {
        $lblStatus.Text = "Save failed: $($_.Exception.Message)"
    }
})

# ---- reshuffle ----------------------------------------------------------
$btnReshuffle.Add_Click({
    if (-not $script:save) { $lblStatus.Text = "No run loaded."; return }
    $nudShuffle.Value = [Math]::Min([decimal]$nudShuffle.Maximum, $nudShuffle.Value + 1)
    $btnApply.PerformClick()   # saves the bumped shuffle (backup + game-running warning)
    if ($lblStatus.Text -like 'Saved*') { $lblStatus.Text = "Reshuffled. Relaunch the game for a new draw on that fight." }
})

# ---- boot ----------------------------------------------------------------
# Always open the window. With a run -> editing enabled. Without -> friendly
# "no run" state, Builds still browsable, Reload to pick up a new run.
$found = Load-Save
Set-RunState $found
Set-Warnings

# Check for a newer release ~0.4s after the window shows (keeps launch instant).
$updTimer = New-Object System.Windows.Forms.Timer
$updTimer.Interval = 400
$updTimer.Add_Tick({
    $updTimer.Stop()
    $tag = Get-UpdateTag
    if ($tag) {
        $llUpdate.Text = "Update available: $tag (you have $STS2_TOOL_VERSION) - click to download"
        $llUpdate.Visible = $true
    }
})
$form.Add_Shown({ $updTimer.Start() })

# Make sure the scroll range reaches the lowest control (the Apply button / status).
$bottom = ($form.Controls | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum
$form.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($bottom + 12))

[void]$form.ShowDialog()
