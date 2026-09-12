@echo off
rem Campus network auto-login - resume the scheduled task
rem Double click this file, then confirm the UAC prompt.
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo Resuming campus auto-login... a UAC window will pop up, please click Yes.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusAutoLoginTaskState.ps1" -Action Resume
if errorlevel 1 (
    echo.
    echo If nothing happened, please run CampusAutoLoginTaskState.ps1 as Administrator.
)
echo.
pause
