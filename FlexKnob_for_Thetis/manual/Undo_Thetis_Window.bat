@echo off
title FlexControl Knob - undo the Thetis window setup
REM  Puts back the Thetis settings saved just before the last window setup.
REM  If Thetis is running, it offers to close it (the normal way) and to start it again.
cd /d "%~dp0"
set "PYCMD=py -3"
%PYCMD% flexknob_thetis_setup.py --restore
if errorlevel 1 goto problem
echo.
echo All done. This window closes by itself in 10 seconds (or press any key).
timeout /t 10 >nul
exit /b 0
:problem
echo.
echo Something did not work - please read the messages above.
pause
exit /b 1
