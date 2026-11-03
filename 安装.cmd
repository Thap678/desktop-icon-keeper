@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DesktopIconKeeper.ps1" -Action Install
echo.
pause
