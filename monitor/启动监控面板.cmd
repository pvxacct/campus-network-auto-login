@echo off
rem Campus Network Monitor - plain launcher (a console window stays while the panel runs).
rem The hidden launcher next to this file (the .vbs one) does not show any window.
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CampusNetworkMonitor.ps1" %*
if errorlevel 1 (
    echo.
    echo The monitor exited with an error. Press any key to close.
    pause >nul
)
