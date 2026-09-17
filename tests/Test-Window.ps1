# Prueba la ventana principal SIN abrir dialogos ni tocar raton/teclado:
# sustituye el ShowDialog final por asserts sobre el estado de los controles.
$ErrorActionPreference = 'Stop'
# Ruta al script bajo prueba, relativa a esta carpeta.
$src = [System.IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'SnipBatch.ps1')
$text = Get-Content $src -Raw

$driver = @'
$script:pass = 0; $script:fail = 0
function Chk($actual, $expected, $name) {
    if ("$actual" -eq "$expected") { $script:pass++ }
    else { $script:fail++; "  FALLO  $name : esperado <$expected>  obtenido <$actual>" }
}

$base  = $env:TEMP
$vacia = Join-Path $base 'sb_vacia'
$conim = Join-Path $base 'sb_conimg'
foreach ($d in @($vacia, $conim)) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $d)
}
$bmp = New-Object System.Drawing.Bitmap(300, 200)
$bmp.Save((Join-Path $conim 'uno.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Save((Join-Path $conim 'dos.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
[void](New-Item -ItemType File -Path (Join-Path $vacia 'notas.txt'))

Chk $main.Controls.Count 15 'la ventana monta todos los controles'

# --- carpeta con imagenes ---
Set-SourceFolder -Path $conim
Chk $btnRegion.Enabled $true  'con imagenes se habilita Seleccionar region'
Chk $btnRun.Enabled    $false 'sin region, Procesar sigue bloqueado'
Chk $lblCount.Text '2 imagen(es) encontradas. Referencia: dos.png' 'cuenta y referencia (orden alfabetico)'
Chk $txtOut.Text (Join-Path $conim 'recortadas') 'salida por defecto dentro del origen'

# --- carpeta SIN imagenes (esto reventaba con StrictMode) ---
Set-SourceFolder -Path $vacia
Chk $lblCount.Text 'No hay imagenes compatibles en esa carpeta.' 'avisa de carpeta sin imagenes'
Chk $btnRegion.Enabled $false 'sin imagenes no deja seleccionar region'
Chk $btnRun.Enabled    $false 'sin imagenes no deja procesar'

# --- carpeta inexistente ---
Set-SourceFolder -Path 'Z:\no\existe\nada'
Chk $btnRegion.Enabled $false 'ruta inexistente tratada como vacia'

# --- salida manual y vuelta a la predeterminada ---
Set-SourceFolder -Path $conim
$ui.OutFolder = 'D:\otra\parte'
Update-OutBox
Chk $txtOut.Text 'D:\otra\parte' 'salida manual se respeta'
Chk ($lblOutHint.Text -like 'Carpeta de salida fija*') $true 'la pista cambia con salida fija'
$ui.OutFolder = ''
Update-OutBox
Chk $txtOut.Text (Join-Path $conim 'recortadas') 'Predeterminada restaura la subcarpeta'

# --- cambiar de carpeta invalida la region anterior ---
$ui.Region = New-Object System.Drawing.Rectangle(0, 0, 10, 10)
$ui.RefWidth = 300; $ui.RefHeight = 200
Update-RunState
Chk $btnRun.Enabled $true 'con region + imagenes, Procesar se habilita'
Set-SourceFolder -Path $conim
Chk ($null -eq $ui.Region) $true 'al cambiar de carpeta se descarta la region'
Chk $btnRun.Enabled $false 'y Procesar vuelve a bloquearse'

# --- formato de salida y su efecto sobre la transparencia ---
Chk $cmbFormat.SelectedItem 'PNG'  'arranca en PNG'
Chk $chkAlpha.Enabled $true        'con PNG la casilla de alfa esta disponible'
Chk $chkAlpha.Checked $false       'y viene desmarcada'
Chk $numTol.Enabled   $false       'la tolerancia empieza bloqueada'

$chkAlpha.Checked = $true
Chk $numTol.Enabled $true          'marcar alfa desbloquea la tolerancia'
Chk $ui.WantAlpha   $true          'se recuerda la eleccion'

$cmbFormat.SelectedItem = 'JPG'
Chk $chkAlpha.Enabled $false       'JPG deshabilita la casilla de alfa'
Chk $chkAlpha.Checked $false       'y la desmarca'
Chk $numTol.Enabled   $false       'y bloquea la tolerancia'
Chk $ui.WantAlpha     $true        'pero NO olvida lo que el usuario queria'
Chk ($lblFmtHint.Text -like 'JPG no admite transparencia*') $true 'y lo explica'

$cmbFormat.SelectedItem = 'BMP'
Chk $chkAlpha.Enabled $false       'BMP tampoco admite alfa'

$cmbFormat.SelectedItem = 'PNG'
Chk $chkAlpha.Enabled $true        'al volver a PNG se rehabilita'
Chk $chkAlpha.Checked $true        'y se restaura la marca original'
Chk $numTol.Enabled   $true        'con su tolerancia'
$chkAlpha.Checked = $false

# --- cierre durante el proceso ---
# FormClosing solo se dispara si la ventana llego a mostrarse
$main.Show()
[System.Windows.Forms.Application]::DoEvents()
$ui.Busy = $true
$main.Close()
[System.Windows.Forms.Application]::DoEvents()
Chk $main.IsDisposed $false 'estando ocupado, cerrar no destruye la ventana'
Chk $ui.Stop $true          'cerrar pide parar el lote'
$ui.Busy = $false; $ui.Stop = $false

Remove-Item $vacia, $conim -Recurse -Force
''
"RESULTADO VENTANA: $script:pass OK, $script:fail fallos"
$main.Dispose()
if ($script:fail -gt 0) { exit 1 }
'@

$text = $text.Replace('[void]$main.ShowDialog()' + "`n" + '$main.Dispose()', $driver)
$tmp  = Join-Path $env:TEMP 'snipbatch_win.ps1'
Set-Content -Path $tmp -Value $text -Encoding UTF8
& $tmp
