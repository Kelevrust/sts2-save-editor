<#
  StS2Common.ps1 - shared path auto-detection + helpers for the StS2 save tools.
  Dot-source this from the editor/CLI:  . (Join-Path $PSScriptRoot 'StS2Common.ps1')
#>

$Global:STS2_APPID        = '2868840'
$Global:STS2_KNOWN_SCHEMA = 16   # save schema this editor was built/tested against
$Global:STS2_TOOL_VERSION = 'v1.7.0'                # bump this with each release tag
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

# --- locate the saves folder(s) ------------------------------------------
# IMPORTANT: the game READS/WRITES its save in Godot's user dir under
# %APPDATA%\SlayTheSpire2 (the authoritative copy). Steam Cloud keeps a MIRROR
# under userdata\<acct>\<appid>\remote. Editing only the mirror loses to the
# game on launch (it rewrites from AppData) - the cause of "edits revert". So we
# return AppData folders FIRST (real file), then the Steam mirror.
function Get-Sts2SaveFolders {
    $hasRun = { (Test-Path (Join-Path $_.FullName 'progress.save')) -or (Test-Path (Join-Path $_.FullName 'current_run.save')) }
    $byTime = { $cr = Join-Path $_ 'current_run.save'; if (Test-Path $cr) { (Get-Item $cr).LastWriteTime } else { [datetime]::MinValue } }

    # (1) Game's real save dir - Godot user:// under AppData (authoritative)
    $app = @()
    $appRoot = Join-Path $env:APPDATA 'SlayTheSpire2'
    if (Test-Path $appRoot) {
        $app = @(Get-ChildItem $appRoot -Recurse -Directory -Filter 'saves' -ErrorAction SilentlyContinue | Where-Object $hasRun | ForEach-Object FullName)
    }

    # (2) Steam Cloud mirror - userdata\<acct>\<appid>\remote (synced by Steam)
    $rem = @()
    $steam = Find-SteamRoot
    if ($steam) {
        $udata = Join-Path $steam 'userdata'
        if (Test-Path $udata) {
            foreach ($acct in (Get-ChildItem $udata -Directory -ErrorAction SilentlyContinue)) {
                $r = Join-Path $acct.FullName "$STS2_APPID\remote"
                if (Test-Path $r) {
                    $rem += @(Get-ChildItem $r -Recurse -Directory -Filter 'saves' -ErrorAction SilentlyContinue | Where-Object $hasRun | ForEach-Object FullName)
                }
            }
        }
    }

    return @(@($app | Sort-Object -Unique | Sort-Object $byTime -Descending) + @($rem | Sort-Object -Unique | Sort-Object $byTime -Descending))
}

# --- every current_run.save copy belonging to the SAME run ----------------
# An edit must hit ALL copies the game/Steam keep in sync (AppData + remote),
# but NEVER a different profile's run. We match by seed+start_time so only the
# real run's copies are written. Always includes $PrimaryPath.
function Get-Sts2SaveTargets {
    param([string]$PrimaryPath, $Save)
    $targets = New-Object System.Collections.Generic.List[string]
    if ($PrimaryPath) { $targets.Add($PrimaryPath) }
    if ($Save) {
        $id = "$($Save.start_time)|$($Save.rng.seed)"
        foreach ($f in (Get-Sts2SaveFolders)) {
            $c = Join-Path $f 'current_run.save'
            if (-not (Test-Path -LiteralPath $c)) { continue }
            try {
                $o = Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json
                if ("$($o.start_time)|$($o.rng.seed)" -eq $id) { $targets.Add($c) }
            } catch {}
        }
    }
    return @($targets | Sort-Object -Unique)
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

# Inspect Steam Cloud's remotecache.vdf for a save file. Steam stores StS2 saves
# under ...\userdata\<id>\<appid>\remote\..., and remotecache.vdf (a sibling of
# 'remote') records the size/sha/times Steam last synced. If the save has an
# entry there, Steam Cloud is/was tracking it and can overwrite local edits on
# launch. Returns $null when not tracked (or no cache), else a hashtable with the
# cached size/sha and whether the on-disk size still matches (cheap last-writer
# hint for later). Pure-read, no Steam API.
function Get-Sts2CloudCacheInfo {
    param([string]$SavePath)
    if (-not $SavePath -or -not (Test-Path -LiteralPath $SavePath)) { return $null }
    # Walk up to the 'remote' folder; remotecache.vdf sits beside it (one level up).
    $remoteRoot = $null
    $d = (Get-Item -LiteralPath $SavePath).DirectoryName
    while ($d) {
        if ((Split-Path $d -Leaf) -eq 'remote') { $remoteRoot = $d; break }
        $d = Split-Path $d
    }
    if (-not $remoteRoot) { return $null }
    $cache = Join-Path (Split-Path $remoteRoot) 'remotecache.vdf'
    if (-not (Test-Path -LiteralPath $cache)) { return $null }
    # Key in the vdf is the path relative to 'remote', forward-slashed and quoted.
    $rel = $SavePath.Substring($remoteRoot.Length).TrimStart('\','/').Replace('\','/')
    $txt = Get-Content -LiteralPath $cache -Raw -Encoding UTF8
    $key = '"' + $rel + '"'
    $i = $txt.IndexOf($key, [System.StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { return $null }   # present in cloud folder but not tracked
    $open  = $txt.IndexOf('{', $i)
    $close = if ($open -ge 0) { $txt.IndexOf('}', $open) } else { -1 }
    $block = if ($open -ge 0 -and $close -gt $open) { $txt.Substring($open, $close - $open) } else { '' }
    $cachedSize = if ($block -match '"size"\s*"([^"]*)"') { $matches[1] } else { $null }
    $cachedSha  = if ($block -match '"sha"\s*"([^"]*)"')  { $matches[1] } else { $null }
    $fileSize   = (Get-Item -LiteralPath $SavePath).Length
    return @{
        Tracked    = $true
        CachePath  = $cache
        RelKey     = $rel
        CachedSize = $cachedSize
        CachedSha  = $cachedSha
        FileSize   = $fileSize
        SizeMatch  = ($cachedSize -eq "$fileSize")
    }
}

# SHA1 of a file as lowercase hex (matches the format Steam stores in
# remotecache.vdf, so the two can be compared directly). $null on any error.
function Get-Sts2FileSha {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLower() } catch { return $null }
}
