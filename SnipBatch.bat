@echo off
rem SnipBatch launcher. Double-click and go: nothing needs installing.
setlocal
set "PS1=%~dp0SnipBatch.ps1"

if not exist "%PS1%" (
    echo.
    echo SnipBatch.ps1 was not found next to this file.
    echo Both must sit in the same folder.
    echo.
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%"
