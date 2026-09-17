$ErrorActionPreference = 'Stop'
# Path to the script under test, relative to this folder.
$src = [System.IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'SnipBatch.ps1')

# Parse
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { "PARSE: $($_.Message) (line $($_.Extent.StartLineNumber))" }; exit 1 }
'PARSE OK'

# Load only the logic (everything before the main window)
$text  = Get-Content $src -Raw
$logic = $text.Substring(0, $text.IndexOf('# --- Main window'))
$tmp   = Join-Path $env:TEMP 'snipbatch_logic.ps1'
Set-Content -Path $tmp -Value $logic -Encoding UTF8
. $tmp

$script:pass = 0; $script:fail = 0
function Fmt($r) { "$($r.X),$($r.Y),$($r.Width),$($r.Height)" }
function Pt($x, $y) { New-Object System.Drawing.Point($x, $y) }
function Rc($x, $y, $w, $h) { New-Object System.Drawing.Rectangle($x, $y, $w, $h) }
function Chk($actual, $expected, $name) {
    if ("$actual" -eq "$expected") { $script:pass++ }
    else { $script:fail++; "  FAIL  $name : expected <$expected>  got <$actual>" }
}

# --- New-NormalizedRect ---
Chk (Fmt (New-NormalizedRect -L 10 -T 20 -R 60 -B 70 -MaxW 800 -MaxH 600)) '10,20,50,50' 'plain rectangle'
Chk (Fmt (New-NormalizedRect -L 60 -T 70 -R 10 -B 20 -MaxW 800 -MaxH 600)) '10,20,50,50' 'inverted corners'
Chk (Fmt (New-NormalizedRect -L -50 -T -50 -R 60 -B 70 -MaxW 800 -MaxH 600)) '0,0,60,70'  'clamps top/left'
Chk (Fmt (New-NormalizedRect -L 700 -T 500 -R 999 -B 999 -MaxW 800 -MaxH 600)) '700,500,100,100' 'clamps bottom/right'
Chk (Fmt (New-NormalizedRect -L 900 -T 900 -R 950 -B 950 -MaxW 800 -MaxH 600)) '800,600,0,0' 'entirely outside -> empty'
Chk (Fmt (New-NormalizedRect -L 40 -T 40 -R 40 -B 40 -MaxW 800 -MaxH 600)) '40,40,0,0' 'click without dragging'

# --- Get-HandlePoints ---
$hp = Get-HandlePoints (Rc 10 20 100 60)
Chk $hp.Count 8 'eight handles'
Chk "$($hp.NW.X),$($hp.NW.Y)" '10,20'  'NW'
Chk "$($hp.SE.X),$($hp.SE.Y)" '110,80' 'SE'
Chk "$($hp.N.X),$($hp.N.Y)"   '60,20'  'N is centred'
Chk "$($hp.W.X),$($hp.W.Y)"   '10,50'  'W is centred'

# --- Get-HandleAt ---
$r = Rc 100 100 200 150
Chk (Get-HandleAt -Rect $r -Point (Pt 100 100)) 'NW' 'grabs NW exactly'
Chk (Get-HandleAt -Rect $r -Point (Pt 306 256)) 'SE' 'grabs SE within the margin'
Chk (Get-HandleAt -Rect $r -Point (Pt 200 100)) 'N'  'grabs N'
Chk (Get-HandleAt -Rect $r -Point (Pt 200 175)) ''   'the centre is not a handle'
Chk (Get-HandleAt -Rect $r -Point (Pt 320 270)) ''   'far away grabs nothing'
Chk (Get-HandleAt -Rect (Rc 0 0 0 0) -Point (Pt 0 0)) '' 'empty rect grabs nothing'

# --- Get-FlippedHandle ---
Chk (Get-FlippedHandle -Handle 'NW' -FlipX $true  -FlipY $false) 'NE' 'NW->NE'
Chk (Get-FlippedHandle -Handle 'NW' -FlipX $true  -FlipY $true)  'SE' 'NW->SE'
Chk (Get-FlippedHandle -Handle 'N'  -FlipX $true  -FlipY $false) 'N'  'N has no X axis'
Chk (Get-FlippedHandle -Handle 'SE' -FlipX $false -FlipY $true)  'NE' 'SE->NE'
Chk (Get-FlippedHandle -Handle 'E'  -FlipX $true  -FlipY $true)  'W'  'E->W'

# --- Get-ResizedRect ---
$r = Rc 100 100 200 150     # 100..300 x 100..250
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'SE' -Point (Pt 400 300) -MaxW 800 -MaxH 600).Rect) '100,100,300,200' 'SE grows'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'NW' -Point (Pt 50 50)  -MaxW 800 -MaxH 600).Rect) '50,50,250,200'  'NW grows'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'E'  -Point (Pt 400 999) -MaxW 800 -MaxH 600).Rect) '100,100,300,150' 'E only affects width'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'N'  -Point (Pt 999 50)  -MaxW 800 -MaxH 600).Rect) '100,50,200,200'  'N only affects height'
Chk (Fmt (Get-ResizedRect -Rect $r -Handle 'SE' -Point (Pt 900 700) -MaxW 800 -MaxH 600).Rect) '100,100,700,500' 'SE clamps at the edge'
$flip = Get-ResizedRect -Rect $r -Handle 'SE' -Point (Pt 50 60) -MaxW 800 -MaxH 600
Chk (Fmt $flip.Rect)  '50,60,50,40' 'crossed SE normalises'
Chk $flip.Handle    'NW'          'crossed SE becomes NW'

# --- Get-MovedRect ---
$r = Rc 100 100 200 150
Chk (Fmt (Get-MovedRect -Rect $r -X 50  -Y 50  -MaxW 800 -MaxH 600)) '50,50,200,150'   'moves freely'
Chk (Fmt (Get-MovedRect -Rect $r -X -50 -Y -50 -MaxW 800 -MaxH 600)) '0,0,200,150'     'stops at top/left'
Chk (Fmt (Get-MovedRect -Rect $r -X 999 -Y 999 -MaxW 800 -MaxH 600)) '600,450,200,150' 'stops at bottom/right'

# --- Get-NudgedRect ---
$r = Rc 100 100 200 150
Chk (Fmt (Get-NudgedRect -Rect $r -Dx 1  -Dy 0  -Resize $false -MaxW 800 -MaxH 600)) '101,100,200,150' 'arrow +1'
Chk (Fmt (Get-NudgedRect -Rect $r -Dx 10 -Dy 10 -Resize $false -MaxW 800 -MaxH 600)) '110,110,200,150' 'Ctrl+arrow +10'
Chk (Fmt (Get-NudgedRect -Rect $r -Dx 1  -Dy 1  -Resize $true  -MaxW 800 -MaxH 600)) '100,100,201,151' 'Shift grows'
Chk (Fmt (Get-NudgedRect -Rect $r -Dx -1 -Dy -1 -Resize $true  -MaxW 800 -MaxH 600)) '100,100,199,149' 'Shift shrinks'
$tiny = Rc 100 100 1 1
Chk (Fmt (Get-NudgedRect -Rect $tiny -Dx -5 -Dy -5 -Resize $true -MaxW 800 -MaxH 600)) '100,100,0,0' 'Shift does not flip when shrinking'
$edge = Rc 700 500 100 100
Chk (Fmt (Get-NudgedRect -Rect $edge -Dx 5 -Dy 5 -Resize $true -MaxW 800 -MaxH 600)) '700,500,100,100' 'Shift stops at the edge'

# --- Screen <-> image conversion ---
Chk (Fmt (ConvertTo-ScreenRect -Rect (Rc 40 60 200 150) -OffX 880 -OffY 420 -Scale 1.0)) '920,480,200,150' '1:1 scale'
Chk (Fmt (ConvertTo-ScreenRect -Rect (Rc 40 60 200 150) -OffX 0 -OffY 0 -Scale 0.5))     '20,30,100,75'    '0.5 scale'
$p = ConvertTo-ImagePoint -Point (Pt 920 480) -OffX 880 -OffY 420 -Scale 1.0 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '40,60' 'screen->image 1:1'
$p = ConvertTo-ImagePoint -Point (Pt 20 30) -OffX 0 -OffY 0 -Scale 0.5 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '40,60' 'screen->image 0.5'
$p = ConvertTo-ImagePoint -Point (Pt -500 -500) -OffX 0 -OffY 0 -Scale 1.0 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '0,0' 'outside point sticks to the edge'
$p = ConvertTo-ImagePoint -Point (Pt 9999 9999) -OffX 0 -OffY 0 -Scale 1.0 -MaxW 800 -MaxH 600
Chk "$($p.X),$($p.Y)" '800,600' 'outside point sticks to the far edge'

# Round trip with a 4K image shown scaled down: 1 arrow = 1 real pixel
$scale4k = 1440 / 2160
$rt = ConvertTo-ImagePoint -Point (ConvertTo-ScreenRect -Rect (Rc 1234 987 10 10) -OffX 100 -OffY 0 -Scale $scale4k).Location `
                           -OffX 100 -OffY 0 -Scale $scale4k -MaxW 3840 -MaxH 2160
Chk "$($rt.X),$($rt.Y)" '1234,987' '4K round trip with no drift'

# --- Full sequence: draw, move, keys ---
$sel = New-NormalizedRect -L 40 -T 60 -R 240 -B 210 -MaxW 800 -MaxH 600   # 200x150 @40,60
Chk (Fmt $sel) '40,60,200,150' 'seq: drag'
$off = Pt (140 - $sel.X) (135 - $sel.Y)
$sel = Get-MovedRect -Rect $sel -X (190 - $off.X) -Y (155 - $off.Y) -MaxW 800 -MaxH 600
Chk (Fmt $sel) '90,80,200,150' 'seq: move'
$sel = Get-NudgedRect -Rect $sel -Dx 1 -Dy 0 -Resize $false -MaxW 800 -MaxH 600
$sel = Get-NudgedRect -Rect $sel -Dx 1 -Dy 0 -Resize $false -MaxW 800 -MaxH 600
$sel = Get-NudgedRect -Rect $sel -Dx 10 -Dy 0 -Resize $false -MaxW 800 -MaxH 600
Chk (Fmt $sel) '102,80,200,150' 'seq: arrows + Ctrl'
$sel = Get-NudgedRect -Rect $sel -Dx 1 -Dy 1 -Resize $true -MaxW 800 -MaxH 600
Chk (Fmt $sel) '102,80,201,151' 'seq: Shift resizes'

''
"GEOMETRY RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
