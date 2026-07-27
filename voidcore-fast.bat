@echo off
rem  Nebulous Voidcore planner - INSTANT mode (no sims, ~3 seconds).
rem
rem  Answers: which Mythic+ dungeon is likeliest to hand me a Myth item in a
rem  slot where I currently have LOWER item level?
rem
rem  1. In WoW: type /simc, press Ctrl+C  (the export is now on your clipboard)
rem  2. Double-click this file. That's it.
rem
rem  Blind to stats and trinket procs - when the answer is close, or when
rem  weapons/trinkets are in play, use voidcore.bat instead (that one sims).
rem
rem  Optionally:
rem    voidcore-fast.bat -KeyLevel 6                   (rolls award ilvl 266)
rem    voidcore-fast.bat my_characters\somechar.simc   (or drag a .simc onto this file)
setlocal
set ARGS=%*
if exist "%~1" set ARGS=-InputFile "%~1" %2 %3 %4 %5 %6 %7 %8 %9
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0voidcore-dungeons.ps1" -Fast %ARGS%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0voidcore-dungeons.ps1" -Fast %ARGS%
)
pause
