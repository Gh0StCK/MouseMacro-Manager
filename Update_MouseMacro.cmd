@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update_MouseMacro.ps1"
if errorlevel 1 (
    echo.
    echo Update failed; see the error above.
    pause
)
