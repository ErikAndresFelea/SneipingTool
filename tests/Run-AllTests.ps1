# Ejecuta las tres suites y resume. Ninguna abre dialogos ni toca raton/teclado.
$ErrorActionPreference = 'Continue'
$env:SNIPBATCH_NODIALOG = '1'   # sin este flag un error de arranque abriria un modal

$suites = @(
    @{ Nombre = 'Geometria de la seleccion'; Archivo = 'Test-Geometry.ps1'   },
    @{ Nombre = 'Recorte y transparencia';   Archivo = 'Test-Processing.ps1' },
    @{ Nombre = 'Ventana principal';         Archivo = 'Test-Window.ps1'     }
)

$fallidas = 0
foreach ($s in $suites) {
    Write-Host ''
    Write-Host "=== $($s.Nombre) ===" -ForegroundColor Cyan
    $ruta = Join-Path $PSScriptRoot $s.Archivo
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $ruta 2>&1 |
        ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        $fallidas++
        Write-Host "  --> FALLA" -ForegroundColor Red
    }
}

Write-Host ''
if ($fallidas -eq 0) {
    Write-Host 'TODAS LAS SUITES PASAN' -ForegroundColor Green
    exit 0
}
Write-Host "$fallidas suite(s) con fallos" -ForegroundColor Red
exit 1
