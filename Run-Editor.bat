@echo off
REM Launches the StS2 Save Editor under Windows PowerShell (STA, for a stable window).
REM Double-click this file. The save and game files are auto-detected from Steam.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Show-StS2Editor.ps1" %*
