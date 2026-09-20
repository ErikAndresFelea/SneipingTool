@echo off
setlocal
rem A .bat file cannot carry an icon of its own: Windows always paints the
rem generic gears on it. A shortcut can, so this makes one next to the tool
rem pointing at SnipBatch.bat and wearing SnipBatch.ico. Run it once; from then
rem on launch SnipBatch instead of the .bat, and pin it wherever you like.
rem With the /desktop switch it puts the shortcut on the Desktop as well.

set "HERE=%~dp0"

if not exist "%HERE%SnipBatch.ico" (
    echo SnipBatch.ico is missing, drawing it...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\New-Icon.ps1"
    if errorlevel 1 goto :failed
)

call :make "%HERE%SnipBatch.lnk"
if /i "%~1"=="/desktop" call :make "%USERPROFILE%\Desktop\SnipBatch.lnk"

echo.
echo Done.
pause
exit /b 0

:make
powershell -NoProfile -ExecutionPolicy Bypass -Command "$h='%HERE%'; $w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut('%~1'); $s.TargetPath=$h+'SnipBatch.bat'; $s.WorkingDirectory=$h.TrimEnd('\'); $s.IconLocation=$h+'SnipBatch.ico,0'; $s.Description='Crop every screenshot in a folder to the same region'; $s.WindowStyle=7; $s.Save()"
if errorlevel 1 goto :failed
echo Shortcut created: %~1
exit /b 0

:failed
echo.
echo Could not create the shortcut.
pause
exit /b 1
