@echo off
REM ======================================================================
REM  start_flexknob.bat  -  starts FlexControl Knob for Thetis
REM ======================================================================
REM
REM  WHAT THIS FILE DOES
REM    1. Checks whether the knob program is already running. It never starts twice.
REM    2. If it is not running, starts it in its own window.
REM    3. Optionally starts Thetis as well (see section B).
REM
REM  Double-click this file (or the Desktop shortcut) to start the knob program.
REM  To stop it, click its window and press Q (or close the window).
REM  Then open the panel in your browser: http://127.0.0.1:8090
REM
REM  No warranty - use at your own risk (see LICENSE.txt).
REM
REM ----------------------------------------------------------------------
REM  A. OPTIONS (flags) - add them to the KNOB_FLAGS line in the SETTINGS block
REM ----------------------------------------------------------------------
REM  Separate flags with spaces. Save the file, close the knob window, run this file again.
REM    --tci-port 50001      Thetis TCI port (Thetis: Setup > Serial/Network/Midi CAT > Network)
REM    --web-port 8090       port of the browser panel (use another if 8090 is taken)
REM    --no-web              no browser panel
REM    --open-panel          open the panel in your browser every time the program starts
REM    --mmio-port 50120     UDP port for the window inside Thetis (0 = do not send)
REM    --verbose             show every message (for troubleshooting)
REM    --no-log              do not write a log file
REM
REM ----------------------------------------------------------------------
REM  B. HAVE THIS FILE START THETIS TOO (optional)
REM ----------------------------------------------------------------------
REM  Change START_THETIS to 1 and check THETIS_EXE points at your Thetis.exe
REM  (right-click your normal Thetis shortcut, Properties, copy the Target).
REM    Thetis HL2:  ...\OpenHPSDR\Thetis-HL2\Thetis.exe  with  -dbid:HL2  in THETIS_FLAGS
REM    SDR-VST3:    ...\OpenHPSDR\SDR-VST3\Thetis.exe
REM  If Thetis is already running it is left alone.
REM
REM ----------------------------------------------------------------------
REM  C. IF SOMETHING GOES WRONG
REM ----------------------------------------------------------------------
REM  - A window flashes and disappears: open Command Prompt, go to this folder,
REM    type the name of this file and press Enter to see the message.
REM  - "py" was not found: install Python from python.org and tick "Add Python to PATH".
REM  - The window says the knob is "in use by another program": see FlexKnob_Help.html
REM    (section "Using it with the KPA1500 Thetis Bridge").
REM ======================================================================

REM ==================== SETTINGS - EDIT THESE ===========================
REM  Folder with flexknob_thetis.py:
set "KNOB_DIR=%~dp0"
set "KNOB_SCRIPT=flexknob_thetis.py"
REM  Flags for the program (see section A):
set "KNOB_FLAGS="
REM  1 = run the knob window minimized, 0 = normal window:
set "START_MINIMIZED=0"
REM  1 = also start Thetis (see section B), 0 = knob program only:
set "START_THETIS=0"
set "THETIS_EXE=C:\Program Files\OpenHPSDR\Thetis\Thetis.exe"
set "PYCMD=py -3"
set "THETIS_FLAGS="
REM  Seconds to wait after starting the knob program before starting Thetis:
set "THETIS_DELAY=3"
REM ======================================================================

REM ---------- nothing below this line needs editing ----------

%PYCMD% --version >nul 2>&1
if errorlevel 1 goto no_python

pushd "%KNOB_DIR%"
if exist "%KNOB_SCRIPT%" goto have_script
popd
echo.
echo Cannot find the knob program (%KNOB_SCRIPT%) in:
echo   %KNOB_DIR%
echo Edit KNOB_DIR near the top of this file.
echo.
pause
exit /b 1

:no_python
echo.
echo Python (%PYCMD%) was not found.
echo Install Python from python.org and tick "Add Python to PATH".
echo.
pause
exit /b 1

:have_script
set "WINSTATE="
if "%START_MINIMIZED%"=="1" set "WINSTATE=/min"
%PYCMD% "%KNOB_SCRIPT%" --check-running %KNOB_FLAGS% >nul 2>&1
if "%errorlevel%"=="3" goto knob_running
echo Starting FlexControl Knob for Thetis...
start "FlexControl Knob for Thetis" %WINSTATE% cmd /k %PYCMD% "%KNOB_SCRIPT%" %KNOB_FLAGS%
popd
goto after_knob

:knob_running
popd
echo The knob program is already running - leaving it alone.

:after_knob
if not "%START_THETIS%"=="1" goto done
if exist "%THETIS_EXE%" goto have_thetis
echo.
echo Thetis was not found at:
echo   %THETIS_EXE%
echo Edit THETIS_EXE near the top of this file.
echo.
pause
goto done

:have_thetis
tasklist /FI "IMAGENAME eq Thetis.exe" 2>nul | find /I "Thetis.exe" >nul
if not errorlevel 1 goto thetis_running
timeout /t %THETIS_DELAY% /nobreak >nul
for %%I in ("%THETIS_EXE%") do set "THETIS_DIR=%%~dpI"
echo Starting Thetis...
pushd "%THETIS_DIR%"
start "" "%THETIS_EXE%" %THETIS_FLAGS%
popd
goto done

:thetis_running
echo Thetis is already running - leaving it alone.

:done
exit /b 0
