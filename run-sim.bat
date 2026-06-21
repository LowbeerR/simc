@echo off
setlocal
rem ============================================================
rem  SimulationCraft easy runner
rem  Usage: drag a .simc file onto this script, or:
rem         run-sim.bat my_characters\mychar.simc
rem  Produces an HTML report next to the input file and opens it.
rem ============================================================

set SIMC=%~dp0build\simc.exe

if not exist "%SIMC%" (
    echo ERROR: simc.exe not found at %SIMC%
    echo Build it first: see README-LOCAL.md
    pause
    exit /b 1
)

if "%~1"=="" (
    echo Usage: drag a .simc file onto this script,
    echo        or run:  run-sim.bat my_characters\mychar.simc
    echo.
    echo Get your .simc file from the in-game "Simulationcraft" addon:
    echo   type /simc in WoW chat, Ctrl+C the text, paste into a .simc file.
    pause
    exit /b 1
)

set REPORT=%~dpn1_report.html

echo Running simulation on %~nx1 ...
"%SIMC%" "%~1" html="%REPORT%" threads=0
if errorlevel 1 (
    echo.
    echo Simulation failed - see error above.
    pause
    exit /b 1
)

echo.
echo Report written to %REPORT%
start "" "%REPORT%"
endlocal
