FlexControl Knob for Thetis v1.0.0  (KW4EX)  -  INSTALL INSTRUCTIONS
==========================================================================

Written for radio operators, not programmers. Every step says what to click.

NO WARRANTY - USE AT YOUR OWN RISK
  This program is shared by one radio operator, as is. There is no
  warranty of any kind: no promise that it works, that it is safe, or that it
  suits your equipment or your purpose. Amplifiers, radios and antennas can be
  damaged, and RF can be dangerous. TUNE and MOX on the knob really transmit.
  You are responsible for checking that it behaves correctly with your own
  station, and for operating within your license. The author is not liable for
  any damage or loss. It is not made, approved or supported by FlexRadio,
  Thetis, Thetis HL2 or SDR-VST3. Licensed under the MIT License (see
  LICENSE.txt).

--------------------------------------------------------------------------
1. WHAT IT IS
--------------------------------------------------------------------------

A small program for Windows 10 and 11 that lets the FlexRadio FlexControl USB
tuning knob control Thetis, Thetis HL2 and SDR-VST3. It needs no amplifier and
no other radio hardware: just the knob and Thetis.

It is the knob part of the KPA1500 Thetis Bridge (v2.31) as a stand-alone
program, for operators who have the knob but not the Elecraft KPA1500
amplifier. It adds a small web page that shows what turning the knob does
right now, and what each press does. It can also add a small window inside
Thetis that shows the same thing.

--------------------------------------------------------------------------
2. WHAT IT DOES
--------------------------------------------------------------------------

  * Turning the knob tunes VFO A in Thetis' own tuning step. A press can
    switch the knob to VFO B, AF volume, AGC gain, RIT, XIT, tuning step or TX
    drive. The three lights on the knob show which.
  * 12 presses (the knob press and buttons 1–3, each as a tap, double tap or
    long press). Each runs a function you choose on the panel.
  * A panel in your browser (http://127.0.0.1:8090) shows what the knob does
    right now and lets you choose the functions.
  * An optional window inside Thetis ("FlexControl Knob") shows the same
    thing.

  Knob press: AF volume ⇄ VFO A | Mute | Back to VFO A
  Button 1: AF volume ⇄ VFO A | AGC gain ⇄ VFO A | Mute
  Button 2: VOX | Tuning step larger | Tuning step smaller
  Button 3: TUNE (transmits!) | Band up | Band down

These are the starting settings (the same as the bridge's, except that button
3 tap is a plain TUNE here). Change any of them on the panel.

--------------------------------------------------------------------------
3. WHAT YOU NEED
--------------------------------------------------------------------------

  Windows: Windows 10 or 11.
  Thetis: Thetis 2.10.3.12 or newer, Thetis HL2 2.10.3.15 or newer, or
      SDR-VST3 5.x, installed and working.
  Thetis TCI turned on: A setting inside Thetis (port 50001). The install
      steps below show where.
  FlexControl knob: Plugged into this computer with its USB cable.
  Python 3.8 or newer: Free. The installer checks for it and offers to install
      it.
  pyserial: A small free helper that reads the knob. The installer installs it
      (needs internet).

  IMPORTANT: Only one program can use the knob at a time. Close DDUtil, and
  switch off the knob feature of the KPA1500 Thetis Bridge if you have it
  (Part 6), before you use this program.

--------------------------------------------------------------------------
4. WHAT'S IN THIS DOWNLOAD
--------------------------------------------------------------------------

  READ ME FIRST …pdf: This guide.
  FlexKnob_for_Thetis_v1.0.0.zip: The program. Right-click it, choose Extract
      All…, then Extract.
  LICENSE.txt: The license (MIT).

Inside the zip is a folder FlexKnob_for_Thetis. In it:

  1_RUN_THIS_Installer.bat: Double-click this. It does the whole install and
      asks a few easy questions.
  README_Install.txt: The install steps as a plain text file.
  FlexKnob_Help.html: The full help (open it in your browser).
  manual\: The program's own files, for anyone who wants to install by hand.

--------------------------------------------------------------------------
5. INSTALL, STEP BY STEP
--------------------------------------------------------------------------

PART A — GET READY (5 MINUTES)

  1. Close any other program that uses the knob. That means DDUtil (if you use
     it with the knob) and the knob feature of the KPA1500 Thetis Bridge. Part
     6 below shows how to switch the bridge's knob off. The installer can do
     that for you.
  2. Plug the knob into the computer with its USB cable. Windows normally sets
     it up by itself (it shows up in Device Manager under Ports).
  3. Turn on Thetis' TCI server. Start Thetis. Click Setup ›
     Serial/Network/Midi CAT › the Network tab. Set the TCI Server to
     127.0.0.1:50001, tick TCI Server Running, click Apply, then OK.
  4. Close Thetis the normal way (File › Exit). It is happy to be closed now;
     the installer may add a window to it.

PART B — RUN THE INSTALLER

  1. In your Downloads folder, right-click FlexKnob_for_Thetis_v1.0.0.zip ›
     Extract All… › Extract.
  2. Open the new FlexKnob_for_Thetis folder and double-click
     1_RUN_THIS_Installer.bat.
  3. If Windows says "Windows protected your PC", click More info, then Run
     anyway. (The installer is a plain text file; you can open it in Notepad
     to read exactly what it does.)
  4. A window with text opens. It asks a few questions. Press Enter to accept
     the answer shown in [brackets] unless this guide says otherwise.
  5. Step 1 of 6 — Python. If it says "Found Python…", nothing to do. If not,
     answer y to let it install Python, or install it yourself from python.org
     (tick Add python.exe to PATH) and double-click the installer again. It
     then installs pyserial by itself (internet needed).
  6. Step 2 of 6 — Install folder. Press Enter. The program goes into
     C:\RadioScripts\FlexKnob_for_Thetis, its own folder, next to your other
     programs. (Do not choose "Program Files".)
  7. Step 3 of 6 — Only one program can use the knob. If you have the KPA1500
     Thetis Bridge, the installer finds it and offers to switch off its knob.
     Press Enter (yes). Nothing else in the bridge changes. If the bridge is
     running, the installer shows you the steps to do it yourself (also in
     Part 6).
  8. Step 4 of 6 — Thetis, start file, shortcuts. "Should the start file also
     launch… Thetis?" — press Enter (no) to start Thetis your usual way, or y
     to have one shortcut start both. "Put a shortcut on the Desktop?" — Enter
     (yes). "Start automatically when you sign in to Windows?" — Enter (no).
  9. Step 5 of 6 — Self-test. Press Enter. After about 30 seconds you should
     see ALL TESTS PASSED. This test uses a pretend knob and a pretend Thetis;
     nothing real is touched.
 10. Step 6 of 6 — The knob window inside Thetis (optional). Press Enter (yes)
     to add it. If Thetis is running the installer offers to close it (Enter;
     make sure the radio is not transmitting). A backup of Thetis' settings is
     saved first. Choose n to skip; you can add it later.
 11. At the end it offers to start the knob program now and opens the panel in
     your browser. Press Enter.

PART C — CHECK THAT IT WORKS

  1. A window titled FlexControl Knob for Thetis is open (the knob program).
     Leave it open while you use the radio. To stop the program, click that
     window and press Q.
  2. Start Thetis (or Thetis HL2 / SDR-VST3) the way you always do. Its TCI
     server must be on (Part A, step 3).
  3. Open the panel in your browser: http://127.0.0.1:8090 (or double-click
     Open_Knob_Panel.bat in the install folder). At the top you should see two
     green labels: Knob connected on COM… and Thetis connected (TCI).
  4. Turn the knob. VFO A should tune. The big text on the panel says VFO A
     tuning.
  5. Tap button 1. The first light on the knob comes on, the panel says AF
     volume (master), and turning now changes the volume. Tap button 1 again
     to go back to VFO A.
  6. If you added the window to Thetis, it shows the same information. If it
     says FLEXKNOB PROGRAM NOT RUNNING, the knob program is not running.

PART D — CHOOSE WHAT EACH PRESS DOES

  1. On the panel, find What each press does. There is one line for each of
     the 12 presses.
  2. Click the drop-down on a line and pick a function. It is saved at once.
  3. Click Try to run that function as if you had pressed the knob. (Functions
     that transmit ask you first.)
  4. To go back to the starting settings, click Put all functions back to the
     defaults.

  NOTE: Every day after that: double-click the FlexKnob for Thetis shortcut on
  your Desktop (or start_flexknob.bat in C:\RadioScripts\FlexKnob_for_Thetis),
  then start Thetis.

--------------------------------------------------------------------------
6. IF YOU ALSO HAVE THE KPA1500 THETIS BRIDGE
--------------------------------------------------------------------------

The bridge has its own knob feature. Only one program can open the knob, so
switch the bridge's knob off and use this program for the knob. The bridge's
amplifier features are not affected.

SWITCH THE KNOB OFF IN THE BRIDGE

  1. Start the KPA1500 Thetis Bridge. Open your browser and go to
     http://127.0.0.1:8080 (the bridge panel).
  2. Click Settings, then find FlexControl tuning knob.
  3. Set the Knob drop-down to Off (not used). It saves by itself and works at
     once. You do not need to restart the bridge.
  4. Optional: also untick Show the KPA1500 Knob window in Thetis (Settings ›
     Thetis windows › Knob window) and press Rebuild Thetis windows, so Thetis
     does not show two knob windows.
  5. Now start the knob program from this download. The panel's first label
     should turn green: Knob connected on COM….

TO GO BACK TO THE BRIDGE'S KNOB

  1. Close the knob program here (click its window and press Q).
  2. In the bridge panel set Knob back to Find it automatically.

  NOTE: The two programs use different names and ports, so they do not
  overwrite each other: this program's panel is at port 8090 (the bridge's is
  8080), its Thetis window is called "FlexControl Knob for Thetis - KW4EX"
  (the bridge's is "KPA1500 Knob - KW4EX"), and each has its own settings
  file. One thing to know: each program's Undo puts back the Thetis settings
  saved before ITS last change, so using one program's Undo can also take away
  the other's window. Just run that program's Setup again.

--------------------------------------------------------------------------
7. KNOB MODES AND LIGHTS
--------------------------------------------------------------------------

What turning the knob does is called its mode. The three small lights on the
knob (buttons 1-2-3) show the mode:

  VFO A tuning: ○ ○ ○
  VFO B tuning: ● ○ ●
  AF volume (master): ● ○ ○
  AGC gain (RX1): ○ ● ○
  RIT (10 Hz per click): ○ ○ ●
  XIT (10 Hz per click): ○ ● ●
  Tuning step size: ● ● ○
  TX drive: ● ● ●

● = on, ○ = off. VFO, RIT, XIT and the tuning step use Thetis' own step. Spun
fast, the VFO moves faster (Fast spin on the panel).

--------------------------------------------------------------------------
8. SAFETY RULES BUILT IN
--------------------------------------------------------------------------

  * TUNE and MOX really make Thetis transmit. Check your antenna or dummy load
    first. This program does not check for an antenna.
  * TUNE is refused if the radio is already transmitting. It stops by itself
    after 20 seconds (you can change this on the panel; 0 = never). Pressing
    it again stops it sooner. The panel shows a big STOP TUNE button while it
    is on.
  * If Thetis is closed or the link is lost, knob presses that need Thetis do
    nothing and the panel says so.
  * The panel can only be opened from this computer (127.0.0.1), and only this
    computer's own web address is accepted.
  * Only one copy of the program runs at a time; a second one says so and
    stops.

--------------------------------------------------------------------------
9. UPDATING AND REMOVING
--------------------------------------------------------------------------

UPDATING TO A NEWER VERSION

  1. Download the new zip and extract it. Each version has its own name with
     the version number.
  2. Close the knob program (press Q in its window). The installer can also do
     this for you.
  3. Double-click the new 1_RUN_THIS_Installer.bat. Choose Continue, and
     choose Keep your current start options. Your settings (what each press
     does) are kept.

REMOVING IT

  1. Double-click Uninstall_FlexKnob_for_Thetis.bat in
     C:\RadioScripts\FlexKnob_for_Thetis.
  2. Answer y to remove the knob window from Thetis (Thetis must be closed; a
     backup is saved first), and y to delete the program's own files. Nothing
     else in the folder is touched.

--------------------------------------------------------------------------
10. IF SOMETHING GOES WRONG
--------------------------------------------------------------------------

  "Windows protected your PC": Click More info, then Run anyway.
  The installer says Python was not found: Install Python from python.org,
      tick Add python.exe to PATH, then double-click the installer again.
  Panel: "pyserial is not installed": Open Command Prompt and type  py -m pip
      install pyserial  (internet needed), then start the program again.
  Panel: "Knob: not found (is it plugged in?)": Plug the knob in. Double-click
      Find_My_Knob.bat: it says whether Windows sees the knob and on which COM
      port. If it is found, pick that port in the panel's Knob settings.
  Panel: "… is in use by another program": Another program has the knob. Close
      DDUtil, and switch off the knob in the KPA1500 Thetis Bridge (Part 6).
      Wait a few seconds.
  Panel: "Thetis: waiting…": Start Thetis, and check Setup ›
      Serial/Network/Midi CAT › Network: TCI Server Running ticked,
      127.0.0.1:50001, Apply, OK.
  "…needs a newer Thetis for the knob functions": Your Thetis is too old to
      take these commands over TCI. Update Thetis (2.10.3.12 or newer; HL2
      2.10.3.15 or newer). The lights and the mode switching still work.
  The panel does not open: The knob program is not running. Start it (Desktop
      shortcut). If its window says port 8090 is busy, edit start_flexknob.bat
      and add  --web-port 8091  to the KNOB_FLAGS line.
  Window in Thetis says "FLEXKNOB PROGRAM NOT RUNNING": Start the knob
      program. The window turns normal within a second or two.
  Window in Thetis is missing: Close Thetis, double-click
      Setup_Thetis_Window.bat. If Thetis does not show it, in Thetis open
      Setup › Appearance › Meters/Gadgets and look for "FlexControl Knob for
      Thetis - KW4EX".
  Something is wrong after the Thetis window setup: Close Thetis, double-click
      Undo_Thetis_Window.bat. It puts back the settings saved just before.
  The self-test did not pass: Open install_selftest.txt in the install folder
      and send it to whoever gave you the program.

The program's log is flexknob.log in the install folder (it keeps itself
small). For more detail, add  --verbose  to KNOB_FLAGS in start_flexknob.bat.

--------------------------------------------------------------------------
Latest version and full help: github.com/kw4ex/flexknob-for-thetis
Full help with every option: FlexKnob_Help.html (in this folder).
"FlexRadio", "FlexControl" and "Thetis" are names of their owners; this is an independent, community-made program.

73 de KW4EX
