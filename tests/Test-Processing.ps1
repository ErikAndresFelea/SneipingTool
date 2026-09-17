$ErrorActionPreference = 'Stop'
# Ruta al script bajo prueba, relativa a esta carpeta.
$src = [System.IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'SnipBatch.ps1')

$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { "PARSE: $($_.Message) (linea $($_.Extent.StartLineNumber))" }; exit 1 }
'PARSE OK'

$text  = Get-Content $src -Raw
$logic = $text.Substring(0, $text.IndexOf('# --- Ventana principal'))
$tmp   = Join-Path $env:TEMP 'snipbatch_logic.ps1'
Set-Content -Path $tmp -Value $logic -Encoding UTF8
. $tmp

$script:pass = 0; $script:fail = 0
function Chk($actual, $expected, $name) {
    if ("$actual" -eq "$expected") { $script:pass++ }
    else { $script:fail++; "  FALLO  $name : esperado <$expected>  obtenido <$actual>" }
}

# --- Get-UniqueName ---
$used = New-Object 'System.Collections.Generic.HashSet[string]'
Chk (Get-UniqueName -BaseName 'shot' -Used $used) 'shot'     'primer nombre'
Chk (Get-UniqueName -BaseName 'shot' -Used $used) 'shot (2)' 'segundo choque'
Chk (Get-UniqueName -BaseName 'shot' -Used $used) 'shot (3)' 'tercer choque'
Chk (Get-UniqueName -BaseName 'SHOT' -Used $used) 'SHOT (4)' 'choque ignorando mayusculas'
Chk (Get-UniqueName -BaseName 'otro' -Used $used) 'otro'     'nombre libre'

# --- Preparar imagenes ---
$dir = Join-Path $env:TEMP 'snipbatch_imgs'
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
[void](New-Item -ItemType Directory -Path $dir)

function New-TestImage($path, $w, $h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.FillRectangle([System.Drawing.Brushes]::Black, 100, 100, 200, 150)
    $g.FillRectangle([System.Drawing.Brushes]::Red, 120, 120, 40, 40)
    # gris muy oscuro: solo debe desaparecer con tolerancia alta
    $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 20, 20, 20))
    $g.FillRectangle($dark, 200, 120, 30, 30)
    $dark.Dispose(); $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
New-TestImage (Join-Path $dir 'a.png') 800 600
New-TestImage (Join-Path $dir 'c.png') 400 300           # mitad de tamano
Copy-Item (Join-Path $dir 'a.png') (Join-Path $dir 'a.jpg')   # mismo nombre, otra extension

Chk (Get-ImageFiles $dir).Count 3 'encuentra 3 imagenes'
Chk (Get-ImageFiles 'Z:\no\existe').Count 0 'carpeta inexistente no revienta'

# --- Lote con nombres unicos ---
$out = Join-Path $dir 'recortadas'
[void](New-Item -ItemType Directory -Path $out)
$region = New-Object System.Drawing.Rectangle(100, 100, 200, 150)
$used = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($f in (Get-ImageFiles $dir)) {
    $base = Get-UniqueName -BaseName ([System.IO.Path]::GetFileNameWithoutExtension($f.Name)) -Used $used
    $r = Invoke-Crop -Path $f.FullName -Region $region -RefWidth 800 -RefHeight 600 `
                     -OutPath (Join-Path $out "$base.png") -BlackToAlpha $true -Tolerance 12
    "  {0,-8} -> Ok={1} {2}" -f $f.Name, $r.Ok, $r.Message
}
$names = (Get-ChildItem $out | Sort-Object Name).Name -join ', '
Chk $names 'a (2).png, a.png, c.png' 'a.jpg no pisa a a.png'

# --- Contenido ---
function Get-Px($path, $x, $y) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $img = [System.Drawing.Bitmap]::FromStream($ms)
    $px = $img.GetPixel($x, $y)
    $img.Dispose(); $ms.Dispose()
    return $px
}
$p = Get-Px (Join-Path $out 'a.png') 5 5
Chk "$($p.A)" '0' 'negro -> transparente'
$p = Get-Px (Join-Path $out 'a.png') 30 30
Chk "$($p.A),$($p.R),$($p.G),$($p.B)" '255,255,0,0' 'rojo intacto'
$p = Get-Px (Join-Path $out 'a.png') 110 30
Chk "$($p.A)" '255' 'gris 20 sobrevive con tolerancia 12'

# tolerancia alta: el gris oscuro tambien desaparece
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $region -RefWidth 800 -RefHeight 600 `
                 -OutPath (Join-Path $out 'tol.png') -BlackToAlpha $true -Tolerance 40
$p = Get-Px (Join-Path $out 'tol.png') 110 30
Chk "$($p.A)" '0' 'gris 20 desaparece con tolerancia 40'

# sin la opcion, nada se vuelve transparente
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $region -RefWidth 800 -RefHeight 600 `
                 -OutPath (Join-Path $out 'opaco.png') -BlackToAlpha $false -Tolerance 12
$p = Get-Px (Join-Path $out 'opaco.png') 5 5
Chk "$($p.A),$($p.R)" '255,0' 'sin la opcion el negro sigue opaco'

# region fuera de la imagen -> se salta, no revienta
$fuera = New-Object System.Drawing.Rectangle(5000, 5000, 100, 100)
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $fuera -RefWidth 800 -RefHeight 600 `
                 -OutPath (Join-Path $out 'fuera.png') -BlackToAlpha $false -Tolerance 0
Chk $r.Ok 'False' 'region fuera se salta limpiamente'
Chk (Test-Path (Join-Path $out 'fuera.png')) 'False' 'no deja archivo basura'

# --- Formatos de salida ---
Chk (Get-FormatInfo 'PNG').Extension '.png' 'PNG -> .png'
Chk (Get-FormatInfo 'JPG').Extension '.jpg' 'JPG -> .jpg'
Chk (Get-FormatInfo 'BMP').Extension '.bmp' 'BMP -> .bmp'
Chk (Get-FormatInfo 'png').Extension '.png' 'no distingue mayusculas'
Chk (Get-FormatInfo 'loquesea').Name 'PNG' 'formato desconocido cae en PNG'
Chk (Get-FormatInfo 'PNG').SupportsAlpha $true  'PNG admite alfa'
Chk (Get-FormatInfo 'JPG').SupportsAlpha $false 'JPG no admite alfa'
Chk (Get-FormatInfo 'BMP').SupportsAlpha $false 'BMP no admite alfa'

function Get-ImageInfo($path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream(, $b)
    $im = [System.Drawing.Image]::FromStream($ms)
    $r = [pscustomobject]@{ W = $im.Width; H = $im.Height; Fmt = $im.RawFormat.Guid }
    $im.Dispose(); $ms.Dispose()
    return $r
}

foreach ($f in @('PNG', 'JPG', 'BMP')) {
    $info = Get-FormatInfo $f
    $ruta = Join-Path $out "fmt$($info.Extension)"
    $r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $region -RefWidth 800 -RefHeight 600 `
                     -OutPath $ruta -BlackToAlpha $true -Tolerance 12 -Format $f
    Chk $r.Ok 'True' "$f se guarda sin error"
    $meta = Get-ImageInfo $ruta
    Chk "$($meta.W)x$($meta.H)" '200x150' "$f mantiene el tamano del recorte"
    Chk $meta.Fmt $info.Format.Guid "$f se guarda con el codec correcto"
}

# JPG: lo transparente se aplana sobre BLANCO, no sobre negro
$p = Get-Px (Join-Path $out 'fmt.jpg') 5 5
Chk ($p.R -gt 240 -and $p.G -gt 240 -and $p.B -gt 240) $true 'JPG aplana la transparencia sobre blanco'
# BMP igual
$p = Get-Px (Join-Path $out 'fmt.bmp') 5 5
Chk "$($p.R),$($p.G),$($p.B)" '255,255,255' 'BMP aplana la transparencia sobre blanco'
# PNG conserva el alfa
$p = Get-Px (Join-Path $out 'fmt.png') 5 5
Chk "$($p.A)" '0' 'PNG conserva la transparencia'
# el rojo sobrevive en los tres
foreach ($e in @('.png', '.jpg', '.bmp')) {
    $p = Get-Px (Join-Path $out "fmt$e") 30 30
    Chk ($p.R -gt 200 -and $p.G -lt 60 -and $p.B -lt 60) $true "$e conserva el rojo"
}

# calidad JPEG: 90 debe pesar mas que 40
$a = Join-Path $out 'q90.jpg'; $b = Join-Path $out 'q40.jpg'
$bmpq = New-Object System.Drawing.Bitmap((Join-Path $dir 'a.png'))
Save-CropBitmap -Bitmap $bmpq -Path $a -Format 'JPG' -JpegQuality 90
Save-CropBitmap -Bitmap $bmpq -Path $b -Format 'JPG' -JpegQuality 40
$bmpq.Dispose()
Chk ((Get-Item $a).Length -gt (Get-Item $b).Length) $true 'la calidad JPEG se aplica de verdad'

# sin imagen de referencia no divide por cero
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $region -RefWidth 0 -RefHeight 0 `
                 -OutPath (Join-Path $out 'nada.png') -BlackToAlpha $false -Tolerance 0
Chk $r.Ok 'False' 'sin referencia devuelve fallo controlado'
Chk $r.Message 'sin imagen de referencia' 'y lo explica'

# los originales no quedan bloqueados
try { Remove-Item (Join-Path $dir 'a.png') -Force; $script:pass++ }
catch { $script:fail++; "  FALLO  archivo origen bloqueado: $_" }

''
"RESULTADO PROCESADO: $script:pass OK, $script:fail fallos"
if ($script:fail -gt 0) { exit 1 }
