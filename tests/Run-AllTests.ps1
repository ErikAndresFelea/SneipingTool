# Runs the three suites and sums up. None of them open dialogs or take over
# the mouse or keyboard.
$ErrorActionPreference = 'Continue'
$env:SNIPBATCH_NODIALOG = '1'   # without this flag a startup error would open a modal

$suites = @(
    @{ Name = 'Selection geometry';       File = 'Test-Geometry.ps1'   },
    @{ Name = 'Cropping and transparency'; File = 'Test-Processing.ps1' },
    @{ Name = 'Main window';              File = 'Test-Window.ps1'     }
)

$failed = 0
foreach ($s in $suites) {
    Write-Host ''
    Write-Host "=== $($s.Name) ===" -ForegroundColor Cyan
    $path = Join-Path $PSScriptRoot $s.File
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $path 2>&1 |
        ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        $failed++
        Write-Host "  --> FAILED" -ForegroundColor Red
    }
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host 'ALL SUITES PASS' -ForegroundColor Green
    exit 0
}
Write-Host "$failed suite(s) with failures" -ForegroundColor Red
exit 1
