@echo off
rem  Opens the paste window for the gear scanner (gear-gui.ps1).
rem  In WoW: type /simc, press Ctrl+C, then paste into the window.
setlocal
where pwsh >nul 2>&1
if %errorlevel%==0 (
    start "" pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0gear-gui.ps1"
) else (
    start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0gear-gui.ps1"
)
endlocal
