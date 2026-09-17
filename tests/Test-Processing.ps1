$ErrorActionPreference = 'Stop'
# Path to the script under test, relative to this folder.
$src = [System.IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'SnipBatch.ps1')

$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { "PARSE: $($_.Message) (line $($_.Extent.StartLineNumber))" }; exit 1 }
'PARSE OK'

$text  = Get-Content $src -Raw
$logic = $text.Substring(0, $text.IndexOf('# --- Main window'))
$tmp   = Join-Path $env:TEMP 'snipbatch_logic.ps1'
Set-Content -Path $tmp -Value $logic -Encoding UTF8
. $tmp

$script:pass = 0; $script:fail = 0
function Chk($actual, $expected, $name) {
    if ("$actual" -eq "$expected") { $script:pass++ }
    else { $script:fail++; "  FAIL  $name : expected <$expected>  got <$actual>" }
}

# --- Get-UniqueName ---
$used = New-Object 'System.Collections.Generic.HashSet[string]'
Chk (Get-UniqueName -BaseName 'shot' -Used $used) 'shot'     'first name'
Chk (Get-UniqueName -BaseName 'shot' -Used $used) 'shot (2)' 'second collision'
Chk (Get-UniqueName -BaseName 'shot' -Used $used) 'shot (3)' 'third collision'
Chk (Get-UniqueName -BaseName 'SHOT' -Used $used) 'SHOT (4)' 'collision ignoring case'
Chk (Get-UniqueName -BaseName 'otro' -Used $used) 'otro'     'free name'

# --- Prepare images ---
$dir = Join-Path $env:TEMP 'snipbatch_imgs'
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
[void](New-Item -ItemType Directory -Path $dir)

function New-TestImage($path, $w, $h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.FillRectangle([System.Drawing.Brushes]::Black, 100, 100, 200, 150)
    $g.FillRectangle([System.Drawing.Brushes]::Red, 120, 120, 40, 40)
    # very dark grey: should only vanish at a high tolerance
    $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 20, 20, 20))
    $g.FillRectangle($dark, 200, 120, 30, 30)
    $dark.Dispose(); $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
New-TestImage (Join-Path $dir 'a.png') 800 600
New-TestImage (Join-Path $dir 'c.png') 400 300           # half size
Copy-Item (Join-Path $dir 'a.png') (Join-Path $dir 'a.jpg')   # same name, different extension

Chk (Get-ImageFiles $dir).Count 3 'finds 3 images'
Chk (Get-ImageFiles 'Z:\no\existe').Count 0 'missing folder does not blow up'

# --- Batch with unique names ---
$out = Join-Path $dir 'crops'
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
Chk $names 'a (2).png, a.png, c.png' 'a.jpg does not overwrite a.png'

# --- Contents ---
function Get-Px($path, $x, $y) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $img = [System.Drawing.Bitmap]::FromStream($ms)
    $px = $img.GetPixel($x, $y)
    $img.Dispose(); $ms.Dispose()
    return $px
}
$p = Get-Px (Join-Path $out 'a.png') 5 5
Chk "$($p.A)" '0' 'black -> transparent'
$p = Get-Px (Join-Path $out 'a.png') 30 30
Chk "$($p.A),$($p.R),$($p.G),$($p.B)" '255,255,0,0' 'red untouched'
$p = Get-Px (Join-Path $out 'a.png') 110 30
Chk "$($p.A)" '255' 'grey 20 survives tolerance 12'

# high tolerance: the dark grey vanishes too
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $region -RefWidth 800 -RefHeight 600 `
                 -OutPath (Join-Path $out 'tol.png') -BlackToAlpha $true -Tolerance 40
$p = Get-Px (Join-Path $out 'tol.png') 110 30
Chk "$($p.A)" '0' 'grey 20 vanishes at tolerance 40'

# without the option nothing becomes transparent
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $region -RefWidth 800 -RefHeight 600 `
                 -OutPath (Join-Path $out 'opaco.png') -BlackToAlpha $false -Tolerance 12
$p = Get-Px (Join-Path $out 'opaco.png') 5 5
Chk "$($p.A),$($p.R)" '255,0' 'without the option black stays opaque'

# region outside the image -> skipped, does not blow up
$fuera = New-Object System.Drawing.Rectangle(5000, 5000, 100, 100)
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $fuera -RefWidth 800 -RefHeight 600 `
                 -OutPath (Join-Path $out 'fuera.png') -BlackToAlpha $false -Tolerance 0
Chk $r.Ok 'False' 'outside region is skipped cleanly'
Chk (Test-Path (Join-Path $out 'fuera.png')) 'False' 'leaves no junk file'

# --- Output formats ---
Chk (Get-FormatInfo 'PNG').Extension '.png' 'PNG -> .png'
Chk (Get-FormatInfo 'JPG').Extension '.jpg' 'JPG -> .jpg'
Chk (Get-FormatInfo 'BMP').Extension '.bmp' 'BMP -> .bmp'
Chk (Get-FormatInfo 'png').Extension '.png' 'case insensitive'
Chk (Get-FormatInfo 'loquesea').Name 'PNG' 'unknown format falls back to PNG'
Chk (Get-FormatInfo 'PNG').SupportsAlpha $true  'PNG supports alpha'
Chk (Get-FormatInfo 'JPG').SupportsAlpha $false 'JPG has no alpha'
Chk (Get-FormatInfo 'BMP').SupportsAlpha $false 'BMP has no alpha'

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
    Chk $r.Ok 'True' "$f saves without error"
    $meta = Get-ImageInfo $ruta
    Chk "$($meta.W)x$($meta.H)" '200x150' "$f keeps the crop size"
    Chk $meta.Fmt $info.Format.Guid "$f is saved with the right codec"
}

# JPG: transparency is flattened onto WHITE, not black
$p = Get-Px (Join-Path $out 'fmt.jpg') 5 5
Chk ($p.R -gt 240 -and $p.G -gt 240 -and $p.B -gt 240) $true 'JPG flattens transparency onto white'
# same for BMP
$p = Get-Px (Join-Path $out 'fmt.bmp') 5 5
Chk "$($p.R),$($p.G),$($p.B)" '255,255,255' 'BMP flattens transparency onto white'
# PNG keeps the alpha
$p = Get-Px (Join-Path $out 'fmt.png') 5 5
Chk "$($p.A)" '0' 'PNG preserves transparency'
# red survives in all three
foreach ($e in @('.png', '.jpg', '.bmp')) {
    $p = Get-Px (Join-Path $out "fmt$e") 30 30
    Chk ($p.R -gt 200 -and $p.G -lt 60 -and $p.B -lt 60) $true "$e keeps the red"
}

# JPEG quality: 90 must weigh more than 40
$a = Join-Path $out 'q90.jpg'; $b = Join-Path $out 'q40.jpg'
$bmpq = New-Object System.Drawing.Bitmap((Join-Path $dir 'a.png'))
Save-CropBitmap -Bitmap $bmpq -Path $a -Format 'JPG' -JpegQuality 90
Save-CropBitmap -Bitmap $bmpq -Path $b -Format 'JPG' -JpegQuality 40
$bmpq.Dispose()
Chk ((Get-Item $a).Length -gt (Get-Item $b).Length) $true 'JPEG quality is really applied'

# no reference image means no division by zero
$r = Invoke-Crop -Path (Join-Path $dir 'a.png') -Region $region -RefWidth 0 -RefHeight 0 `
                 -OutPath (Join-Path $out 'nada.png') -BlackToAlpha $false -Tolerance 0
Chk $r.Ok 'False' 'no reference returns a controlled failure'
Chk $r.Message 'no reference image' 'and says so'

# originals are not left locked
try { Remove-Item (Join-Path $dir 'a.png') -Force; $script:pass++ }
catch { $script:fail++; "  FAIL  source file locked: $_" }

''
"PROCESSING RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
