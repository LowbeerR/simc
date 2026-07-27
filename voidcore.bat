@echo off
rem  Nebulous Voidcore dungeon planner - "which M+ dungeon should I spam?"
rem  1. In WoW: type /simc, press Ctrl+C  (the export is now on your clipboard)
rem  2. Double-click this file. That's it.
rem
rem  Optionally:
rem    voidcore.bat -KeyLevel 6                        (rolls award ilvl 266)
rem    voidcore.bat my_characters\somechar.simc        (or drag a .simc onto this file)
rem    voidcore.bat my_characters\me.simc -KeyLevel 8
rem    voidcore.bat -Owned 251080,251085               (already won these via Voidcore)
setlocal
set ARGS=%*
if exist "%~1" set ARGS=-InputFile "%~1" %2 %3 %4 %5 %6 %7 %8 %9
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0voidcore-dungeons.ps1" %ARGS%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0voidcore-dungeons.ps1" %ARGS%
)
pause
