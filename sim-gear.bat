@echo off
rem  SimC gear scanner.
rem  1. In WoW: type /simc, press Ctrl+C  (the export is now on your clipboard)
rem  2. Double-click this file. That's it.
rem  Optionally: sim-gear.bat my_characters\somechar.simc
setlocal
set ARGS=
if not "%~1"=="" set ARGS=-InputFile "%~1"
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0gear-options.ps1" %ARGS%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gear-options.ps1" %ARGS%
)
pause
