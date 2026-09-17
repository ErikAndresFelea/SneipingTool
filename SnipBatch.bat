@echo off
rem Lanzador de SnipBatch. Doble clic y listo: no requiere instalar nada.
setlocal
set "PS1=%~dp0SnipBatch.ps1"

if not exist "%PS1%" (
    echo.
    echo No se encuentra SnipBatch.ps1 junto a este archivo.
    echo Los dos deben estar en la misma carpeta.
    echo.
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%"
