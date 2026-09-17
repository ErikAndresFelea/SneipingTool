#requires -Version 5.0
<#
    SnipBatch - Batch cropping in the style of the Windows Snipping Tool.
    Pick a region once and it is applied to every image in a folder.
    Option: turn black into transparency (like Office's "set transparent color").

    Nothing to install: uses the PowerShell 5.1 + .NET Framework shipped with Windows.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# The launcher hides the console, so a startup failure (execution policy,
# constrained language mode, incomplete .NET) would leave the tool never
# opening and never saying why. This trap reports it on screen.
trap {
    Write-Error "SnipBatch: $($_.Exception.Message)"
    # SNIPBATCH_NODIALOG skips the modal dialog when running unattended
    # (tests, scheduled tasks): a modal there would hang the process forever.
    if (-not $env:SNIPBATCH_NODIALOG) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "SnipBatch could not start:`n`n$($_.Exception.Message)",
            'SnipBatch', 'OK', 'Error')
    }
    break
}

# --- Native helpers --------------------------------------------------------
# Per-pixel work is done in C# compiled on the fly: in plain PowerShell a loop
# over 8 million bytes would take tens of seconds per image.
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
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

    // Sets alpha = 0 on every pixel whose R, G and B channels are all below
    // the tolerance (pure black = 0). The bitmap must be 32bpp ARGB.
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
            for (int i = 0; i < len; i += 4)   // memory order: B G R A
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

// Explorer-style folder picker. FolderBrowserDialog is the old tree: no address
// bar, no typing or pasting a path, no Quick access, and it always starts the
// walk from the top. This is the very dialog Explorer uses (IFileDialog with
// FOS_PICKFOLDERS), shipped with Windows since Vista, so nothing to install.
// SetFolder reopens it where the caller was, and the client GUID makes Windows
// remember that place between runs of the tool.
public static class SnipBatchFolder
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogRCW { }

    // Only the methods actually called carry a real signature; the rest are
    // placeholders that keep the vtable slots in order.
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes();
        void SetFileTypeIndex();
        void GetFileTypeIndex();
        void Advise();
        void Unadvise();
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName();
        void GetFileName();
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel();
        void SetFileNameLabel();
        void GetResult(out IShellItem item);
        void AddPlace();
        void SetDefaultExtension();
        void Close();
        void SetClientGuid(ref Guid guid);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler();
        void GetParent();
        void GetDisplayName(uint sigdn, out IntPtr name);
        void GetAttributes();
        void Compare();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bindCtx,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    private const uint FOS_PICKFOLDERS     = 0x00000020;
    private const uint FOS_FORCEFILESYSTEM = 0x00000040;   // no libraries or virtual folders
    private const uint FOS_PATHMUSTEXIST   = 0x00000800;
    private const uint FOS_NOCHANGEDIR     = 0x00000008;   // keep the process CWD
    private const uint SIGDN_FILESYSPATH   = 0x80058000;

    // Returns the chosen path, or null when the user cancels.
    public static string Pick(IntPtr owner, string title, string startAt, string clientGuid)
    {
        IFileDialog dlg = (IFileDialog)new FileOpenDialogRCW();
        try
        {
            uint options;
            dlg.GetOptions(out options);
            dlg.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM
                                   | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);

            if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
            if (!string.IsNullOrEmpty(clientGuid))
            {
                Guid g = new Guid(clientGuid);
                dlg.SetClientGuid(ref g);
            }

            bool exists = false;
            try { exists = !string.IsNullOrEmpty(startAt) && Directory.Exists(startAt); }
            catch { }   // dropped drive: just open wherever Windows remembers
            if (exists)
            {
                IShellItem start = null;
                try
                {
                    SHCreateItemFromParsingName(startAt, IntPtr.Zero, typeof(IShellItem).GUID, out start);
                    if (start != null) dlg.SetFolder(start);
                }
                catch { }
                finally { if (start != null) Marshal.ReleaseComObject(start); }
            }

            if (dlg.Show(owner) != 0) return null;   // 0x800704C7 = cancelled

            IShellItem result;
            dlg.GetResult(out result);
            IntPtr buf = IntPtr.Zero;
            try
            {
                result.GetDisplayName(SIGDN_FILESYSPATH, out buf);
                return Marshal.PtrToStringUni(buf);
            }
            finally
            {
                if (buf != IntPtr.Zero) Marshal.FreeCoTaskMem(buf);
                Marshal.ReleaseComObject(result);
            }
        }
        finally { Marshal.ReleaseComObject(dlg); }
    }
}

// Double-buffered form: DoubleBuffered is protected and cannot be assigned
// from PowerShell, so it is enabled here to keep the overlay from flickering.
public class BufferedForm : Form
{
    public BufferedForm()
    {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.OptimizedDoubleBuffer
                    | ControlStyles.AllPaintingInWmPaint
                    | ControlStyles.UserPaint, true);
    }

    // Without this the arrow keys are treated as dialog navigation and never
    // reach KeyDown, so the selection could not be nudged pixel by pixel.
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

# ALWAYS returns an array. Careful: "return @()" does not work, PowerShell
# unrolls the empty array and the caller gets $null; under Set-StrictMode a
# $null.Count throws, and a folder with no images crashed the event handler.
# The comma operator wraps the array so it arrives intact.
# Test-Path throws if the DRIVE does not exist (an unplugged USB stick, a
# dropped network drive): it does not return $false. With ErrorActionPreference
# = Stop that kills the tool from inside an event handler, so it is wrapped.
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
    catch { return ,$none }   # no permissions, disconnected drive...
}

# Loads an image without locking the file (Image.FromFile keeps the handle open).
function Open-ImageNoLock {
    param([string]$Path)
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $stream = New-Object System.IO.MemoryStream(, $bytes)
    $img    = [System.Drawing.Image]::FromStream($stream)
    [pscustomobject]@{ Image = $img; Stream = $stream }
}

# --- Selection geometry ----------------------------------------------------
# Everything is computed in IMAGE PIXELS, not screen pixels: that way the arrow
# keys move exactly one pixel of the crop even when the image is displayed
# scaled down, and nothing is lost to rounding between the two spaces.
# These are pure functions, no UI, so they can be tested without opening windows.

function New-NormalizedRect {
    param([int]$L, [int]$T, [int]$R, [int]$B, [int]$MaxW, [int]$MaxH)
    # The origin is clamped at the top end too: a rectangle entirely outside the
    # image must stick to the edge, not sit at impossible coordinates.
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

# Which handle sits under the point (all in screen coordinates).
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

# When dragged past the opposite side, the handle becomes the facing one.
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

# Moves the whole rectangle without reshaping it, kept inside the image.
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
        # The right/bottom edge never crosses the left/top one: when shrinking
        # it stops at zero instead of flipping and growing the other way.
        $r = [Math]::Max($Rect.Left, $Rect.Right  + $Dx)
        $b = [Math]::Max($Rect.Top,  $Rect.Bottom + $Dy)
        return (New-NormalizedRect -L $Rect.Left -T $Rect.Top -R $r -B $b -MaxW $MaxW -MaxH $MaxH)
    }
    return (Get-MovedRect -Rect $Rect -X ($Rect.X + $Dx) -Y ($Rect.Y + $Dy) -MaxW $MaxW -MaxH $MaxH)
}

# Where the image lands on screen for a given zoom. Smaller than the window it
# is centred; bigger, it is pinned so the requested centre stays visible and no
# empty margin ever shows. The centre is returned back already clamped, so the
# caller can keep panning from where it really ended up.
function Get-ViewPort {
    param(
        [double]$Zoom, [int]$ImgW, [int]$ImgH,
        [int]$ViewW, [int]$ViewH,
        [double]$CenterX, [double]$CenterY
    )
    $drawW = [Math]::Max(1, [int][Math]::Round($ImgW * $Zoom))
    $drawH = [Math]::Max(1, [int][Math]::Round($ImgH * $Zoom))

    if ($drawW -le $ViewW) {
        $offX = [int](($ViewW - $drawW) / 2)
        $cx   = $ImgW / 2.0
    }
    else {
        $offX = [int][Math]::Round($ViewW / 2.0 - $CenterX * $Zoom)
        if ($offX -gt 0)               { $offX = 0 }
        if ($offX -lt $ViewW - $drawW) { $offX = $ViewW - $drawW }
        $cx = ($ViewW / 2.0 - $offX) / $Zoom
    }

    if ($drawH -le $ViewH) {
        $offY = [int](($ViewH - $drawH) / 2)
        $cy   = $ImgH / 2.0
    }
    else {
        $offY = [int][Math]::Round($ViewH / 2.0 - $CenterY * $Zoom)
        if ($offY -gt 0)               { $offY = 0 }
        if ($offY -lt $ViewH - $drawH) { $offY = $ViewH - $drawH }
        $cy = ($ViewH / 2.0 - $offY) / $Zoom
    }

    [pscustomobject]@{
        OffX = $offX; OffY = $offY
        DrawW = $drawW; DrawH = $drawH
        CenterX = $cx; CenterY = $cy
    }
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

# --- Output format ---------------------------------------------------------
# Only PNG has a real alpha channel. BMP allows 32-bit with alpha but almost no
# viewer honours it, and JPEG has none at all, so both are flattened onto white
# before saving: better that than transparency the user believes they have and
# which shows up black once pasted.
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

    # Flattened onto white at 24 bits: smaller and more compatible files.
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
            # Without this GDI+ saves at quality 75 and text in screenshots smears.
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

# Two files sharing a name with different extensions (shot.png and shot.jpg)
# would produce the same output file and one would silently overwrite the other.
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

# --- Selection window (full-screen overlay) --------------------------------
# The rectangle is drawn by dragging. Releasing the mouse does NOT confirm it:
# it stays adjustable through the 8 handles, can be moved by dragging from
# inside, and nudged with the arrow keys. Enter confirms, Esc cancels.
function Select-Region {
    param([System.Drawing.Image]$Image)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $imgW   = $Image.Width
    $imgH   = $Image.Height

    # The image starts scaled to fit the screen, never enlarged. That fit is
    # also the zoom floor: zooming out past it would only add empty margin.
    $fitScale = [Math]::Min($screen.Width / $imgW, $screen.Height / $imgH)
    if ($fitScale -gt 1) { $fitScale = 1.0 }
    $MAXZOOM = 16.0
    # With extreme aspect ratios the rounding can reach 0 and Bitmap throws.
    $drawW = [Math]::Max(1, [int]($imgW * $fitScale))
    $drawH = [Math]::Max(1, [int]($imgH * $fitScale))

    # Rescaled ONCE: redoing the interpolation on every Paint makes dragging
    # stutter with large screenshots. Only the fit view is cached; zoomed in,
    # Paint redraws just the visible slice of the original, which is small.
    $canvas = New-Object System.Drawing.Bitmap($drawW, $drawH, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $cg = [System.Drawing.Graphics]::FromImage($canvas)
    $cg.InterpolationMode = 'HighQualityBicubic'
    $cg.DrawImage($Image, (New-Object System.Drawing.Rectangle(0, 0, $drawW, $drawH)),
                  (New-Object System.Drawing.Rectangle(0, 0, $imgW, $imgH)),
                  [System.Drawing.GraphicsUnit]::Pixel)
    $cg.Dispose()

    $GRAB   = 9     # grab radius of the handles, in screen px
    # 144 = 18 image px at 8x, an exact fit: any other pairing would leave a
    # dead band down two sides of the box.
    $LSIZE  = 144   # side of the magnifier, in screen px
    $LZOOM  = 8     # screen px per image px inside the magnifier

    $state = [pscustomobject]@{
        Mode    = 'idle'      # idle | drawing | moving | resizing | panning
        Sel     = New-Object System.Drawing.Rectangle(0, 0, 0, 0)   # image px
        Anchor  = New-Object System.Drawing.Point(0, 0)             # image px
        Handle  = ''
        MoveOff = New-Object System.Drawing.Point(0, 0)
        Result  = $null
        # View: Zoom is screen px per image px, Off* where image (0,0) lands
        # (negative once zoomed past the window), Center* the image point held
        # at the middle of the window while panning.
        Zoom    = $fitScale
        OffX    = [int](($screen.Width  - $drawW) / 2)
        OffY    = [int](($screen.Height - $drawH) / 2)
        CenterX = $imgW / 2.0
        CenterY = $imgH / 2.0
        PanFrom = New-Object System.Drawing.Point(0, 0)   # screen px
        PanCX   = 0.0
        PanCY   = 0.0
        Loupe   = $true
        Cursor  = New-Object System.Drawing.Point(-1, -1)
        HasCur  = $false
    }

    $toImg = { param($p) ConvertTo-ImagePoint -Point $p -OffX $state.OffX -OffY $state.OffY -Scale $state.Zoom -MaxW $imgW -MaxH $imgH }
    $toScr = { param($r) ConvertTo-ScreenRect -Rect $r -OffX $state.OffX -OffY $state.OffY -Scale $state.Zoom }

    # Applies a zoom + centre pair to the view, clamped by Get-ViewPort.
    $setView = {
        param([double]$zoom, [double]$cx, [double]$cy)
        if ($zoom -lt $fitScale) { $zoom = $fitScale }
        if ($zoom -gt $MAXZOOM)  { $zoom = $MAXZOOM }
        $vp = Get-ViewPort -Zoom $zoom -ImgW $imgW -ImgH $imgH `
                           -ViewW $screen.Width -ViewH $screen.Height -CenterX $cx -CenterY $cy
        $state.Zoom    = $zoom
        $state.OffX    = $vp.OffX
        $state.OffY    = $vp.OffY
        $state.CenterX = $vp.CenterX
        $state.CenterY = $vp.CenterY
    }

    # Zooms keeping the image point under the given screen point pinned there,
    # which is what makes wheel zoom feel like it homes in on the detail.
    $zoomAt = {
        param([double]$zoom, [System.Drawing.Point]$anchor)
        if ($zoom -lt $fitScale) { $zoom = $fitScale }
        if ($zoom -gt $MAXZOOM)  { $zoom = $MAXZOOM }
        $ix = ($anchor.X - $state.OffX) / $state.Zoom
        $iy = ($anchor.Y - $state.OffY) / $state.Zoom
        $cx = $ix + ($screen.Width  / 2.0 - $anchor.X) / $zoom
        $cy = $iy + ($screen.Height / 2.0 - $anchor.Y) / $zoom
        & $setView $zoom $cx $cy
    }

    $form = New-Object BufferedForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.Bounds          = $screen
    $form.TopMost         = $true
    $form.BackColor       = [System.Drawing.Color]::Black
    $form.Cursor          = [System.Windows.Forms.Cursors]::Cross
    $form.KeyPreview      = $true

    # Without focus neither the arrows nor Esc arrive, and the overlay would hang.
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

        if ($state.Zoom -le $fitScale + 1e-9) {
            $g.DrawImageUnscaled($canvas, $state.OffX, $state.OffY)
        }
        else {
            # Only the visible slice is resampled; one extra pixel of margin so
            # no seam shows at the edges after rounding.
            $sx = [Math]::Max(0, [int][Math]::Floor((0 - $state.OffX) / $state.Zoom) - 1)
            $sy = [Math]::Max(0, [int][Math]::Floor((0 - $state.OffY) / $state.Zoom) - 1)
            $sw = [Math]::Min($imgW - $sx, [int][Math]::Ceiling($screen.Width  / $state.Zoom) + 3)
            $sh = [Math]::Min($imgH - $sy, [int][Math]::Ceiling($screen.Height / $state.Zoom) + 3)
            if ($sw -gt 0 -and $sh -gt 0) {
                $dest = New-Object System.Drawing.Rectangle(
                    ($state.OffX + [int][Math]::Round($sx * $state.Zoom)),
                    ($state.OffY + [int][Math]::Round($sy * $state.Zoom)),
                    [int][Math]::Round($sw * $state.Zoom),
                    [int][Math]::Round($sh * $state.Zoom))
                $src = New-Object System.Drawing.Rectangle($sx, $sy, $sw, $sh)
                # Zoomed in the point is to see the actual pixels, so no blur.
                $g.InterpolationMode = 'NearestNeighbor'
                $g.PixelOffsetMode   = 'Half'
                $g.DrawImage($Image, $dest, $src, [System.Drawing.GraphicsUnit]::Pixel)
                $g.InterpolationMode = 'Default'
                $g.PixelOffsetMode   = 'Default'
            }
        }

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
            'Drag the handles to resize  or  drag inside to move  -  arrows nudge (Ctrl = 10 px)  -  ENTER confirms  -  Esc cancels'
        } else {
            'Drag to select the region  -  Esc cancels'
        }
        $zoomPct = [int][Math]::Round($state.Zoom * 100)
        $hint2 = "Wheel zooms ($zoomPct%)  -  right-drag or middle-drag pans  -  0 fits, 1 is 100%  -  M toggles the magnifier"

        $hf  = New-Object System.Drawing.Font ('Segoe UI', 11)
        $hf2 = New-Object System.Drawing.Font ('Segoe UI', 9)
        $hs  = $g.MeasureString($hint,  $hf)
        $hs2 = $g.MeasureString($hint2, $hf2)
        $hw  = [Math]::Max($hs.Width, $hs2.Width)
        $hx  = ($form.ClientSize.Width - $hw) / 2
        $g.FillRectangle($bg, ($hx - 14), 22, ($hw + 28), ($hs.Height + $hs2.Height + 14))
        $g.DrawString($hint,  $hf,  [System.Drawing.Brushes]::White,
                      ($hx + ($hw - $hs.Width) / 2), 28)
        $g.DrawString($hint2, $hf2, ([System.Drawing.Brushes]::LightSkyBlue),
                      ($hx + ($hw - $hs2.Width) / 2), (28 + $hs.Height))
        $hf.Dispose(); $hf2.Dispose()

        # --- magnifier ------------------------------------------------------
        # Shows the pixels around the cursor at 1:LZOOM with the edges of the
        # selection drawn in, which is what lets an edge be placed on the exact
        # pixel even when the whole image is displayed scaled down.
        if ($state.Loupe -and $state.HasCur -and $state.Mode -ne 'panning') {
            $ip   = & $toImg $state.Cursor
            $span = [int]($LSIZE / $LZOOM)              # image px covered
            $half = [int]($span / 2)
            $lx = $state.Cursor.X + 26
            $ly = $state.Cursor.Y + 26
            if ($lx + $LSIZE + 8 -gt $form.ClientSize.Width)  { $lx = $state.Cursor.X - 26 - $LSIZE }
            if ($ly + $LSIZE + 30 -gt $form.ClientSize.Height) { $ly = $state.Cursor.Y - 26 - $LSIZE - 22 }
            if ($lx -lt 8) { $lx = 8 }
            if ($ly -lt 8) { $ly = 8 }

            $box = New-Object System.Drawing.Rectangle($lx, $ly, $LSIZE, $LSIZE)
            $g.FillRectangle($bg, $box)

            # Clamped to the image: past its edges the box just stays dark
            # instead of GDI stretching the border pixels over it.
            $sx0 = [Math]::Max(0, $ip.X - $half)
            $sy0 = [Math]::Max(0, $ip.Y - $half)
            $sx1 = [Math]::Min($imgW, $ip.X - $half + $span)
            $sy1 = [Math]::Min($imgH, $ip.Y - $half + $span)
            if ($sx1 -gt $sx0 -and $sy1 -gt $sy0) {
                $ldest = New-Object System.Drawing.Rectangle(
                    ($lx + ($sx0 - ($ip.X - $half)) * $LZOOM),
                    ($ly + ($sy0 - ($ip.Y - $half)) * $LZOOM),
                    (($sx1 - $sx0) * $LZOOM), (($sy1 - $sy0) * $LZOOM))
                $lsrc = New-Object System.Drawing.Rectangle($sx0, $sy0, ($sx1 - $sx0), ($sy1 - $sy0))
                $gsave = $g.Save()
                $g.SetClip($box)
                $g.InterpolationMode = 'NearestNeighbor'
                $g.PixelOffsetMode   = 'Half'
                $g.DrawImage($Image, $ldest, $lsrc, [System.Drawing.GraphicsUnit]::Pixel)
                $g.InterpolationMode = 'Default'
                $g.PixelOffsetMode   = 'Default'

                # The selection, mapped into the magnifier.
                if ($state.Sel.Width -gt 0 -and $state.Sel.Height -gt 0) {
                    $sp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 0, 160, 255)), 2
                    $g.DrawRectangle($sp,
                        ($lx + ($state.Sel.X - ($ip.X - $half)) * $LZOOM),
                        ($ly + ($state.Sel.Y - ($ip.Y - $half)) * $LZOOM),
                        ($state.Sel.Width * $LZOOM), ($state.Sel.Height * $LZOOM))
                    $sp.Dispose()
                }

                # Crosshair on the pixel under the cursor, which sits at the
                # centre of the magnifier by construction.
                $cxp = $lx + $half * $LZOOM
                $cyp = $ly + $half * $LZOOM
                $cp  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(180, 255, 80, 80)), 1
                $g.DrawLine($cp, $lx, ($cyp + $LZOOM / 2), ($lx + $LSIZE), ($cyp + $LZOOM / 2))
                $g.DrawLine($cp, ($cxp + $LZOOM / 2), $ly, ($cxp + $LZOOM / 2), ($ly + $LSIZE))
                $g.DrawRectangle($cp, $cxp, $cyp, $LZOOM, $LZOOM)
                $cp.Dispose()
                $g.Restore($gsave)
            }

            $lp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 230, 230, 230)), 1
            $g.DrawRectangle($lp, $box)
            $lp.Dispose()

            $lf  = New-Object System.Drawing.Font ('Segoe UI', 8)
            $txt = "X=$($ip.X)  Y=$($ip.Y)"
            $g.FillRectangle($bg, $lx, ($ly + $LSIZE + 2), $LSIZE, 18)
            $g.DrawString($txt, $lf, [System.Drawing.Brushes]::White, ($lx + 4), ($ly + $LSIZE + 3))
            $lf.Dispose()
        }

        $veil.Dispose(); $bg.Dispose()
    })

    $form.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -or
            $e.Button -eq [System.Windows.Forms.MouseButtons]::Middle) {
            # Panning only makes sense once the image is bigger than the window,
            # and never in the middle of a left-button gesture.
            if ($state.Mode -eq 'idle' -and $state.Zoom -gt $fitScale + 1e-9) {
                $state.Mode    = 'panning'
                $state.PanFrom = $e.Location
                $state.PanCX   = $state.CenterX
                $state.PanCY   = $state.CenterY
                $form.Cursor   = [System.Windows.Forms.Cursors]::SizeAll
                $form.Invalidate()
            }
            return
        }
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
        $state.Cursor = $e.Location
        $state.HasCur = $true

        switch ($state.Mode) {
            'panning' {
                & $setView $state.Zoom `
                           ($state.PanCX - ($e.X - $state.PanFrom.X) / $state.Zoom) `
                           ($state.PanCY - ($e.Y - $state.PanFrom.Y) / $state.Zoom)
                $form.Invalidate()
            }
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
                # The magnifier follows the cursor, so it needs a repaint even
                # when nothing is being dragged.
                if ($state.Loupe) { $form.Invalidate() }
            }
        }
    })

    # Releasing only ends the gesture: the selection stays live for adjusting.
    $form.Add_MouseUp({
        param($s, $e)
        if ($state.Mode -eq 'drawing' -and
            ($state.Sel.Width -lt 2 -or $state.Sel.Height -lt 2)) {
            $state.Sel = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
        }
        if ($state.Mode -eq 'panning') { $form.Cursor = [System.Windows.Forms.Cursors]::Cross }
        $state.Mode = 'idle'
        $form.Invalidate()
    })

    # Wheel zooms around the cursor; the selection lives in image pixels, so it
    # survives the zoom untouched even mid-drag.
    $form.Add_MouseWheel({
        param($s, $e)
        $step = if ($e.Delta -gt 0) { 1.25 } else { 1 / 1.25 }
        $new  = $state.Zoom * $step
        # Snap back to the exact fit instead of stopping just above it.
        if ($new -lt $fitScale * 1.02) { $new = $fitScale }
        if ([Math]::Abs($new - $state.Zoom) -lt 1e-9) { return }
        & $zoomAt $new $e.Location
        $form.Invalidate()
    })

    $form.Add_MouseLeave({
        $state.HasCur = $false
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

        # --- view keys, useful with or without a selection ---
        $anchor = if ($state.HasCur) { $state.Cursor }
                  else { New-Object System.Drawing.Point(([int]($screen.Width / 2)), ([int]($screen.Height / 2))) }
        switch ($e.KeyCode) {
            { $_ -eq [System.Windows.Forms.Keys]::D0 -or $_ -eq [System.Windows.Forms.Keys]::NumPad0 } {
                & $setView $fitScale ($imgW / 2.0) ($imgH / 2.0)
                $e.Handled = $true; $form.Invalidate(); return
            }
            { $_ -eq [System.Windows.Forms.Keys]::D1 -or $_ -eq [System.Windows.Forms.Keys]::NumPad1 } {
                # 100%: centred on the selection if there is one, else on the cursor.
                if ($state.Sel.Width -gt 0) {
                    & $setView 1.0 ($state.Sel.X + $state.Sel.Width / 2.0) ($state.Sel.Y + $state.Sel.Height / 2.0)
                } else {
                    & $zoomAt 1.0 $anchor
                }
                $e.Handled = $true; $form.Invalidate(); return
            }
            { $_ -eq [System.Windows.Forms.Keys]::Oemplus -or $_ -eq [System.Windows.Forms.Keys]::Add } {
                & $zoomAt ($state.Zoom * 1.25) $anchor
                $e.Handled = $true; $form.Invalidate(); return
            }
            { $_ -eq [System.Windows.Forms.Keys]::OemMinus -or $_ -eq [System.Windows.Forms.Keys]::Subtract } {
                $z = $state.Zoom / 1.25
                if ($z -lt $fitScale * 1.02) { $z = $fitScale }
                & $zoomAt $z $anchor
                $e.Handled = $true; $form.Invalidate(); return
            }
            ([System.Windows.Forms.Keys]::M) {
                $state.Loupe = -not $state.Loupe
                $e.Handled = $true; $form.Invalidate(); return
            }
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

        # Shift = resize from the right / bottom edge
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

# --- Processing ------------------------------------------------------------
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
        return [pscustomobject]@{ Ok = $false; Message = 'no reference image' }
    }

    $loaded = Open-ImageNoLock -Path $Path
    try {
        $img = $loaded.Image
        $r   = $Region

        # If the image does not match the reference size, the region is scaled
        # proportionally instead of failing.
        $scaled = $false
        if ($img.Width -ne $RefWidth -or $img.Height -ne $RefHeight) {
            $sx = $img.Width  / [double]$RefWidth
            $sy = $img.Height / [double]$RefHeight
            $r  = New-Object System.Drawing.Rectangle(
                [int][Math]::Round($r.X * $sx), [int][Math]::Round($r.Y * $sy),
                [int][Math]::Round($r.Width * $sx), [int][Math]::Round($r.Height * $sy))
            $scaled = $true
        }

        # Clamped to this image's actual bounds
        $x = [Math]::Max(0, $r.X); $y = [Math]::Max(0, $r.Y)
        $w = [Math]::Min($r.Width,  $img.Width  - $x)
        $h = [Math]::Min($r.Height, $img.Height - $y)
        if ($w -le 0 -or $h -le 0) {
            return [pscustomobject]@{ Ok = $false; Message = 'region falls outside this image' }
        }

        $dest = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $g = [System.Drawing.Graphics]::FromImage($dest)
            $g.PixelOffsetMode    = 'HighQuality'
            $g.InterpolationMode  = 'NearestNeighbor'   # 1:1 crop, no smoothing
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
            if ($scaled) { $msg += ' (region rescaled)' }
            return [pscustomobject]@{ Ok = $true; Message = $msg }
        }
        finally { $dest.Dispose() }
    }
    finally {
        $loaded.Image.Dispose()
        $loaded.Stream.Dispose()
    }
}

# --- Main window -----------------------------------------------------------
$ui = [pscustomobject]@{
    Folder    = ''
    OutFolder = ''      # empty = automatic: <source>\crops
    Region    = $null
    RefWidth  = 0
    RefHeight = 0
    Busy      = $false
    Stop      = $false
    WantAlpha = $false   # what the user ticked, to restore when going back to PNG
    LastDir   = ''       # last folder browsed to, so the next dialog starts there
}

# The output folder is explicit: a subfolder of the source by default, but it
# can point anywhere so the original folder is never touched.
# Join-Path queries the PowerShell provider and throws DriveNotFoundException if
# the drive is gone (unplugged USB, dropped network drive). Path::Combine is
# pure string manipulation and never fails for that reason.
function Resolve-OutFolder {
    if (-not [string]::IsNullOrWhiteSpace($ui.OutFolder)) { return $ui.OutFolder }
    if ([string]::IsNullOrWhiteSpace($ui.Folder)) { return '' }
    return [System.IO.Path]::Combine($ui.Folder, 'crops')
}

$main = New-Object System.Windows.Forms.Form
$main.Text            = 'SnipBatch - batch crop'
$main.Size            = New-Object System.Drawing.Size(620, 590)
$main.StartPosition   = 'CenterScreen'
$main.FormBorderStyle = 'FixedSingle'
$main.MaximizeBox     = $false
$main.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text     = '1. Source folder'
$lblFolder.Location = New-Object System.Drawing.Point(14, 14)
$lblFolder.AutoSize = $true

$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(14, 36)
$txtFolder.Size     = New-Object System.Drawing.Size(480, 24)
$txtFolder.ReadOnly = $true

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text     = 'Browse...'
$btnFolder.Location = New-Object System.Drawing.Point(500, 35)
$btnFolder.Size     = New-Object System.Drawing.Size(90, 25)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Location  = New-Object System.Drawing.Point(14, 64)
$lblCount.Size      = New-Object System.Drawing.Size(576, 18)
$lblCount.ForeColor = [System.Drawing.Color]::DimGray
$lblCount.Text      = 'No folder selected.'

$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text     = '2. Folder to save the crops in'
$lblOut.Location = New-Object System.Drawing.Point(14, 90)
$lblOut.AutoSize = $true

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(14, 112)
$txtOut.Size     = New-Object System.Drawing.Size(390, 24)
$txtOut.ReadOnly = $true

$btnOut = New-Object System.Windows.Forms.Button
$btnOut.Text     = 'Browse...'
$btnOut.Location = New-Object System.Drawing.Point(410, 111)
$btnOut.Size     = New-Object System.Drawing.Size(85, 25)

$btnOutReset = New-Object System.Windows.Forms.Button
$btnOutReset.Text     = 'Default'
$btnOutReset.Location = New-Object System.Drawing.Point(500, 111)
$btnOutReset.Size     = New-Object System.Drawing.Size(90, 25)

$lblOutHint = New-Object System.Windows.Forms.Label
$lblOutHint.Location  = New-Object System.Drawing.Point(14, 140)
$lblOutHint.Size      = New-Object System.Drawing.Size(576, 18)
$lblOutHint.ForeColor = [System.Drawing.Color]::DimGray
$lblOutHint.Text      = 'Default: a "crops" subfolder inside the source. Created automatically if missing.'

$btnRegion = New-Object System.Windows.Forms.Button
$btnRegion.Text     = '3. Select region...'
$btnRegion.Location = New-Object System.Drawing.Point(14, 166)
$btnRegion.Size     = New-Object System.Drawing.Size(180, 32)
$btnRegion.Enabled  = $false

$lblRegion = New-Object System.Windows.Forms.Label
$lblRegion.Location  = New-Object System.Drawing.Point(204, 174)
$lblRegion.Size      = New-Object System.Drawing.Size(386, 20)
$lblRegion.ForeColor = [System.Drawing.Color]::DimGray
$lblRegion.Text      = 'No region defined.'

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text     = 'Options'
$grp.Location = New-Object System.Drawing.Point(14, 208)
$grp.Size     = New-Object System.Drawing.Size(576, 106)

$lblFmt = New-Object System.Windows.Forms.Label
$lblFmt.Text     = 'Output format:'
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
$chkAlpha.Text     = 'Turn black into transparency'
$chkAlpha.Location = New-Object System.Drawing.Point(14, 50)
$chkAlpha.Size     = New-Object System.Drawing.Size(240, 22)

$lblTol = New-Object System.Windows.Forms.Label
$lblTol.Text     = 'Tolerance (0 = pure black):'
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
$lblTolHint.Text      = 'raise it if dark edges remain'
$lblTolHint.Location  = New-Object System.Drawing.Point(250, 78)
$lblTolHint.AutoSize  = $true
$lblTolHint.ForeColor = [System.Drawing.Color]::DimGray

$grp.Controls.AddRange(@($lblFmt, $cmbFormat, $lblFmtHint, $chkAlpha, $lblTol, $numTol, $lblTolHint))

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text     = '4. Process all'
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
        $lblOutHint.Text = 'Default: a "crops" subfolder inside the source. Created automatically if missing.'
    }
    else {
        $lblOutHint.Text = 'Fixed output folder. "Default" goes back to the subfolder inside the source.'
    }
}

function Update-RunState {
    $btnRun.Enabled = ($null -ne $ui.Region) -and ((Get-ImageFiles $ui.Folder).Count -gt 0)
}

# JPG and BMP carry no alpha: rather than losing transparency silently, the
# checkbox is disabled and the choice remembered for the return to PNG.
function Update-FormatState {
    $info = Get-FormatInfo $cmbFormat.SelectedItem
    if ($info.SupportsAlpha) {
        $chkAlpha.Enabled = $true
        $chkAlpha.Checked = $ui.WantAlpha
        $lblFmtHint.Text  = 'PNG preserves transparency.'
    }
    else {
        # Disable BEFORE unticking: otherwise the event would overwrite WantAlpha.
        $chkAlpha.Enabled = $false
        $chkAlpha.Checked = $false
        $lblFmtHint.Text  = "$($info.Name) has no alpha channel: saved opaque over white."
    }
    $numTol.Enabled = $chkAlpha.Checked
}

$chkAlpha.Add_CheckedChanged({
    if ($chkAlpha.Enabled) { $ui.WantAlpha = $chkAlpha.Checked }
    $numTol.Enabled = $chkAlpha.Checked
})

$cmbFormat.Add_SelectedIndexChanged({ Update-FormatState })

# Split out of the handler so it can be tested without opening the folder dialog.
function Set-SourceFolder {
    param([string]$Path)

    $ui.Folder      = $Path
    $txtFolder.Text = $Path
    $ui.Region      = $null      # the old region is meaningless for other screenshots
    $ui.RefWidth    = 0
    $ui.RefHeight   = 0
    $lblRegion.Text = 'No region defined.'
    $lblRegion.ForeColor = [System.Drawing.Color]::DimGray

    $files = Get-ImageFiles $Path
    if ($files.Count -eq 0) {
        $lblCount.Text     = 'No supported images in that folder.'
        $btnRegion.Enabled = $false
    }
    else {
        $lblCount.Text     = "$($files.Count) image(s) found. Reference: $($files[0].Name)"
        $btnRegion.Enabled = $true
    }
    Update-OutBox
    Update-RunState
}

# Opens the Explorer-style picker starting at the first of the candidate paths
# that still exists, so changing a folder never starts the walk from scratch.
# The GUID identifies the dialog for Windows, which stores its last position
# under it: source and output keep separate memories, kept between runs.
# If the COM dialog is ever unavailable it falls back to the old tree rather
# than leaving the button dead.
function Select-FolderDialog {
    param([string]$Title, [string[]]$StartAt, [string]$ClientGuid)

    $start = ''
    foreach ($p in $StartAt) {
        if (Test-FolderExists $p) { $start = $p; break }
    }

    $owner = [IntPtr]::Zero
    if ($main.IsHandleCreated) { $owner = $main.Handle }

    try {
        $picked = [SnipBatchFolder]::Pick($owner, $Title, $start, $ClientGuid)
    }
    catch {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description         = $Title
        $dlg.ShowNewFolderButton = $true
        if ($start -ne '') { $dlg.SelectedPath = $start }
        $picked = $null
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $picked = $dlg.SelectedPath }
        $dlg.Dispose()
    }

    if (-not [string]::IsNullOrWhiteSpace($picked)) { $ui.LastDir = $picked }
    return $picked
}

$btnFolder.Add_Click({
    $picked = Select-FolderDialog -Title 'Folder holding the screenshots' `
                                  -StartAt @($ui.Folder, $ui.LastDir) `
                                  -ClientGuid '7b2f1a4e-6c3d-4b57-9a11-5d0c2e8f3a01'
    if ([string]::IsNullOrWhiteSpace($picked)) { return }
    Set-SourceFolder -Path $picked
})

$btnOut.Add_Click({
    $picked = Select-FolderDialog -Title 'Folder to save the crops in' `
                                  -StartAt @((Resolve-OutFolder), $ui.Folder, $ui.LastDir) `
                                  -ClientGuid '7b2f1a4e-6c3d-4b57-9a11-5d0c2e8f3a02'
    if ([string]::IsNullOrWhiteSpace($picked)) { return }
    $ui.OutFolder = $picked
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
        Write-Log 'Selection cancelled.'
        return
    }

    $ui.Region = $region
    $lblRegion.Text = "Region: $($region.Width) x $($region.Height) px  at  X=$($region.X), Y=$($region.Y)"
    $lblRegion.ForeColor = [System.Drawing.Color]::Black
    Write-Log "Region defined on $($files[0].Name) ($($ui.RefWidth)x$($ui.RefHeight)): $($region.Width)x$($region.Height) @ $($region.X),$($region.Y)"
    Update-RunState
})

$btnRun.Add_Click({
    $files = Get-ImageFiles $ui.Folder
    if ($files.Count -eq 0 -or $null -eq $ui.Region) { return }

    $outFolder = Resolve-OutFolder

    # Saving into the source folder itself would overwrite the originals.
    $sameFolder = $false
    try {
        $sameFolder = ([System.IO.Path]::GetFullPath($ui.Folder).TrimEnd([char]92) -eq
                         [System.IO.Path]::GetFullPath($outFolder).TrimEnd([char]92))
    }
    catch { $sameFolder = $false }   # odd path: carry on, saving will report it
    if ($sameFolder) {
        $warn = [System.Windows.Forms.MessageBox]::Show(
            ("The output folder is the same as the source.`n`nCrops are saved under the same name with the {0} extension, so any original in that folder with that name will be overwritten and cannot be recovered.`n`nContinue anyway?" -f (Get-FormatInfo $cmbFormat.SelectedItem).Extension),
            'SnipBatch - careful', 'YesNo', 'Warning', 'Button2')
        if ($warn -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Cancelled: the output pointed at the source folder.'
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
            "Could not create the output folder:`n$outFolder`n`n$($_.Exception.Message)",
            'SnipBatch', 'OK', 'Error')
        return
    }

    $btnRun.Enabled = $false; $btnRegion.Enabled = $false
    $btnFolder.Enabled = $false; $btnOut.Enabled = $false; $btnOutReset.Enabled = $false
    $progress.Value   = 0
    $progress.Maximum = $files.Count
    Write-Log ''
    Write-Log "--- Processing $($files.Count) image(s) as $((Get-FormatInfo $cmbFormat.SelectedItem).Name) -> $outFolder"

    $ok = 0; $fail = 0
    $fmt  = Get-FormatInfo $cmbFormat.SelectedItem
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    $ui.Busy = $true
    $ui.Stop = $false
    try {
        foreach ($f in $files) {
            if ($ui.Stop) { Write-Log '--- Interrupted by the user.'; break }
            try {
                $base = Get-UniqueName -Used $used `
                            -BaseName ([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
                $r = Invoke-Crop -Path $f.FullName -Region $ui.Region `
                                 -RefWidth $ui.RefWidth -RefHeight $ui.RefHeight `
                                 -OutPath ([System.IO.Path]::Combine($outFolder, "$base$($fmt.Extension)")) `
                                 -BlackToAlpha $chkAlpha.Checked -Tolerance ([int]$numTol.Value) `
                                 -Format $fmt.Name
                if ($r.Ok) { $ok++;   Write-Log ("  OK    {0}  [{1}]" -f $f.Name, $r.Message) }
                else       { $fail++; Write-Log ("  SKIP  {0}  [{1}]" -f $f.Name, $r.Message) }
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

    Write-Log "--- Done: $ok succeeded, $fail with problems."
    $btnRun.Enabled = $true; $btnRegion.Enabled = $true
    $btnFolder.Enabled = $true; $btnOut.Enabled = $true; $btnOutReset.Enabled = $true

    # If the window was closed mid-run, close it for real now, with no more dialogs.
    if ($ui.Stop) { $main.Close(); return }

    if ($ok -gt 0) {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "$ok image(s) saved to:`n$outFolder`n`nOpen the folder?",
            'SnipBatch', 'YesNo', 'Information')
        if ($ask -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Unquoted, a path with spaces arrives split and explorer opens the wrong thing.
            Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $outFolder)
        }
    }
})

# DoEvents keeps the window usable while processing: if it is closed mid-run,
# the loop would go on writing to controls that have already been disposed.
$main.Add_FormClosing({
    param($s, $e)
    if ($ui.Busy) {
        $ui.Stop  = $true
        $e.Cancel = $true
    }
})

Write-Log 'SnipBatch ready.'
Write-Log '1) Source folder  2) Output folder  3) Region  4) Process.'
Write-Log 'In the selection: drag, adjust with the handles and press ENTER to confirm.'

Update-OutBox
Update-FormatState
[void]$main.ShowDialog()
$main.Dispose()
