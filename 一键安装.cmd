@echo off
rem Campus network auto-login - one click installer
rem Double click this file, then confirm the UAC prompt.
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo Installing campus auto-login... a UAC window will pop up, please click Yes.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-DrcomAutoLogin.ps1"
if errorlevel 1 (
    echo.
    echo If nothing happened, please run Setup-DrcomAutoLogin.ps1 as Administrator.
)
echo.
pause
