@echo off
rem Ejecuta todas las pruebas de SnipBatch y deja la ventana abierta al terminar.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Run-AllTests.ps1"
echo.
pause
