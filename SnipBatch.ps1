#requires -Version 5.0
<#
    SnipBatch - Recorte por lotes estilo "Recortes" de Windows
    Selecciona una region una vez y se aplica a todas las imagenes de una carpeta.
    Opcion: convertir el negro en transparente (como "definir color transparente" de Office).

    No necesita instalar nada: usa PowerShell 5.1 + .NET Framework incluidos en Windows.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# El lanzador oculta la consola, asi que un fallo al arrancar (politica de
# ejecucion, modo restringido, .NET incompleto) dejaria la herramienta sin
# abrirse y sin decir por que. Este trap lo cuenta en pantalla.
trap {
    Write-Error "SnipBatch: $($_.Exception.Message)"
    # SNIPBATCH_NODIALOG evita el dialogo modal cuando se ejecuta sin nadie
    # delante (pruebas, tareas programadas): ahi un modal colgaria el proceso.
    if (-not $env:SNIPBATCH_NODIALOG) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "SnipBatch no pudo arrancar:`n`n$($_.Exception.Message)",
            'SnipBatch', 'OK', 'Error')
    }
    break
}

# --- Helpers nativos -------------------------------------------------------
# El trabajo por pixel se hace en C# compilado al vuelo: en PowerShell puro
# un bucle sobre 8 millones de bytes tardaria decenas de segundos por imagen.
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class SnipBatchNative
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    public static void MakeDpiAware()
    {
        try { SetProcessDPIAware(); } catch { }
    }

    // Pone alpha = 0 en todo pixel cuyos canales R, G y B esten por debajo
    // de la tolerancia (negro puro = 0). El bitmap debe ser 32bpp ARGB.
    public static int BlackToAlpha(Bitmap bmp, int tolerance)
    {
        Rectangle rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        BitmapData data = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            int len = Math.Abs(data.Stride) * bmp.Height;
            byte[] buf = new byte[len];
            Marshal.Copy(data.Scan0, buf, 0, len);

            int hits = 0;
            for (int i = 0; i < len; i += 4)   // orden en memoria: B G R A
            {
                if (buf[i] <= tolerance && buf[i + 1] <= tolerance && buf[i + 2] <= tolerance)
                {
                    buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0;
                    hits++;
                }
            }

            Marshal.Copy(buf, 0, data.Scan0, len);
            return hits;
        }
        finally { bmp.UnlockBits(data); }
    }
}

// Form con doble buffer: DoubleBuffered es protegida y no se puede asignar
// desde PowerShell, asi que se activa aqui para que el overlay no parpadee.
public class BufferedForm : Form
{
    public BufferedForm()
    {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.OptimizedDoubleBuffer
                    | ControlStyles.AllPaintingInWmPaint
                    | ControlStyles.UserPaint, true);
    }

    // Sin esto las flechas se tratan como navegacion de dialogo y nunca
    // llegan a KeyDown, asi que no se podria afinar la seleccion al pixel.
    protected override bool IsInputKey(Keys keyData)
    {
        Keys k = keyData & Keys.KeyCode;
        if (k == Keys.Left || k == Keys.Right || k == Keys.Up || k == Keys.Down)
            return true;
        return base.IsInputKey(keyData);
    }
}
'@

[SnipBatchNative]::MakeDpiAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$EXTENSIONS = @('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.tif', '.tiff')

# Devuelve SIEMPRE un array. Ojo: "return @()" no vale, PowerShell desenrolla
# el array vacio y el llamante recibe $null; con Set-StrictMode, un $null.Count
# es excepcion, y una carpeta sin imagenes tumbaba el manejador de eventos.
# El operador coma envuelve el array para que llegue entero.
# Test-Path lanza excepcion si la UNIDAD no existe (un USB retirado, una unidad
# de red caida): no devuelve $false. Con ErrorActionPreference = Stop eso tumba
# la herramienta desde dentro de un manejador de eventos, asi que se envuelve.
function Test-FolderExists {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try   { return [bool](Test-Path -LiteralPath $Path -PathType Container) }
    catch { return $false }
}

function Get-ImageFiles {
    param([string]$Folder)
    $none = @()
    if ([string]::IsNullOrWhiteSpace($Folder))    { return ,$none }
    if (-not (Test-FolderExists $Folder))         { return ,$none }
    try {
        $found = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop |
                    Where-Object { $EXTENSIONS -contains $_.Extension.ToLowerInvariant() } |
                    Sort-Object Name)
        return ,$found
    }
    catch { return ,$none }   # carpeta sin permisos, unidad desconectada...
}

# Carga una imagen sin dejar el archivo bloqueado (Image.FromFile mantiene el handle abierto).
function Open-ImageNoLock {
    param([string]$Path)
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $stream = New-Object System.IO.MemoryStream(, $bytes)
    $img    = [System.Drawing.Image]::FromStream($stream)
    [pscustomobject]@{ Image = $img; Stream = $stream }
}

# --- Geometria de la seleccion ---------------------------------------------
# Todo se calcula en PIXELES DE LA IMAGEN, no de pantalla: asi las flechas
# mueven exactamente un pixel del recorte aunque la imagen se vea reducida,
# y no hay perdida por redondeo al convertir de un espacio a otro.
# Son funciones puras, sin UI, para poder probarlas sin abrir ventanas.

function New-NormalizedRect {
    param([int]$L, [int]$T, [int]$R, [int]$B, [int]$MaxW, [int]$MaxH)
    # El origen tambien se acota por arriba: un rectangulo entero fuera de la
    # imagen debe pegarse al borde, no quedarse en coordenadas imposibles.
    $x1 = [Math]::Min([Math]::Max([Math]::Min($L, $R), 0), $MaxW)
    $y1 = [Math]::Min([Math]::Max([Math]::Min($T, $B), 0), $MaxH)
    $x2 = [Math]::Min([Math]::Max($L, $R), $MaxW)
    $y2 = [Math]::Min([Math]::Max($T, $B), $MaxH)
    if ($x2 -lt $x1) { $x2 = $x1 }
    if ($y2 -lt $y1) { $y2 = $y1 }
    New-Object System.Drawing.Rectangle($x1, $y1, ($x2 - $x1), ($y2 - $y1))
}

function Get-HandlePoints {
    param([System.Drawing.Rectangle]$Rect)
    $cx = $Rect.Left + [int]($Rect.Width  / 2)
    $cy = $Rect.Top  + [int]($Rect.Height / 2)
    [ordered]@{
        'NW' = New-Object System.Drawing.Point($Rect.Left,  $Rect.Top)
        'N'  = New-Object System.Drawing.Point($cx,         $Rect.Top)
        'NE' = New-Object System.Drawing.Point($Rect.Right, $Rect.Top)
        'E'  = New-Object System.Drawing.Point($Rect.Right, $cy)
        'SE' = New-Object System.Drawing.Point($Rect.Right, $Rect.Bottom)
        'S'  = New-Object System.Drawing.Point($cx,         $Rect.Bottom)
        'SW' = New-Object System.Drawing.Point($Rect.Left,  $Rect.Bottom)
        'W'  = New-Object System.Drawing.Point($Rect.Left,  $cy)
    }
}

# Que tirador hay bajo el punto (todo en coordenadas de pantalla).
function Get-HandleAt {
    param([System.Drawing.Rectangle]$Rect, [System.Drawing.Point]$Point, [int]$Grab = 9)
    if ($Rect.Width -le 0 -or $Rect.Height -le 0) { return '' }
    foreach ($kv in (Get-HandlePoints $Rect).GetEnumerator()) {
        if ([Math]::Abs($Point.X - $kv.Value.X) -le $Grab -and
            [Math]::Abs($Point.Y - $kv.Value.Y) -le $Grab) { return $kv.Key }
    }
    return ''
}

function Get-CursorForHandle {
    param([string]$Handle)
    switch ($Handle) {
        'NW'    { [System.Windows.Forms.Cursors]::SizeNWSE }
        'SE'    { [System.Windows.Forms.Cursors]::SizeNWSE }
        'NE'    { [System.Windows.Forms.Cursors]::SizeNESW }
        'SW'    { [System.Windows.Forms.Cursors]::SizeNESW }
        'N'     { [System.Windows.Forms.Cursors]::SizeNS }
        'S'     { [System.Windows.Forms.Cursors]::SizeNS }
        'E'     { [System.Windows.Forms.Cursors]::SizeWE }
        'W'     { [System.Windows.Forms.Cursors]::SizeWE }
        default { [System.Windows.Forms.Cursors]::Cross }
    }
}

# Al cruzar el lado opuesto, el tirador pasa a ser el de enfrente.
function Get-FlippedHandle {
    param([string]$Handle, [bool]$FlipX, [bool]$FlipY)
    $h = $Handle
    if ($FlipX) { $h = $h.Replace('W', '#').Replace('E', 'W').Replace('#', 'E') }
    if ($FlipY) { $h = $h.Replace('N', '#').Replace('S', 'N').Replace('#', 'S') }
    return $h
}

function Get-ResizedRect {
    param(
        [System.Drawing.Rectangle]$Rect, [string]$Handle,
        [System.Drawing.Point]$Point, [int]$MaxW, [int]$MaxH
    )
    $l = $Rect.Left; $t = $Rect.Top; $r = $Rect.Right; $b = $Rect.Bottom
    switch ($Handle) {
        'NW' { $l = $Point.X; $t = $Point.Y }
        'N'  {                $t = $Point.Y }
        'NE' { $r = $Point.X; $t = $Point.Y }
        'E'  { $r = $Point.X }
        'SE' { $r = $Point.X; $b = $Point.Y }
        'S'  {                $b = $Point.Y }
        'SW' { $l = $Point.X; $b = $Point.Y }
        'W'  { $l = $Point.X }
    }
    [pscustomobject]@{
        Rect   = New-NormalizedRect -L $l -T $t -R $r -B $b -MaxW $MaxW -MaxH $MaxH
        Handle = Get-FlippedHandle -Handle $Handle -FlipX ($r -lt $l) -FlipY ($b -lt $t)
    }
}

# Mueve el rectangulo entero sin deformarlo, sin salirse de la imagen.
function Get-MovedRect {
    param([System.Drawing.Rectangle]$Rect, [int]$X, [int]$Y, [int]$MaxW, [int]$MaxH)
    $nx = [Math]::Max(0, [Math]::Min($X, $MaxW - $Rect.Width))
    $ny = [Math]::Max(0, [Math]::Min($Y, $MaxH - $Rect.Height))
    New-Object System.Drawing.Rectangle($nx, $ny, $Rect.Width, $Rect.Height)
}

function Get-NudgedRect {
    param(
        [System.Drawing.Rectangle]$Rect, [int]$Dx, [int]$Dy,
        [bool]$Resize, [int]$MaxW, [int]$MaxH
    )
    if ($Resize) {
        # El borde derecho/inferior nunca cruza al izquierdo/superior: al
        # encoger se queda en cero en vez de invertirse y crecer al reves.
        $r = [Math]::Max($Rect.Left, $Rect.Right  + $Dx)
        $b = [Math]::Max($Rect.Top,  $Rect.Bottom + $Dy)
        return (New-NormalizedRect -L $Rect.Left -T $Rect.Top -R $r -B $b -MaxW $MaxW -MaxH $MaxH)
    }
    return (Get-MovedRect -Rect $Rect -X ($Rect.X + $Dx) -Y ($Rect.Y + $Dy) -MaxW $MaxW -MaxH $MaxH)
}

function ConvertTo-ScreenRect {
    param([System.Drawing.Rectangle]$Rect, [int]$OffX, [int]$OffY, [double]$Scale)
    New-Object System.Drawing.Rectangle(
        ($OffX + [int][Math]::Round($Rect.X * $Scale)),
        ($OffY + [int][Math]::Round($Rect.Y * $Scale)),
        [int][Math]::Round($Rect.Width  * $Scale),
        [int][Math]::Round($Rect.Height * $Scale))
}

function ConvertTo-ImagePoint {
    param([System.Drawing.Point]$Point, [int]$OffX, [int]$OffY, [double]$Scale, [int]$MaxW, [int]$MaxH)
    $x = [int][Math]::Round(($Point.X - $OffX) / $Scale)
    $y = [int][Math]::Round(($Point.Y - $OffY) / $Scale)
    New-Object System.Drawing.Point(
        [Math]::Max(0, [Math]::Min($x, $MaxW)),
        [Math]::Max(0, [Math]::Min($y, $MaxH)))
}

# --- Formato de salida -----------------------------------------------------
# Solo PNG tiene canal alfa de verdad. BMP admite 32 bits con alfa pero casi
# ningun visor lo respeta, y JPEG no lo admite en absoluto, asi que ambos se
# aplanan sobre blanco antes de guardar: mejor eso que una transparencia que
# el usuario cree tener y aparece en negro al pegarla.
function Get-FormatInfo {
    param([string]$Name)
    switch ("$Name".ToUpperInvariant()) {
        'JPG' { return [pscustomobject]@{ Name = 'JPG'; Extension = '.jpg'
                    Format = [System.Drawing.Imaging.ImageFormat]::Jpeg; SupportsAlpha = $false } }
        'BMP' { return [pscustomobject]@{ Name = 'BMP'; Extension = '.bmp'
                    Format = [System.Drawing.Imaging.ImageFormat]::Bmp;  SupportsAlpha = $false } }
        default { return [pscustomobject]@{ Name = 'PNG'; Extension = '.png'
                    Format = [System.Drawing.Imaging.ImageFormat]::Png;  SupportsAlpha = $true } }
    }
}

function Save-CropBitmap {
    param(
        [System.Drawing.Bitmap]$Bitmap, [string]$Path,
        [string]$Format, [int]$JpegQuality = 90
    )
    $info = Get-FormatInfo $Format

    if ($info.SupportsAlpha) {
        $Bitmap.Save($Path, $info.Format)
        return
    }

    # Aplanado sobre blanco y a 24 bits: archivos mas pequenos y compatibles.
    $flat = New-Object System.Drawing.Bitmap($Bitmap.Width, $Bitmap.Height,
                [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($flat)
        $g.Clear([System.Drawing.Color]::White)
        $g.DrawImage($Bitmap, 0, 0, $Bitmap.Width, $Bitmap.Height)
        $g.Dispose()

        if ($info.Name -eq 'JPG') {
            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                        Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            if ($null -eq $codec) { $flat.Save($Path, $info.Format); return }
            # Sin esto GDI+ guarda a calidad 75 y las capturas con texto se ven sucias.
            $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
            try {
                $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                    [System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
                $flat.Save($Path, $codec, $ep)
            }
            finally { $ep.Dispose() }
        }
        else { $flat.Save($Path, $info.Format) }
    }
    finally { $flat.Dispose() }
}

# Dos archivos con el mismo nombre y distinta extension (shot.png y shot.jpg)
# generarian el mismo PNG de salida y uno pisaria al otro sin avisar.
function Get-UniqueName {
    param([string]$BaseName, [System.Collections.Generic.HashSet[string]]$Used)
    $name = $BaseName
    $i    = 2
    while ($Used.Contains($name.ToLowerInvariant())) {
        $name = "$BaseName ($i)"
        $i++
    }
    [void]$Used.Add($name.ToLowerInvariant())
    return $name
}

# --- Ventana de seleccion (overlay a pantalla completa) --------------------
# Se dibuja un rectangulo arrastrando. Al soltar el raton NO se confirma:
# queda ajustable con los 8 tiradores, se puede mover arrastrandolo por dentro
# y afinar con las flechas. Enter confirma, Esc cancela.
function Select-Region {
    param([System.Drawing.Image]$Image)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $imgW   = $Image.Width
    $imgH   = $Image.Height

    # La imagen se dibuja escalada para caber en pantalla, nunca ampliada.
    $scale = [Math]::Min($screen.Width / $imgW, $screen.Height / $imgH)
    if ($scale -gt 1) { $scale = 1.0 }
    # Con relaciones de aspecto extremas el redondeo puede dar 0 y Bitmap falla.
    $drawW = [Math]::Max(1, [int]($imgW * $scale))
    $drawH = [Math]::Max(1, [int]($imgH * $scale))
    $offX  = [int](($screen.Width  - $drawW) / 2)
    $offY  = [int](($screen.Height - $drawH) / 2)

    # Se reescala UNA vez: repetir la interpolacion en cada Paint hace que el
    # arrastre vaya a tirones con capturas grandes.
    $canvas = New-Object System.Drawing.Bitmap($drawW, $drawH, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $cg = [System.Drawing.Graphics]::FromImage($canvas)
    $cg.InterpolationMode = 'HighQualityBicubic'
    $cg.DrawImage($Image, (New-Object System.Drawing.Rectangle(0, 0, $drawW, $drawH)),
                  (New-Object System.Drawing.Rectangle(0, 0, $imgW, $imgH)),
                  [System.Drawing.GraphicsUnit]::Pixel)
    $cg.Dispose()

    $GRAB = 9   # radio de agarre de los tiradores, en px de pantalla

    $state = [pscustomobject]@{
        Mode    = 'idle'      # idle | drawing | moving | resizing
        Sel     = New-Object System.Drawing.Rectangle(0, 0, 0, 0)   # px de imagen
        Anchor  = New-Object System.Drawing.Point(0, 0)             # px de imagen
        Handle  = ''
        MoveOff = New-Object System.Drawing.Point(0, 0)
        Result  = $null
    }

    $toImg = { param($p) ConvertTo-ImagePoint -Point $p -OffX $offX -OffY $offY -Scale $scale -MaxW $imgW -MaxH $imgH }
    $toScr = { param($r) ConvertTo-ScreenRect -Rect $r -OffX $offX -OffY $offY -Scale $scale }

    $form = New-Object BufferedForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.Bounds          = $screen
    $form.TopMost         = $true
    $form.BackColor       = [System.Drawing.Color]::Black
    $form.Cursor          = [System.Windows.Forms.Cursors]::Cross
    $form.KeyPreview      = $true

    # Sin foco no llegan ni las flechas ni Esc, y el overlay se quedaria colgado.
    $form.Add_Shown({ $form.Activate(); [void]$form.Focus() })

    $confirm = {
        $sel = $state.Sel
        if ($sel.Width -lt 1 -or $sel.Height -lt 1) { return }
        $state.Result = $sel
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    }

    $form.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.DrawImageUnscaled($canvas, $offX, $offY)

        $sel  = & $toScr $state.Sel
        $veil = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(140, 0, 0, 0))
        $bg   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 0, 0, 0))

        if ($state.Sel.Width -gt 0 -and $state.Sel.Height -gt 0) {
            $region = New-Object System.Drawing.Region ($form.ClientRectangle)
            $region.Exclude($sel)
            $g.FillRegion($veil, $region)
            $region.Dispose()

            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 0, 160, 255)), 2
            $g.DrawRectangle($pen, $sel)
            $pen.Dispose()

            $hb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
            $hp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 0, 110, 190)), 1
            foreach ($kv in (Get-HandlePoints $sel).GetEnumerator()) {
                $hr = New-Object System.Drawing.Rectangle(($kv.Value.X - 4), ($kv.Value.Y - 4), 8, 8)
                $g.FillRectangle($hb, $hr)
                $g.DrawRectangle($hp, $hr)
            }
            $hb.Dispose(); $hp.Dispose()

            $txt  = "$($state.Sel.Width) x $($state.Sel.Height) px"
            $font = New-Object System.Drawing.Font ('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
            $sz   = $g.MeasureString($txt, $font)
            $ty   = if ($sel.Y -gt 26) { $sel.Y - 24 } else { $sel.Bottom + 6 }
            $g.FillRectangle($bg, $sel.X, $ty, ($sz.Width + 8), 20)
            $g.DrawString($txt, $font, [System.Drawing.Brushes]::White, ($sel.X + 4), ($ty + 2))
            $font.Dispose()
        }
        else {
            $g.FillRectangle($veil, $form.ClientRectangle)
        }

        $hint = if ($state.Sel.Width -gt 0) {
            'Ajusta con los tiradores  o  arrastra dentro para mover  -  flechas afinan (Ctrl = 10 px)  -  ENTER confirma  -  Esc cancela'
        } else {
            'Arrastra para seleccionar la region  -  Esc cancela'
        }
        $hf = New-Object System.Drawing.Font ('Segoe UI', 11)
        $hs = $g.MeasureString($hint, $hf)
        $hx = ($form.ClientSize.Width - $hs.Width) / 2
        $g.FillRectangle($bg, ($hx - 14), 22, ($hs.Width + 28), ($hs.Height + 12))
        $g.DrawString($hint, $hf, [System.Drawing.Brushes]::White, $hx, 28)
        $hf.Dispose()

        $veil.Dispose(); $bg.Dispose()
    })

    $form.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $selScr = & $toScr $state.Sel
        $p      = & $toImg $e.Location
        $h      = Get-HandleAt -Rect $selScr -Point $e.Location -Grab $GRAB

        if ($h -ne '') {
            $state.Mode   = 'resizing'
            $state.Handle = $h
        }
        elseif ($state.Sel.Width -gt 0 -and $state.Sel.Contains($p)) {
            $state.Mode    = 'moving'
            $state.MoveOff = New-Object System.Drawing.Point(($p.X - $state.Sel.X), ($p.Y - $state.Sel.Y))
        }
        else {
            $state.Mode   = 'drawing'
            $state.Anchor = $p
            $state.Sel    = New-NormalizedRect -L $p.X -T $p.Y -R $p.X -B $p.Y -MaxW $imgW -MaxH $imgH
        }
        $form.Invalidate()
    })

    $form.Add_MouseMove({
        param($s, $e)
        $p = & $toImg $e.Location

        switch ($state.Mode) {
            'drawing' {
                $state.Sel = New-NormalizedRect -L $state.Anchor.X -T $state.Anchor.Y `
                                                -R $p.X -B $p.Y -MaxW $imgW -MaxH $imgH
                $form.Invalidate()
            }
            'moving' {
                $state.Sel = Get-MovedRect -Rect $state.Sel `
                                           -X ($p.X - $state.MoveOff.X) -Y ($p.Y - $state.MoveOff.Y) `
                                           -MaxW $imgW -MaxH $imgH
                $form.Invalidate()
            }
            'resizing' {
                $res = Get-ResizedRect -Rect $state.Sel -Handle $state.Handle `
                                       -Point $p -MaxW $imgW -MaxH $imgH
                $state.Sel    = $res.Rect
                $state.Handle = $res.Handle
                $form.Invalidate()
            }
            default {
                $selScr = & $toScr $state.Sel
                $h = Get-HandleAt -Rect $selScr -Point $e.Location -Grab $GRAB
                if ($h -ne '') { $form.Cursor = Get-CursorForHandle $h }
                elseif ($state.Sel.Width -gt 0 -and $state.Sel.Contains($p)) {
                    $form.Cursor = [System.Windows.Forms.Cursors]::SizeAll
                }
                else { $form.Cursor = [System.Windows.Forms.Cursors]::Cross }
            }
        }
    })

    # Al soltar solo termina el gesto: la seleccion queda viva para ajustarla.
    $form.Add_MouseUp({
        param($s, $e)
        if ($state.Mode -eq 'drawing' -and
            ($state.Sel.Width -lt 2 -or $state.Sel.Height -lt 2)) {
            $state.Sel = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
        }
        $state.Mode = 'idle'
        $form.Invalidate()
    })

    $form.Add_MouseDoubleClick({
        param($s, $e)
        $p = & $toImg $e.Location
        if ($state.Sel.Width -gt 0 -and $state.Sel.Contains($p)) { & $confirm }
    })

    $form.Add_KeyDown({
        param($s, $e)

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
            return
        }
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -or
            $e.KeyCode -eq [System.Windows.Forms.Keys]::Space) {
            & $confirm
            return
        }
        if ($state.Sel.Width -le 0) { return }

        $step = if ($e.Control) { 10 } else { 1 }
        $dx = 0; $dy = 0
        switch ($e.KeyCode) {
            ([System.Windows.Forms.Keys]::Left)  { $dx = -$step }
            ([System.Windows.Forms.Keys]::Right) { $dx =  $step }
            ([System.Windows.Forms.Keys]::Up)    { $dy = -$step }
            ([System.Windows.Forms.Keys]::Down)  { $dy =  $step }
            default { return }
        }
        $e.Handled = $true

        # Shift = redimensionar por el borde derecho / inferior
        $state.Sel = Get-NudgedRect -Rect $state.Sel -Dx $dx -Dy $dy `
                                    -Resize ([bool]$e.Shift) -MaxW $imgW -MaxH $imgH
        $form.Invalidate()
    })

    try   { [void]$form.ShowDialog() }
    finally {
        $form.Dispose()
        $canvas.Dispose()
    }
    return $state.Result
}

# --- Procesado -------------------------------------------------------------
function Invoke-Crop {
    param(
        [string]$Path,
        [System.Drawing.Rectangle]$Region,
        [int]$RefWidth,
        [int]$RefHeight,
        [string]$OutPath,
        [bool]$BlackToAlpha,
        [int]$Tolerance,
        [string]$Format = 'PNG'
    )

    if ($RefWidth -le 0 -or $RefHeight -le 0) {
        return [pscustomobject]@{ Ok = $false; Message = 'sin imagen de referencia' }
    }

    $loaded = Open-ImageNoLock -Path $Path
    try {
        $img = $loaded.Image
        $r   = $Region

        # Si la imagen no mide lo mismo que la de referencia, la region se
        # reescala proporcionalmente en vez de fallar.
        $scaled = $false
        if ($img.Width -ne $RefWidth -or $img.Height -ne $RefHeight) {
            $sx = $img.Width  / [double]$RefWidth
            $sy = $img.Height / [double]$RefHeight
            $r  = New-Object System.Drawing.Rectangle(
                [int][Math]::Round($r.X * $sx), [int][Math]::Round($r.Y * $sy),
                [int][Math]::Round($r.Width * $sx), [int][Math]::Round($r.Height * $sy))
            $scaled = $true
        }

        # Recorte a los limites reales de esta imagen
        $x = [Math]::Max(0, $r.X); $y = [Math]::Max(0, $r.Y)
        $w = [Math]::Min($r.Width,  $img.Width  - $x)
        $h = [Math]::Min($r.Height, $img.Height - $y)
        if ($w -le 0 -or $h -le 0) {
            return [pscustomobject]@{ Ok = $false; Message = 'la region queda fuera de la imagen' }
        }

        $dest = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $g = [System.Drawing.Graphics]::FromImage($dest)
            $g.PixelOffsetMode    = 'HighQuality'
            $g.InterpolationMode  = 'NearestNeighbor'   # recorte 1:1, sin suavizar
            $g.CompositingMode    = 'SourceCopy'
            $srcRect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
            $dstRect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
            $g.DrawImage($img, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
            $g.Dispose()

            if ($BlackToAlpha) {
                [void][SnipBatchNative]::BlackToAlpha($dest, $Tolerance)
            }

            Save-CropBitmap -Bitmap $dest -Path $OutPath -Format $Format

            $msg = "$w x $h"
            if ($scaled) { $msg += ' (region reescalada)' }
            return [pscustomobject]@{ Ok = $true; Message = $msg }
        }
        finally { $dest.Dispose() }
    }
    finally {
        $loaded.Image.Dispose()
        $loaded.Stream.Dispose()
    }
}

# --- Ventana principal -----------------------------------------------------
$ui = [pscustomobject]@{
    Folder    = ''
    OutFolder = ''      # vacio = automatica: <origen>\recortadas
    Region    = $null
    RefWidth  = 0
    RefHeight = 0
    Busy      = $false
    Stop      = $false
    WantAlpha = $false   # lo que el usuario marco, para restaurarlo al volver a PNG
}

# La carpeta de salida es explicita: por defecto una subcarpeta del origen,
# pero se puede apuntar a cualquier sitio para no tocar la carpeta original.
# Join-Path consulta el proveedor de PowerShell y lanza DriveNotFoundException
# si la unidad ya no esta (USB retirado, unidad de red caida). Path::Combine es
# manipulacion de cadenas pura y nunca falla por eso.
function Resolve-OutFolder {
    if (-not [string]::IsNullOrWhiteSpace($ui.OutFolder)) { return $ui.OutFolder }
    if ([string]::IsNullOrWhiteSpace($ui.Folder)) { return '' }
    return [System.IO.Path]::Combine($ui.Folder, 'recortadas')
}

$main = New-Object System.Windows.Forms.Form
$main.Text            = 'SnipBatch - recorte por lotes'
$main.Size            = New-Object System.Drawing.Size(620, 590)
$main.StartPosition   = 'CenterScreen'
$main.FormBorderStyle = 'FixedSingle'
$main.MaximizeBox     = $false
$main.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text     = '1. Carpeta con las imagenes'
$lblFolder.Location = New-Object System.Drawing.Point(14, 14)
$lblFolder.AutoSize = $true

$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(14, 36)
$txtFolder.Size     = New-Object System.Drawing.Size(480, 24)
$txtFolder.ReadOnly = $true

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text     = 'Examinar...'
$btnFolder.Location = New-Object System.Drawing.Point(500, 35)
$btnFolder.Size     = New-Object System.Drawing.Size(90, 25)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Location  = New-Object System.Drawing.Point(14, 64)
$lblCount.Size      = New-Object System.Drawing.Size(576, 18)
$lblCount.ForeColor = [System.Drawing.Color]::DimGray
$lblCount.Text      = 'Sin carpeta seleccionada.'

$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text     = '2. Carpeta donde guardar los recortes'
$lblOut.Location = New-Object System.Drawing.Point(14, 90)
$lblOut.AutoSize = $true

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(14, 112)
$txtOut.Size     = New-Object System.Drawing.Size(390, 24)
$txtOut.ReadOnly = $true

$btnOut = New-Object System.Windows.Forms.Button
$btnOut.Text     = 'Examinar...'
$btnOut.Location = New-Object System.Drawing.Point(410, 111)
$btnOut.Size     = New-Object System.Drawing.Size(85, 25)

$btnOutReset = New-Object System.Windows.Forms.Button
$btnOutReset.Text     = 'Predeterminada'
$btnOutReset.Location = New-Object System.Drawing.Point(500, 111)
$btnOutReset.Size     = New-Object System.Drawing.Size(90, 25)

$lblOutHint = New-Object System.Windows.Forms.Label
$lblOutHint.Location  = New-Object System.Drawing.Point(14, 140)
$lblOutHint.Size      = New-Object System.Drawing.Size(576, 18)
$lblOutHint.ForeColor = [System.Drawing.Color]::DimGray
$lblOutHint.Text      = 'Por defecto: subcarpeta "recortadas" dentro del origen. Se crea sola si no existe.'

$btnRegion = New-Object System.Windows.Forms.Button
$btnRegion.Text     = '3. Seleccionar region...'
$btnRegion.Location = New-Object System.Drawing.Point(14, 166)
$btnRegion.Size     = New-Object System.Drawing.Size(180, 32)
$btnRegion.Enabled  = $false

$lblRegion = New-Object System.Windows.Forms.Label
$lblRegion.Location  = New-Object System.Drawing.Point(204, 174)
$lblRegion.Size      = New-Object System.Drawing.Size(386, 20)
$lblRegion.ForeColor = [System.Drawing.Color]::DimGray
$lblRegion.Text      = 'Ninguna region definida.'

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text     = 'Opciones'
$grp.Location = New-Object System.Drawing.Point(14, 208)
$grp.Size     = New-Object System.Drawing.Size(576, 106)

$lblFmt = New-Object System.Windows.Forms.Label
$lblFmt.Text     = 'Formato de salida:'
$lblFmt.Location = New-Object System.Drawing.Point(14, 25)
$lblFmt.AutoSize = $true

$cmbFormat = New-Object System.Windows.Forms.ComboBox
$cmbFormat.Location      = New-Object System.Drawing.Point(140, 21)
$cmbFormat.Size          = New-Object System.Drawing.Size(80, 24)
$cmbFormat.DropDownStyle = 'DropDownList'
[void]$cmbFormat.Items.AddRange(@('PNG', 'JPG', 'BMP'))
$cmbFormat.SelectedIndex = 0

$lblFmtHint = New-Object System.Windows.Forms.Label
$lblFmtHint.Location  = New-Object System.Drawing.Point(232, 25)
$lblFmtHint.Size      = New-Object System.Drawing.Size(330, 18)
$lblFmtHint.ForeColor = [System.Drawing.Color]::DimGray

$chkAlpha = New-Object System.Windows.Forms.CheckBox
$chkAlpha.Text     = 'Convertir el negro en transparente'
$chkAlpha.Location = New-Object System.Drawing.Point(14, 50)
$chkAlpha.Size     = New-Object System.Drawing.Size(240, 22)

$lblTol = New-Object System.Windows.Forms.Label
$lblTol.Text     = 'Tolerancia (0 = negro puro):'
$lblTol.Location = New-Object System.Drawing.Point(14, 78)
$lblTol.AutoSize = $true

$numTol = New-Object System.Windows.Forms.NumericUpDown
$numTol.Location = New-Object System.Drawing.Point(180, 75)
$numTol.Size     = New-Object System.Drawing.Size(60, 24)
$numTol.Minimum  = 0
$numTol.Maximum  = 255
$numTol.Value    = 12
$numTol.Enabled  = $false

$lblTolHint = New-Object System.Windows.Forms.Label
$lblTolHint.Text      = 'sube si quedan bordes oscuros'
$lblTolHint.Location  = New-Object System.Drawing.Point(250, 78)
$lblTolHint.AutoSize  = $true
$lblTolHint.ForeColor = [System.Drawing.Color]::DimGray

$grp.Controls.AddRange(@($lblFmt, $cmbFormat, $lblFmtHint, $chkAlpha, $lblTol, $numTol, $lblTolHint))

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text     = '4. Procesar todas'
$btnRun.Location = New-Object System.Drawing.Point(14, 324)
$btnRun.Size     = New-Object System.Drawing.Size(180, 34)
$btnRun.Enabled  = $false

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(204, 330)
$progress.Size     = New-Object System.Drawing.Size(386, 22)

$log = New-Object System.Windows.Forms.TextBox
$log.Location   = New-Object System.Drawing.Point(14, 368)
$log.Size       = New-Object System.Drawing.Size(576, 172)
$log.Multiline  = $true
$log.ReadOnly   = $true
$log.ScrollBars = 'Vertical'
$log.BackColor  = [System.Drawing.Color]::White
$log.Font       = New-Object System.Drawing.Font('Consolas', 8.5)

$main.Controls.AddRange(@($lblFolder, $txtFolder, $btnFolder, $lblCount,
                          $lblOut, $txtOut, $btnOut, $btnOutReset, $lblOutHint,
                          $btnRegion, $lblRegion, $grp, $btnRun, $progress, $log))

function Write-Log {
    param([string]$Text)
    $log.AppendText($Text + [Environment]::NewLine)
}

function Update-OutBox {
    $txtOut.Text = Resolve-OutFolder
    if ([string]::IsNullOrWhiteSpace($ui.OutFolder)) {
        $lblOutHint.Text = 'Por defecto: subcarpeta "recortadas" dentro del origen. Se crea sola si no existe.'
    }
    else {
        $lblOutHint.Text = 'Carpeta de salida fija. "Predeterminada" vuelve a la subcarpeta del origen.'
    }
}

function Update-RunState {
    $btnRun.Enabled = ($null -ne $ui.Region) -and ((Get-ImageFiles $ui.Folder).Count -gt 0)
}

# JPG y BMP no llevan alfa: en vez de perder la transparencia en silencio, la
# casilla se deshabilita y se recuerda la eleccion para cuando se vuelva a PNG.
function Update-FormatState {
    $info = Get-FormatInfo $cmbFormat.SelectedItem
    if ($info.SupportsAlpha) {
        $chkAlpha.Enabled = $true
        $chkAlpha.Checked = $ui.WantAlpha
        $lblFmtHint.Text  = 'PNG conserva la transparencia.'
    }
    else {
        # Deshabilitar ANTES de desmarcar: si no, el evento pisaria WantAlpha.
        $chkAlpha.Enabled = $false
        $chkAlpha.Checked = $false
        $lblFmtHint.Text  = "$($info.Name) no admite transparencia: se guarda opaco sobre blanco."
    }
    $numTol.Enabled = $chkAlpha.Checked
}

$chkAlpha.Add_CheckedChanged({
    if ($chkAlpha.Enabled) { $ui.WantAlpha = $chkAlpha.Checked }
    $numTol.Enabled = $chkAlpha.Checked
})

$cmbFormat.Add_SelectedIndexChanged({ Update-FormatState })

# Separado del manejador para poder probarlo sin abrir el dialogo de carpetas.
function Set-SourceFolder {
    param([string]$Path)

    $ui.Folder      = $Path
    $txtFolder.Text = $Path
    $ui.Region      = $null      # la region vieja no vale para otras capturas
    $ui.RefWidth    = 0
    $ui.RefHeight   = 0
    $lblRegion.Text = 'Ninguna region definida.'
    $lblRegion.ForeColor = [System.Drawing.Color]::DimGray

    $files = Get-ImageFiles $Path
    if ($files.Count -eq 0) {
        $lblCount.Text     = 'No hay imagenes compatibles en esa carpeta.'
        $btnRegion.Enabled = $false
    }
    else {
        $lblCount.Text     = "$($files.Count) imagen(es) encontradas. Referencia: $($files[0].Name)"
        $btnRegion.Enabled = $true
    }
    Update-OutBox
    Update-RunState
}

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Carpeta con las capturas'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Set-SourceFolder -Path $dlg.SelectedPath
})

$btnOut.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Carpeta donde guardar los recortes'
    $dlg.ShowNewFolderButton = $true
    $current = Resolve-OutFolder
    if (Test-FolderExists $current) { $dlg.SelectedPath = $current }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $ui.OutFolder = $dlg.SelectedPath
    Update-OutBox
})

$btnOutReset.Add_Click({
    $ui.OutFolder = ''
    Update-OutBox
})

$btnRegion.Add_Click({
    $files = Get-ImageFiles $ui.Folder
    if ($files.Count -eq 0) { return }

    $region = $null
    $loaded = Open-ImageNoLock -Path $files[0].FullName
    try {
        $ui.RefWidth  = $loaded.Image.Width
        $ui.RefHeight = $loaded.Image.Height
        $main.WindowState = 'Minimized'
        $region = Select-Region -Image $loaded.Image
    }
    finally {
        $loaded.Image.Dispose()
        $loaded.Stream.Dispose()
        $main.WindowState = 'Normal'
        $main.Activate()
    }

    if ($null -eq $region) {
        Write-Log 'Seleccion cancelada.'
        return
    }

    $ui.Region = $region
    $lblRegion.Text = "Region: $($region.Width) x $($region.Height) px  en  X=$($region.X), Y=$($region.Y)"
    $lblRegion.ForeColor = [System.Drawing.Color]::Black
    Write-Log "Region definida sobre $($files[0].Name) ($($ui.RefWidth)x$($ui.RefHeight)): $($region.Width)x$($region.Height) @ $($region.X),$($region.Y)"
    Update-RunState
})

$btnRun.Add_Click({
    $files = Get-ImageFiles $ui.Folder
    if ($files.Count -eq 0 -or $null -eq $ui.Region) { return }

    $outFolder = Resolve-OutFolder

    # Guardar en la propia carpeta de origen pisaria los PNG originales.
    $mismaCarpeta = $false
    try {
        $mismaCarpeta = ([System.IO.Path]::GetFullPath($ui.Folder).TrimEnd([char]92) -eq
                         [System.IO.Path]::GetFullPath($outFolder).TrimEnd([char]92))
    }
    catch { $mismaCarpeta = $false }   # ruta rara: se sigue, el guardado ya avisara
    if ($mismaCarpeta) {
        $warn = [System.Windows.Forms.MessageBox]::Show(
            ("La carpeta de salida es la misma que la de origen.`n`nLos recortes se guardan con el mismo nombre y extension {0}, asi que cualquier original de esa carpeta con ese nombre quedara sobrescrito y no se podra recuperar.`n`nContinuar de todas formas?" -f (Get-FormatInfo $cmbFormat.SelectedItem).Extension),
            'SnipBatch - cuidado', 'YesNo', 'Warning', 'Button2')
        if ($warn -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Cancelado: la salida apuntaba a la carpeta de origen.'
            return
        }
    }

    try {
        if (-not (Test-FolderExists $outFolder)) {
            [void](New-Item -ItemType Directory -Path $outFolder -Force)
        }
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "No se pudo crear la carpeta de salida:`n$outFolder`n`n$($_.Exception.Message)",
            'SnipBatch', 'OK', 'Error')
        return
    }

    $btnRun.Enabled = $false; $btnRegion.Enabled = $false
    $btnFolder.Enabled = $false; $btnOut.Enabled = $false; $btnOutReset.Enabled = $false
    $progress.Value   = 0
    $progress.Maximum = $files.Count
    Write-Log ''
    Write-Log "--- Procesando $($files.Count) imagen(es) en $((Get-FormatInfo $cmbFormat.SelectedItem).Name) -> $outFolder"

    $ok = 0; $fail = 0
    $fmt  = Get-FormatInfo $cmbFormat.SelectedItem
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    $ui.Busy = $true
    $ui.Stop = $false
    try {
        foreach ($f in $files) {
            if ($ui.Stop) { Write-Log '--- Interrumpido por el usuario.'; break }
            try {
                $base = Get-UniqueName -Used $used `
                            -BaseName ([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
                $r = Invoke-Crop -Path $f.FullName -Region $ui.Region `
                                 -RefWidth $ui.RefWidth -RefHeight $ui.RefHeight `
                                 -OutPath ([System.IO.Path]::Combine($outFolder, "$base$($fmt.Extension)")) `
                                 -BlackToAlpha $chkAlpha.Checked -Tolerance ([int]$numTol.Value) `
                                 -Format $fmt.Name
                if ($r.Ok) { $ok++;   Write-Log ("  OK    {0}  [{1}]" -f $f.Name, $r.Message) }
                else       { $fail++; Write-Log ("  SALTA {0}  [{1}]" -f $f.Name, $r.Message) }
            }
            catch {
                $fail++
                Write-Log ("  ERROR {0}  [{1}]" -f $f.Name, $_.Exception.Message)
            }
            $progress.Value = [Math]::Min($progress.Value + 1, $progress.Maximum)
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    finally { $ui.Busy = $false }

    Write-Log "--- Listo: $ok correcta(s), $fail con problemas."
    $btnRun.Enabled = $true; $btnRegion.Enabled = $true
    $btnFolder.Enabled = $true; $btnOut.Enabled = $true; $btnOutReset.Enabled = $true

    # Si cerraron la ventana a mitad, ahora se cierra de verdad, sin mas dialogos.
    if ($ui.Stop) { $main.Close(); return }

    if ($ok -gt 0) {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "$ok imagen(es) guardadas en:`n$outFolder`n`nAbrir la carpeta?",
            'SnipBatch', 'YesNo', 'Information')
        if ($ask -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Sin comillas, una ruta con espacios llega partida y explorer abre otra cosa.
            Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $outFolder)
        }
    }
})

# DoEvents permite seguir usando la ventana mientras se procesa: si la cierran
# a mitad, el bucle seguiria escribiendo en controles ya destruidos.
$main.Add_FormClosing({
    param($s, $e)
    if ($ui.Busy) {
        $ui.Stop  = $true
        $e.Cancel = $true
    }
})

Write-Log 'SnipBatch listo.'
Write-Log '1) Carpeta de origen  2) Carpeta de salida  3) Region  4) Procesar.'
Write-Log 'En la seleccion: arrastra, ajusta con los tiradores y pulsa ENTER para confirmar.'

Update-OutBox
Update-FormatState
[void]$main.ShowDialog()
$main.Dispose()
