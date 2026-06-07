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

# ---- shared state --------------------------------------------------------
# Auto-detect the active run save unless one was passed in.
if (-not $SavePath) { $SavePath = Find-Sts2Save -Prompt }
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
        [System.Windows.Forms.MessageBox]::Show(
            "No active run found (current_run.save).`n`nStart a run in Slay the Spire 2 first - the file appears once you're in a run - then reopen the editor.",
            "No active run", 'OK', 'Information') | Out-Null
        return $false
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

function Test-GameRunning {
    $r = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'spire' }
    return [bool]$r
}

# ---- form ----------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "StS2 Save Editor"
$form.Size = New-Object System.Drawing.Size(440, 800)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

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
$y += 36

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

# Info buttons (read-only views)
$btnAhead  = New-Button "What's Ahead" 10 $y 130
$btnBuilds = New-Button "Builds"      150 $y 130
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

# Keep the drawer pinned to the editor's right edge, matching its height.
function Set-DrawerPosition {
    if ($script:buildsWin -and -not $script:buildsWin.IsDisposed) {
        $script:buildsWin.Location = New-Object System.Drawing.Point(($form.Location.X + $form.Width), $form.Location.Y)
        $script:buildsWin.Height   = $form.Height
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

# ---- "what's ahead" reader ---------------------------------------------
$btnAhead.Add_Click({
    $sb = New-Object System.Text.StringBuilder
    $ai = [int]$script:save.current_act_index
    for ($k = $ai; $k -lt $script:save.acts.Count; $k++) {
        $act = $script:save.acts[$k]; $r = $act.rooms
        $tag = if ($k -eq $ai) { " (current)" } else { "" }
        [void]$sb.AppendLine("=== $($act.id)$tag ===")
        foreach ($trip in @(
            @('normal_encounter_ids','normal_encounters_visited','Normal fights'),
            @('elite_encounter_ids','elite_encounters_visited','Elites'),
            @('event_ids','events_visited','? events'))) {
            $ids = $r.($trip[0]); $v = [int]$r.($trip[1])
            $remaining = if ($k -eq $ai) { $v } else { 0 }   # only the current act has progress
            $upcoming = @($ids | Select-Object -Skip $remaining | Select-Object -First 8)
            [void]$sb.AppendLine("  $($trip[2]) (next, in visit order):")
            foreach ($x in $upcoming) { [void]$sb.AppendLine("     $($x -replace '^ENCOUNTER\.|^EVENT\.','')") }
        }
        [void]$sb.AppendLine("  BOSS: $($r.boss_id -replace '^ENCOUNTER\.','')")
        [void]$sb.AppendLine("")
    }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "What's Ahead  (seed $($script:save.rng.seed))"
    $dlg.Size = New-Object System.Drawing.Size(480, 620)
    $dlg.StartPosition = "CenterParent"
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
    $tb.Dock = 'Fill'; $tb.Font = New-Object System.Drawing.Font("Consolas", 9)
    $tb.Text = $sb.ToString()
    $dlg.Controls.Add($tb)
    [void]$dlg.ShowDialog()
})

# ---- reload / apply / close ---------------------------------------------
$btnReload.Add_Click({
    if (Load-Save) { Refresh-Fields }
})
$btnClose.Add_Click({ $form.Close() })

$btnApply.Add_Click({
    # validate numerics
    $g=0;$c=0;$m=0;$a=0
    if (-not [int]::TryParse($tbGold.Text,[ref]$g)) { $lblStatus.Text="Gold must be a number."; return }
    if (-not [int]::TryParse($tbCur.Text,[ref]$c))  { $lblStatus.Text="Current HP must be a number."; return }
    if (-not [int]::TryParse($tbMax.Text,[ref]$m))  { $lblStatus.Text="Max HP must be a number."; return }
    if (-not [int]::TryParse($tbAsc.Text,[ref]$a))  { $lblStatus.Text="Ascension must be a number."; return }

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
        $lblStatus.Text = "Saved $stamp. Re-launch the game. (backup kept)"
    } catch {
        $lblStatus.Text = "Save failed: $($_.Exception.Message)"
    }
})

# ---- boot ----------------------------------------------------------------
if (Load-Save) {
    Refresh-Fields
    $warn = @()
    if (Test-GameRunning) { $warn += "StS2 is running - quit first (Steam Cloud will overwrite)." }
    if ($script:schema -ne $STS2_KNOWN_SCHEMA) { $warn += "Save schema $($script:schema) != tested $STS2_KNOWN_SCHEMA - edits risky." }
    if ($script:save.players.Count -gt 1) { $warn += "Multiplayer save ($($script:save.players.Count) players) - editing untested." }
    $lblWarn.Text = ($warn -join "  |  ")
    [void]$form.ShowDialog()
}
