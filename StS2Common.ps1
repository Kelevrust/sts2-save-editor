<#
  StS2Common.ps1 - shared path auto-detection + helpers for the StS2 save tools.
  Dot-source this from the editor/CLI:  . (Join-Path $PSScriptRoot 'StS2Common.ps1')
#>

$Global:STS2_APPID        = '2868840'
$Global:STS2_KNOWN_SCHEMA = 16   # save schema this editor was built/tested against
$Global:STS2_TOOL_VERSION = 'v1.2.0'                # bump this with each release tag
$Global:STS2_REPO         = 'Kelevrust/sts2-save-editor'
$Global:STS2_RELEASES_URL = "https://github.com/$STS2_REPO/releases/latest"

# Best-effort update check: returns the latest release tag if it's NEWER than
# this build, else $null. Sends nothing; fails silently offline.
function Get-UpdateTag {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$STS2_REPO/releases/latest" `
             -Headers @{ 'User-Agent' = 'sts2-save-editor' } -TimeoutSec 4 -ErrorAction Stop
        $latest = "$($r.tag_name)"
        if (-not $latest) { return $null }
        if ([version]($latest.TrimStart('v')) -gt [version]($STS2_TOOL_VERSION.TrimStart('v'))) { return $latest }
    } catch { }
    return $null
}

# --- Steam install root (registry, then common fallbacks) -----------------
function Find-SteamRoot {
    foreach ($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam') {
        $v = Get-ItemProperty $k -ErrorAction SilentlyContinue
        $p = if ($v.SteamPath) { $v.SteamPath } elseif ($v.InstallPath) { $v.InstallPath }
        if ($p) { $p = $p -replace '/','\'; if (Test-Path $p) { return $p } }
    }
    foreach ($g in 'C:\Program Files (x86)\Steam','C:\Program Files\Steam','D:\Steam') {
        if (Test-Path $g) { return $g }
    }
    return $null
}

# --- all Steam library roots (main + libraryfolders.vdf) -------------------
function Get-Sts2Libraries($steam) {
    $libs = @()
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"')) {
                $libs += ($m.Matches[0].Groups[1].Value -replace '\\\\','\')
            }
        }
    }
    return ($libs | Sort-Object -Unique)
}

# --- locate SlayTheSpire2.pck (for the Refresh-IDs scan) -------------------
function Find-Sts2Pck {
    param([switch]$Prompt)
    foreach ($l in (Get-Sts2Libraries (Find-SteamRoot))) {
        $p = Join-Path $l 'steamapps\common\Slay the Spire 2\SlayTheSpire2.pck'
        if (Test-Path $p) { return $p }
    }
    if ($Prompt) {
        Add-Type -AssemblyName System.Windows.Forms
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Godot pack (*.pck)|*.pck|All files (*.*)|*.*'
        $ofd.Title  = 'Locate SlayTheSpire2.pck'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $ofd.FileName }
    }
    return $null
}

# --- locate the saves folder(s), newest first -----------------------------
function Get-Sts2SaveFolders {
    $steam = Find-SteamRoot
    if (-not $steam) { return @() }
    $udata = Join-Path $steam 'userdata'
    if (-not (Test-Path $udata)) { return @() }
    $folders = @()
    foreach ($acct in (Get-ChildItem $udata -Directory -ErrorAction SilentlyContinue)) {
        $rem = Join-Path $acct.FullName "$STS2_APPID\remote"
        if (Test-Path $rem) {
            foreach ($sf in (Get-ChildItem $rem -Recurse -Directory -Filter 'saves' -ErrorAction SilentlyContinue)) {
                if ((Test-Path (Join-Path $sf.FullName 'progress.save')) -or (Test-Path (Join-Path $sf.FullName 'current_run.save'))) {
                    $folders += $sf.FullName
                }
            }
        }
    }
    return ($folders | Sort-Object {
        $cr = Join-Path $_ 'current_run.save'; $pr = Join-Path $_ 'progress.save'
        if (Test-Path $cr) { (Get-Item $cr).LastWriteTime }
        elseif (Test-Path $pr) { (Get-Item $pr).LastWriteTime }
        else { [datetime]::MinValue }
    } -Descending)
}

# --- locate current_run.save (active run); picker fallback ----------------
# Returns a path that MAY NOT EXIST yet (no active run); caller checks Test-Path.
function Find-Sts2Save {
    param([switch]$Prompt)
    $folders = @(Get-Sts2SaveFolders)
    foreach ($f in $folders) { $cr = Join-Path $f 'current_run.save'; if (Test-Path $cr) { return $cr } }
    if ($Prompt) {
        Add-Type -AssemblyName System.Windows.Forms
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'StS2 run save|current_run.save|Save files (*.save)|*.save|All files (*.*)|*.*'
        $ofd.Title  = 'Locate current_run.save (start a run first if you have none)'
        if ($folders.Count) { $ofd.InitialDirectory = $folders[0] }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $ofd.FileName }
    }
    if ($folders.Count) { return (Join-Path $folders[0] 'current_run.save') }  # may not exist
    return $null
}
