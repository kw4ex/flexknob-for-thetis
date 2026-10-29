@echo off
title FlexControl Knob - add the window to Thetis
REM  Puts the "FlexControl Knob" window into Thetis (shows what the knob does right now).
REM  If Thetis is running, the setup offers to close it (the normal way) and to start it again.
REM  A backup of your Thetis settings is saved before anything changes.
cd /d "%~dp0"
set "PYCMD=py -3"
%PYCMD% flexknob_thetis_setup.py %*
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
