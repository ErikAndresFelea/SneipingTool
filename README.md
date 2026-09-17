# SnipBatch

Batch cropping in the style of the Windows Snipping Tool: you define a region **once** and it is
applied to **every image in a folder**. Optionally turns black into transparency, like Office's
"set transparent color".

## Usage

Double-click **`SnipBatch.bat`**.

1. **Source folder** → *Browse*.
2. **Folder to save the crops in** → defaults to a `crops` subfolder inside the source;
   *Browse* points it anywhere you like and *Default* restores the default. Originals are never
   modified.
3. **Select region** → the first image opens full screen.
4. **Process all**.

Both *Browse* buttons open the same folder window Explorer uses, with its address bar, Quick
access and search, so a path can also be typed or pasted. Each one reopens where you left it —
changing a folder never means walking the tree from the top again — and it is remembered between
runs of the tool.

## The selection

Drag to draw the rectangle. **Releasing the mouse does not confirm it**: the selection stays live
so you can adjust it.

| Action | How |
|---|---|
| Resize | drag any of the 8 handles |
| Move as a whole | drag from inside the rectangle |
| Nudge by 1 pixel | arrow keys |
| Nudge by 10 pixels | Ctrl + arrows |
| Stretch the right/bottom edge | Shift + arrows |
| Confirm | **Enter** (or double-click inside) |
| Start over | drag outside the rectangle |
| Cancel | Esc |

The readout always shows the size in **real image pixels**, not screen pixels: if the screenshot
is larger than your monitor it is displayed scaled down, but one arrow press still moves exactly
one pixel of the crop.

### Zoom and magnifier

A screenshot bigger than your monitor is shown scaled down, so one screen pixel covers several
real ones and the mouse alone cannot reach them. Zoom in and it can.

| Action | How |
|---|---|
| Zoom in / out around the pointer | mouse wheel (or `+` / `-`) |
| Fit the whole image again | `0` |
| Jump to 100% (1 screen pixel = 1 image pixel) | `1` |
| Pan once zoomed in | drag with the **right** or middle button |
| Hide or show the magnifier | `M` |

The magnifier follows the pointer and shows the surrounding pixels at 8x, with the edges of the
selection drawn in, so an edge can be placed on the exact pixel. Zooming never changes the
selection: it is stored in image pixels, so it survives zoom, pan and the whole adjustment.

## Details

- **Nothing to install.** Uses PowerShell 5.1, the .NET Framework and GDI+, all shipped with
  Windows. The `.bat` launches the script with `-ExecutionPolicy Bypass`, so there is no need to
  change the system's execution policy either.
- **Input formats:** png, jpg, jpeg, bmp, gif, tif, tiff.
- **Output format:** choose between **PNG, JPG and BMP**.
  - *PNG* is the default and the only one that preserves transparency.
  - *JPG* is written at quality 90 (GDI+ defaults to 75, which smears text).
  - *JPG and BMP* are flattened onto white at 24 bits. Picking either one disables the
    transparency checkbox automatically, so you cannot lose transparency without noticing.
    Switching back to PNG restores whatever you had ticked.
- **The region is defined on the first image** (alphabetically), not on the live screen. That
  keeps coordinates exact to the pixel and lets you see what you are about to crop.
- **Images of different sizes:** if an image does not match the reference size, the region is
  scaled proportionally and the log says so. If it still falls outside, that image is skipped.
- **Name collisions:** if the folder holds both `photo.png` and `photo.jpg`, the second crop is
  saved as `photo (2).png` instead of overwriting the first.
- **Tolerance:** a pixel becomes transparent when its R, G and B channels are *all* below the
  threshold. At `0` only pure black is affected; raise it (12-40) if dark halos remain around
  text or anti-aliased edges.
- **Closing the window mid-run** stops the batch cleanly; crops already written are kept.

## If it does not start

The launcher hides the console, so a startup failure is reported in a dialog box. If not even
that appears, open PowerShell in this folder and run the following to see the error:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\SnipBatch.ps1
```

## Files

| File | Purpose |
|---|---|
| `SnipBatch.bat` | Launcher. This is the one you run. |
| `SnipBatch.ps1` | The whole tool: interface, selection and processing. |
| `tests/run-tests.bat` | Runs the 132 automated tests. |

## Tests

Double-click `tests/run-tests.bat`. They cover the selection geometry (clamping at edges, handles
dragged past the opposite side, screen↔image conversion, zoom and pan clamping), cropping, output
formats and transparency (tolerance, flattening onto white, JPEG quality, mismatched sizes, name
collisions, files left unlocked) and the main window (empty folder, missing drive, manual output
folder, format versus transparency, closing mid-run).

None of them open dialogs or take over the mouse or keyboard, so they can be left running.
