# Exercises the main window WITHOUT opening dialogs or touching mouse/keyboard:
# it swaps the final ShowDialog for asserts on the state of the controls.
$ErrorActionPreference = 'Stop'
# Path to the script under test, relative to this folder.
$src = [System.IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'SnipBatch.ps1')
$text = Get-Content $src -Raw

$driver = @'
$script:pass = 0; $script:fail = 0
function Chk($actual, $expected, $name) {
    if ("$actual" -eq "$expected") { $script:pass++ }
    else { $script:fail++; "  FAIL  $name : expected <$expected>  got <$actual>" }
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

Chk $main.Controls.Count 15 'the window builds every control'

# --- folder with images ---
Set-SourceFolder -Path $conim
Chk $btnRegion.Enabled $true  'with images, Select region is enabled'
Chk $btnRun.Enabled    $false 'with no region, Process stays disabled'
Chk $lblCount.Text '2 image(s) found. Reference: dos.png' 'count and reference (alphabetical)'
Chk $txtOut.Text (Join-Path $conim 'crops') 'default output inside the source'

# --- folder WITHOUT images (this used to crash under StrictMode) ---
Set-SourceFolder -Path $vacia
Chk $lblCount.Text 'No supported images in that folder.' 'reports a folder with no images'
Chk $btnRegion.Enabled $false 'no images means no region selection'
Chk $btnRun.Enabled    $false 'no images means no processing'

# --- missing folder ---
Set-SourceFolder -Path 'Z:\no\existe\nada'
Chk $btnRegion.Enabled $false 'missing path treated as empty'

# --- manual output folder and back to the default ---
Set-SourceFolder -Path $conim
$ui.OutFolder = 'D:\otra\parte'
Update-OutBox
Chk $txtOut.Text 'D:\otra\parte' 'manual output is honoured'
Chk ($lblOutHint.Text -like 'Fixed output folder*') $true 'the hint changes for a fixed output'
$ui.OutFolder = ''
Update-OutBox
Chk $txtOut.Text (Join-Path $conim 'crops') 'Default restores the subfolder'

# --- changing folder invalidates the previous region ---
$ui.Region = New-Object System.Drawing.Rectangle(0, 0, 10, 10)
$ui.RefWidth = 300; $ui.RefHeight = 200
Update-RunState
Chk $btnRun.Enabled $true 'with region + images, Process is enabled'
Set-SourceFolder -Path $conim
Chk ($null -eq $ui.Region) $true 'changing folder discards the region'
Chk $btnRun.Enabled $false 'and Process is disabled again'

# --- output format and its effect on transparency ---
Chk $cmbFormat.SelectedItem 'PNG'  'starts on PNG'
Chk $chkAlpha.Enabled $true        'with PNG the alpha checkbox is available'
Chk $chkAlpha.Checked $false       'and starts unticked'
Chk $numTol.Enabled   $false       'tolerance starts disabled'

$chkAlpha.Checked = $true
Chk $numTol.Enabled $true          'ticking alpha enables tolerance'
Chk $ui.WantAlpha   $true          'the choice is remembered'

$cmbFormat.SelectedItem = 'JPG'
Chk $chkAlpha.Enabled $false       'JPG disables the alpha checkbox'
Chk $chkAlpha.Checked $false       'and unticks it'
Chk $numTol.Enabled   $false       'and disables tolerance'
Chk $ui.WantAlpha     $true        'but does NOT forget what the user wanted'
Chk ($lblFmtHint.Text -like 'JPG has no alpha channel*') $true 'and explains it'

$cmbFormat.SelectedItem = 'BMP'
Chk $chkAlpha.Enabled $false       'BMP has no alpha either'

$cmbFormat.SelectedItem = 'PNG'
Chk $chkAlpha.Enabled $true        'going back to PNG re-enables it'
Chk $chkAlpha.Checked $true        'and restores the original tick'
Chk $numTol.Enabled   $true        'along with its tolerance'
$chkAlpha.Checked = $false

# --- closing mid-run ---
# FormClosing only fires if the window was actually shown
$main.Show()
[System.Windows.Forms.Application]::DoEvents()
$ui.Busy = $true
$main.Close()
[System.Windows.Forms.Application]::DoEvents()
Chk $main.IsDisposed $false 'while busy, closing does not dispose the window'
Chk $ui.Stop $true          'closing asks the batch to stop'
$ui.Busy = $false; $ui.Stop = $false

Remove-Item $vacia, $conim -Recurse -Force
''
"WINDOW RESULT: $script:pass passed, $script:fail failed"
$main.Dispose()
if ($script:fail -gt 0) { exit 1 }
'@

$text = $text.Replace('[void]$main.ShowDialog()' + "`n" + '$main.Dispose()', $driver)
$tmp  = Join-Path $env:TEMP 'snipbatch_win.ps1'
Set-Content -Path $tmp -Value $text -Encoding UTF8
& $tmp
