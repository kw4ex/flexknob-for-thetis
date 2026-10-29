@echo off
title FlexControl Knob - is the knob seen?
REM  Shows whether Windows sees the FlexControl knob, and on which COM port.
cd /d "%~dp0"
set "PYCMD=py -3"
%PYCMD% flexknob_thetis.py --find-knob
echo.
pause
