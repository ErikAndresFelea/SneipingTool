@echo off
rem Runs every SnipBatch test and keeps the window open afterwards.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Run-AllTests.ps1"
echo.
pause
