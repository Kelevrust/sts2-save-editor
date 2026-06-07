# StS2 Save Editor + Build Cheatsheet

A lightweight save editor and run-planning tool for **Slay the Spire 2** (early access),
plus a built-in **build cheatsheet** for every character. Pure PowerShell + WinForms —
no install, no dependencies, all plain-text so you can read every line before running it.

> ⚠️ **Single-player only. Back up your saves. Use at your own risk.** This edits your
> local run file directly. It is not affiliated with or endorsed by Mega Crit.

![Windows only](https://img.shields.io/badge/platform-Windows-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-green)

## What it does

- **Edit your current run** — gold, current/max HP (with Full Heal), ascension.
- **Add/remove relics, potions, and cards** from searchable dropdowns containing
  *every* item in the game (auto-extracted from the game files — 341 relics, 63 potions,
  ~550 cards), with friendly names and an "upgraded" toggle for cards.
- **What's Ahead** — reads the pre-rolled queues in your save and shows the exact
  upcoming normal fights, elites, ? events, and boss for each act. (Route planner, not
  a full seed predictor — it only reads what your save has already rolled.)
- **Builds** — an anchored cheatsheet drawer. Pick a class, pick a build, and see the
  key cards/relics up top with the play breakdown below. All five classes, grounded in
  the actual card/relic effects.
- **Refresh IDs** — re-scans the game's `.pck` to rebuild the card/relic/potion lists
  after a patch (so the dropdowns stay current).
- **Safe by default** — every save is backed up first (to `backups/`), and the editor
  warns if the game is running, if the save version is unrecognized, or if it's a
  multiplayer save.

## Requirements

- **Windows** (uses Windows PowerShell + WinForms — no Mac/Linux/Deck support).
- **Slay the Spire 2** installed via Steam (paths are auto-detected).

## Install & run

1. **Download** this repo (green *Code* button → *Download ZIP*) and unzip it anywhere.
2. **Unblock it** (Windows flags files from the internet): right-click
   `Run-Editor.bat` → **Properties** → tick **Unblock** → OK. (Do the same for the
   `.ps1` files if needed.)
3. **Double-click `Run-Editor.bat`.**

The save file and the game `.pck` are found automatically from your Steam install.
If auto-detection fails, the tool will pop a file picker so you can point it at them.

> **"Windows protected your PC" / antivirus warning?** This is an unsigned community
> script, so Windows is cautious. The code is plain-text PowerShell — read it. You can
> also scan it on [VirusTotal](https://www.virustotal.com/). If you'd rather not run a
> `.bat`, open PowerShell in this folder and run:
> `powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\Show-StS2Editor.ps1`

## ⚠️ Steam Cloud will undo your edits unless you disable it

This is the #1 gotcha. Steam Cloud re-syncs the cloud copy over your local edit, so:

1. In Steam: right-click **Slay the Spire 2** → **Properties** → **General** →
   uncheck **"Keep game saves in the Steam Cloud for Slay the Spire 2."**
2. **Fully quit the game** before editing (not just to the menu).
3. Edit → save → relaunch.

If your edit doesn't stick, Steam Cloud is still on somewhere.

## Files

| File | What it is |
|---|---|
| `Run-Editor.bat` | Double-click launcher |
| `Show-StS2Editor.ps1` | The GUI editor |
| `Edit-StS2Save.ps1` | Command-line editor (scriptable) |
| `StS2Common.ps1` | Shared Steam/save/pck auto-detection |
| `sts2-ids.json` | All relic/potion/card IDs (rebuild via *Refresh IDs*) |
| `builds.json` | The build cheatsheet (plain JSON — edit to taste) |

## Notes & honesty

- **Early access.** StS2 will keep changing. Card/relic lists self-heal via *Refresh IDs*;
  if a patch changes the save format, the editor warns on an unrecognized `schema_version`
  before writing.
- **The builds are opinion.** Card and relic *effects* are pulled straight from the game
  files (reliable). The *archetype groupings and "go-to" picks* are mechanics-based
  judgment, not a scraped tier list — the meta is young. `builds.json` is yours to edit.
- **Multiplayer saves are untested** — the editor flags them but isn't designed for co-op.

## License

MIT — see [LICENSE](LICENSE).
