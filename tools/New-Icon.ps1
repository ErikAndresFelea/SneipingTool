# Draws SnipBatch.ico from scratch with GDI+: a stack of screenshots with the
# blue selection box of the overlay laid over the top one, which is the whole
# tool in one picture. Nothing to install, and the icon can be regenerated
# instead of being a binary nobody can edit.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\New-Icon.ps1
#
# -Preview also writes a PNG per size next to the icon, to look at the small
# ones before shipping them.

[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$PreviewDir = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not filled in yet while the parameter defaults are bound,
# so the default output path is worked out here instead.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Path -eq '') { $Path = Join-Path (Split-Path -Parent $here) 'SnipBatch.ico' }

Add-Type -AssemblyName System.Drawing

# Colours. The selection blue is the same one the overlay draws with, so the
# icon and the tool look like the same thing.
$C_SHEET  = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
$C_EDGE   = [System.Drawing.Color]::FromArgb(255, 132, 146, 163)
$C_BACK   = [System.Drawing.Color]::FromArgb(255, 205, 214, 226)
$C_SKY    = [System.Drawing.Color]::FromArgb(255, 214, 236, 250)
$C_SUN    = [System.Drawing.Color]::FromArgb(255, 255, 197, 77)
$C_HILL   = [System.Drawing.Color]::FromArgb(255,  76, 140, 107)
$C_HILL2  = [System.Drawing.Color]::FromArgb(255,  60, 116,  90)
$C_SEL    = [System.Drawing.Color]::FromArgb(255,   0, 160, 255)
$C_DIM    = [System.Drawing.Color]::FromArgb( 72,   8,  22,  38)

# A rounded rectangle as a path; every sheet and the photo clip use one.
function New-RoundRect {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)

    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    if ($d -le 0) {
        $p.AddRectangle((New-Object System.Drawing.RectangleF($X, $Y, $W, $H)))
        return $p
    }
    $p.AddArc([float]$X,           [float]$Y,           [float]$d, [float]$d, 180, 90)
    $p.AddArc([float]($X + $W - $d), [float]$Y,           [float]$d, [float]$d, 270, 90)
    $p.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), [float]$d, [float]$d,   0, 90)
    $p.AddArc([float]$X,           [float]($Y + $H - $d), [float]$d, [float]$d,  90, 90)
    $p.CloseFigure()
    return $p
}

# One frame. Everything is laid out on a 256 grid and scaled down, so the sizes
# stay in proportion; line widths are given in device pixels instead, or the
# 16 px frame would come out with hairlines that vanish.
function New-Frame {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size,
              [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode   = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.ScaleTransform(($Size / 256.0), ($Size / 256.0))

    $u = 256.0 / $Size          # one device pixel, in grid units

    # Detail has to go as the frame shrinks: at 16 px a stack of three sheets
    # with a sun in it is just grey mush.
    $level = if ($Size -ge 48) { 2 } elseif ($Size -ge 28) { 1 } else { 0 }

    $edgeW = [Math]::Max($u, 2.0)
    $selW  = [Math]::Max(2.0 * $u, 6.0)
    $radius = if ($level -eq 0) { 6.0 } else { 10.0 }

    $pw = 156.0   # sheet width
    $ph = 116.0   # sheet height

    $edgePen = New-Object System.Drawing.Pen($C_EDGE, [float]$edgeW)
    $backBr  = New-Object System.Drawing.SolidBrush($C_BACK)
    $sheetBr = New-Object System.Drawing.SolidBrush($C_SHEET)

    # The sheets behind: the batch. Drawn back to front.
    # A plain list: an array of pairs would be unrolled into loose numbers on
    # its way out of a switch or an @() wrapper.
    $offsets = New-Object System.Collections.ArrayList
    if ($level -eq 2) {
        [void]$offsets.Add(@(34.0, 52.0))
        [void]$offsets.Add(@(50.0, 70.0))
    } elseif ($level -eq 1) {
        [void]$offsets.Add(@(46.0, 62.0))
    }
    foreach ($o in $offsets) {
        $p = New-RoundRect -X $o[0] -Y $o[1] -W $pw -H $ph -R $radius
        $g.FillPath($backBr, $p)
        $g.DrawPath($edgePen, $p)
        $p.Dispose()
    }

    # The sheet on top: the screenshot being cropped.
    $fx = if ($level -eq 0) { 24.0 } elseif ($level -eq 1) { 62.0 } else { 66.0 }
    $fy = if ($level -eq 0) { 50.0 } elseif ($level -eq 1) { 78.0 } else { 88.0 }
    $fw = if ($level -eq 0) { 208.0 } else { $pw }
    $fh = if ($level -eq 0) { 156.0 } else { $ph }

    $front = New-RoundRect -X $fx -Y $fy -W $fw -H $fh -R $radius
    $g.FillPath($sheetBr, $front)

    # Its contents, clipped to the rounded sheet. Sun and hills read as "a
    # picture" at a glance far better than any abstract mark, and they are what
    # keeps the 16 px frame from looking like a plain blue box on white.
    $save = $g.Save()
    $g.SetClip($front)

    $skyBr = New-Object System.Drawing.SolidBrush($C_SKY)
    $g.FillRectangle($skyBr, [float]$fx, [float]$fy, [float]$fw, [float]$fh)
    $skyBr.Dispose()

    $sunR = $fw * 0.10
    $sunBr = New-Object System.Drawing.SolidBrush($C_SUN)
    $g.FillEllipse($sunBr, [float]($fx + $fw * 0.15), [float]($fy + $fh * 0.15),
                           [float]($sunR * 2), [float]($sunR * 2))
    $sunBr.Dispose()

    $baseY = $fy + $fh
    $hillBr = New-Object System.Drawing.SolidBrush($C_HILL)
    $pts = @(
        (New-Object System.Drawing.PointF([float]($fx - 4),          [float]$baseY)),
        (New-Object System.Drawing.PointF([float]($fx + $fw * 0.38), [float]($fy + $fh * 0.38))),
        (New-Object System.Drawing.PointF([float]($fx + $fw * 0.72), [float]$baseY))
    )
    $g.FillPolygon($hillBr, $pts)
    $hillBr.Dispose()

    $hill2Br = New-Object System.Drawing.SolidBrush($C_HILL2)
    $pts2 = @(
        (New-Object System.Drawing.PointF([float]($fx + $fw * 0.44), [float]$baseY)),
        (New-Object System.Drawing.PointF([float]($fx + $fw * 0.74), [float]($fy + $fh * 0.52))),
        (New-Object System.Drawing.PointF([float]($fx + $fw + 4),    [float]$baseY))
    )
    $g.FillPolygon($hill2Br, $pts2)
    $hill2Br.Dispose()

    $g.Restore($save)
    $g.DrawPath($edgePen, $front)

    # The selection: what the tool is actually for. Everything outside it on the
    # top sheet is dimmed, exactly like the overlay does while you drag.
    $sx = $fx + $fw * 0.18
    $sy = $fy + $fh * 0.20
    $sw = $fw * 0.62
    $sh = $fh * 0.60

    $outside = New-Object System.Drawing.Drawing2D.GraphicsPath
    $outside.AddPath($front, $false)
    $reg = New-Object System.Drawing.Region($outside)
    $reg.Exclude((New-Object System.Drawing.RectangleF([float]$sx, [float]$sy,
                                                       [float]$sw, [float]$sh)))
    $dimBr = New-Object System.Drawing.SolidBrush($C_DIM)
    $g.FillRegion($dimBr, $reg)
    $dimBr.Dispose(); $reg.Dispose(); $outside.Dispose()

    $selPen = New-Object System.Drawing.Pen($C_SEL, [float]$selW)
    $g.DrawRectangle($selPen, [float]$sx, [float]$sy, [float]$sw, [float]$sh)
    $selPen.Dispose()

    # Corner handles, the grips of the overlay. Dropped on the tiny frames,
    # where they would swallow the box they sit on.
    if ($level -ge 1) {
        $hs = [Math]::Max(3.2 * $u, 15.0)
        $selBr  = New-Object System.Drawing.SolidBrush($C_SEL)
        $whPen  = New-Object System.Drawing.Pen($C_SHEET, [float]([Math]::Max($u, 1.6)))
        foreach ($c in @(@($sx, $sy), @(($sx + $sw), $sy),
                         @($sx, ($sy + $sh)), @(($sx + $sw), ($sy + $sh)))) {
            $r = New-Object System.Drawing.RectangleF(
                    [float]($c[0] - $hs / 2), [float]($c[1] - $hs / 2),
                    [float]$hs, [float]$hs)
            $g.FillRectangle($selBr, $r)
            $g.DrawRectangle($whPen, $r.X, $r.Y, $r.Width, $r.Height)
        }
        $selBr.Dispose(); $whPen.Dispose()
    }

    $front.Dispose()
    $edgePen.Dispose(); $backBr.Dispose(); $sheetBr.Dispose()
    $g.Dispose()
    return $bmp
}

# A frame as a 32-bit DIB: the classic ICO payload. Rows run bottom-up and the
# AND mask is left at zero, since the alpha channel already carries the shape.
function ConvertTo-Dib {
    param([System.Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $rowLen = $w * 4
        $row = New-Object byte[] $rowLen
        $maskRow = [int][Math]::Floor((($w + 31) / 32)) * 4

        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)

        $bw.Write([uint32]40)          # biSize
        $bw.Write([int32]$w)           # biWidth
        $bw.Write([int32]($h * 2))     # biHeight: image plus mask
        $bw.Write([uint16]1)           # biPlanes
        $bw.Write([uint16]32)          # biBitCount
        $bw.Write([uint32]0)           # biCompression: BI_RGB
        $bw.Write([uint32]($rowLen * $h + $maskRow * $h))
        $bw.Write([int32]0); $bw.Write([int32]0)
        $bw.Write([uint32]0); $bw.Write([uint32]0)

        for ($y = $h - 1; $y -ge 0; $y--) {
            $src = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
            [System.Runtime.InteropServices.Marshal]::Copy($src, $row, 0, $rowLen)
            $bw.Write($row, 0, $rowLen)
        }
        $zeros = New-Object byte[] ($maskRow * $h)
        $bw.Write($zeros, 0, $zeros.Length)

        $bw.Flush()
        return $ms.ToArray()
    }
    finally { $Bitmap.UnlockBits($data) }
}

function ConvertTo-PngBytes {
    param([System.Drawing.Bitmap]$Bitmap)

    $ms = New-Object System.IO.MemoryStream
    $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return $ms.ToArray()
}

# The sizes Windows actually asks for, from the tree view up to the 256 the
# Extra large icons view and the Alt+Tab card use.
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)

$frames = @{}
$payloads = @{}
foreach ($s in $sizes) {
    $bmp = New-Frame -Size $s
    $frames[$s] = $bmp
    # PNG compression pays off on the big frames; the small ones stay DIB,
    # which every shell reader has understood since Windows 95.
    $payloads[$s] = if ($s -ge 64) { ConvertTo-PngBytes $bmp } else { ConvertTo-Dib $bmp }
}

$out = [System.IO.Path]::GetFullPath($Path)
$fs = [System.IO.File]::Create($out)
$bw = New-Object System.IO.BinaryWriter($fs)
try {
    $bw.Write([uint16]0)               # reserved
    $bw.Write([uint16]1)               # type: icon
    $bw.Write([uint16]$sizes.Count)

    $offset = 6 + 16 * $sizes.Count
    foreach ($s in $sizes) {
        $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
        $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
        $bw.Write([byte]0)             # palette entries
        $bw.Write([byte]0)             # reserved
        $bw.Write([uint16]1)           # planes
        $bw.Write([uint16]32)          # bits per pixel
        $bw.Write([uint32]$payloads[$s].Length)
        $bw.Write([uint32]$offset)
        $offset += $payloads[$s].Length
    }
    foreach ($s in $sizes) { $bw.Write($payloads[$s], 0, $payloads[$s].Length) }
    $bw.Flush()
}
finally { $bw.Dispose(); $fs.Dispose() }

if ($PreviewDir -ne '') {
    if (-not (Test-Path -LiteralPath $PreviewDir)) {
        New-Item -ItemType Directory -Path $PreviewDir | Out-Null
    }
    foreach ($s in $sizes) {
        $frames[$s].Save((Join-Path $PreviewDir ("icon-$s.png")),
                         [System.Drawing.Imaging.ImageFormat]::Png)
    }
}

foreach ($s in $sizes) { $frames[$s].Dispose() }

"Wrote $out ({0:N0} bytes, {1} sizes)" -f (Get-Item -LiteralPath $out).Length, $sizes.Count
