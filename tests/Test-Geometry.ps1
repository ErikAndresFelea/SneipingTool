$ErrorActionPreference = 'Stop'
# Ruta al script bajo prueba, relativa a esta carpeta.
$src = [System.IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'SnipBatch.ps1')

# Parse
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { "PARSE: $($_.Message) (linea $($_.Extent.StartLineNumber))" }; exit 1 }
'PARSE OK'

# Cargar solo la logica (todo lo anterior a la ventana principal)
$text  = Get-Content $src -Raw
$logic = $text.Substring(0, $text.IndexOf('# --- Ventana principal'))
$tmp   = Join-Path $env:TEMP 'snipbatch_logic.ps1'
Set-Content -Path $tmp -Value $logic -Encoding UTF8
. $tmp

$script:pass = 0; $script:fail = 0
function Fmt($r) { "$($r.X),$($r.Y),$($r.Width),$($r.Height)" }
function Pt($x, $y) { New-Object System.Drawing.Point($x, $y) }
function Rc($x, $y, $w, $h) { New-Object System.Drawing.Rectangle($x, $y, $w, $h) }
function Chk($actual, $expected, $name) {
    if ("$actual" -eq "$expected") { $script:pass++ }
    else { $script:fail++; "  FALLO  $name : esperado <$expected>  obtenido <$actual>" }
}

# --- New-NormalizedRect ---
Chk (Fmt (New-NormalizedRect -L 10 -T 20 -R 60 -B 70 -MaxW 800 -MaxH 600)) '10,20,50,50' 'normal'
Chk (Fmt (New-NormalizedRect -L 60 -T 70 -R 10 -B 20 -MaxW 800 -MaxH 600)) '10,20,50,50' 'invertido'
Chk (Fmt (New-NormalizedRect -L -50 -T -50 -R 60 -B 70 -MaxW 800 -MaxH 600)) '0,0,60,70'  'recorta arriba/izq'
Chk (Fmt (New-NormalizedRect -L 700 -T 500 -R 999 -B 999 -MaxW 800 -MaxH 600)) '700,500,100,100' 'recorta abajo/der'
Chk (Fmt (New-NormalizedRect -L 900 -T 900 -R 950 -B 950 -MaxW 800 -MaxH 600)) '800,600,0,0' 'todo fuera -> vacio'
Chk (Fmt (New-NormalizedRect -L 40 -T 40 -R 40 -B 40 -MaxW 800 -MaxH 600)) '40,40,0,0' 'clic sin arrastrar'

# --- Get-HandlePoints ---
$hp = Get-HandlePoints (Rc 10 20 100 60)
Chk $hp.Count 8 'ocho tiradores'
Chk "$($hp.NW.X),$($hp.NW.Y)" '10,20'  'NW'
Chk "$($hp.SE.X),$($hp.SE.Y)" '110,80' 'SE'
Chk "$($hp.N.X),$($hp.N.Y)"   '60,20'  'N centrado'
Chk "$($hp.W.X),$($hp.W.Y)"   '10,50'  'W centrado'

# --- Get-HandleAt ---
$r = Rc 100 100 200 150
Chk (Get-HandleAt -Rect $r -Point (Pt 100 100)) 'NW' 'agarra NW exacto'
Chk (Get-HandleAt -Rect $r -Point (Pt 306 256)) 'SE' 'agarra SE con margen'
Chk (Get-HandleAt -Rect $r -Point (Pt 200 100)) 'N'  'agarra N'
Chk (Get-HandleAt -Rect $r -Point (Pt 200 175)) ''   'centro no es tirador'
Chk (Get-HandleAt -Rect $r -Point (Pt 320 270)) ''   'lejos no agarra'
Chk (Get-HandleAt -Rect (Rc 0 0 0 0) -Point (Pt 0 0)) '' 'rect vacio no agarra'

# --- Get-FlippedHandle ---
Chk (Get-FlippedHandle -Handle 'NW' -FlipX $true  -FlipY $false) 'NE' 'NW->NE'
Chk (Get-FlippedHandle -Handle 'NW' -FlipX $true  -FlipY $true)  'SE' 'NW->SE'
Chk (Get-FlippedHandle -Handle 'N'  -FlipX $true  -FlipY $false) 'N'  'N sin eje X'
Chk (Get-FlippedHandle -Handle 'SE' -FlipX $false -FlipY $true)  'NE' 'SE->NE'
Chk (Get-FlippedHandle -Handle 'E'  -FlipX $true  -FlipY $true)  'W'  'E->W'

# --- Get-ResizedRect ---
$r = Rc 100 100 200 150     # 100..300 x 100..250
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'SE' -Point (Pt 400 300) -MaxW 800 -MaxH 600).Rect) '100,100,300,200' 'SE agranda'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'NW' -Point (Pt 50 50)  -MaxW 800 -MaxH 600).Rect) '50,50,250,200'  'NW agranda'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'E'  -Point (Pt 400 999) -MaxW 800 -MaxH 600).Rect) '100,100,300,150' 'E solo toca ancho'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'N'  -Point (Pt 999 50)  -MaxW 800 -MaxH 600).Rect) '100,50,200,200'  'N solo toca alto'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'SE' -Point (Pt 900 700) -MaxW 800 -MaxH 600).Rect) '100,100,700,500' 'SE recorta al borde'
$flip = Get-ResizedRect -Rect $r -Handle 'SE' -Point (Pt 50 60) -MaxW 800 -MaxH 600
Chk (Fmt $flip.Rect)  '50,60,50,40' 'SE cruzado normaliza'
Chk $flip.Handle    'NW'          'SE cruzado pasa a NW'

# --- Get-MovedRect ---
$r = Rc 100 100 200 150
Chk (Fmt (Get-MovedRect -Rect $r -X 50  -Y 50  -MaxW 800 -MaxH 600)) '50,50,200,150'   'mueve libre'
Chk (Fmt (Get-MovedRect -Rect $r -X -50 -Y -50 -MaxW 800 -MaxH 600)) '0,0,200,150'     'tope arriba/izq'
Chk (Fmt (Get-MovedRect -Rect $r -X 999 -Y 999 -MaxW 800 -MaxH 600)) '600,450,200,150' 'tope abajo/der'

# --- Get-NudgedRect ---
$r = Rc 100 100 200 150
Chk (Fmt (Get-NudgedRect -Rect $r -Dx 1  -Dy 0  -Resize $false -MaxW 800 -MaxH 600)) '101,100,200,150' 'flecha +1'
Chk (Fmt (Get-NudgedRect -Rect $r -Dx 10 -Dy 10 -Resize $false -MaxW 800 -MaxH 600)) '110,110,200,150' 'Ctrl+flecha +10'
Chk (Fmt (Get-NudgedRect -Rect $r -Dx 1  -Dy 1  -Resize $true  -MaxW 800 -MaxH 600)) '100,100,201,151' 'Shift agranda'
Chk (Fmt (Get-NudgedRect -Rect $r -Dx -1 -Dy -1 -Resize $true  -MaxW 800 -MaxH 600)) '100,100,199,149' 'Shift encoge'
$tiny = Rc 100 100 1 1
Chk (Fmt (Get-NudgedRect -Rect $tiny -Dx -5 -Dy -5 -Resize $true -MaxW 800 -MaxH 600)) '100,100,0,0' 'Shift no invierte al encoger'
$edge = Rc 700 500 100 100
Chk (Fmt (Get-NudgedRect -Rect $edge -Dx 5 -Dy 5 -Resize $true -MaxW 800 -MaxH 600)) '700,500,100,100' 'Shift topa con el borde'

# --- Conversion pantalla <-> imagen ---
Chk (Fmt (ConvertTo-ScreenRect -Rect (Rc 40 60 200 150) -OffX 880 -OffY 420 -Scale 1.0)) '920,480,200,150' 'escala 1:1'
Chk (Fmt (ConvertTo-ScreenRect -Rect (Rc 40 60 200 150) -OffX 0 -OffY 0 -Scale 0.5))     '20,30,100,75'    'escala 0.5'
$p = ConvertTo-ImagePoint -Point (Pt 920 480) -OffX 880 -OffY 420 -Scale 1.0 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '40,60' 'pantalla->imagen 1:1'
$p = ConvertTo-ImagePoint -Point (Pt 20 30) -OffX 0 -OffY 0 -Scale 0.5 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '40,60' 'pantalla->imagen 0.5'
$p = ConvertTo-ImagePoint -Point (Pt -500 -500) -OffX 0 -OffY 0 -Scale 1.0 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '0,0' 'punto fuera se pega al borde'
$p = ConvertTo-ImagePoint -Point (Pt 9999 9999) -OffX 0 -OffY 0 -Scale 1.0 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '800,600' 'punto fuera se pega al borde opuesto'

# Ida y vuelta con imagen 4K vista en pantalla reducida: 1 flecha = 1 px real
$scale4k = 1440 / 2160
$rt = ConvertTo-ImagePoint -Point (ConvertTo-ScreenRect -Rect (Rc 1234 987 10 10) -OffX 100 -OffY 0 -Scale $scale4k).Location `
                           -OffX 100 -OffY 0 -Scale $scale4k -MaxW 3840 -MaxH 2160
Chk "$($rt.X),$($rt.Y)" '1234,987' 'ida y vuelta 4K sin deriva'

# --- Secuencia completa: dibujar, mover, teclas (lo que fallaba en el test de UI) ---
$sel = New-NormalizedRect -L 40 -T 60 -R 240 -B 210 -MaxW 800 -MaxH 600   # 200x150 @40,60
Chk (Fmt $sel) '40,60,200,150' 'seq: arrastre'
$off = Pt (140 - $sel.X) (135 - $sel.Y)
$sel = Get-MovedRect -Rect $sel -X (190 - $off.X) -Y (155 - $off.Y) -MaxW 800 -MaxH 600
Chk (Fmt $sel) '90,80,200,150' 'seq: mover'
$sel = Get-NudgedRect -Rect $sel -Dx 1 -Dy 0 -Resize $false -MaxW 800 -MaxH 600
$sel = Get-NudgedRect -Rect $sel -Dx 1 -Dy 0 -Resize $false -MaxW 800 -MaxH 600
$sel = Get-NudgedRect -Rect $sel -Dx 10 -Dy 0 -Resize $false -MaxW 800 -MaxH 600
Chk (Fmt $sel) '102,80,200,150' 'seq: flechas + Ctrl'
$sel = Get-NudgedRect -Rect $sel -Dx 1 -Dy 1 -Resize $true -MaxW 800 -MaxH 600
Chk (Fmt $sel) '102,80,201,151' 'seq: Shift redimensiona'

''
"RESULTADO GEOMETRIA: $script:pass OK, $script:fail fallos"
if ($script:fail -gt 0) { exit 1 }
