@echo off
setlocal
title FlexControl Knob for Thetis - Installer
REM ======================================================================
REM  FlexControl Knob for Thetis - one-click installer
REM  Just double-click this file. It is plain text: open it in Notepad to
REM  see exactly what it does. The program files are packed (base64) at the
REM  very bottom; the installer logic is the readable PowerShell section.
REM  If Windows SmartScreen warns you: More info > Run anyway.
REM  No warranty - use at your own risk (MIT License, see LICENSE.txt).
REM ======================================================================
set "FLEXKNOB_INSTALLER=%~f0"
set "FLEXKNOB_PS1=%TEMP%\flexknob_installer_run.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:FLEXKNOB_INSTALLER); $i=$t.IndexOf([string][char]10+'#PS1-BEGIN')+11; $j=$t.IndexOf([string][char]10+'#PS1-END'); [IO.File]::WriteAllText($env:FLEXKNOB_PS1,$t.Substring($i,$j-$i))"
if not exist "%FLEXKNOB_PS1%" (
  echo Could not unpack the installer. Is PowerShell disabled on this PC?
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%FLEXKNOB_PS1%"
set "FLEXKNOB_RC=%ERRORLEVEL%"
del "%FLEXKNOB_PS1%" >nul 2>&1
echo.
if not "%FLEXKNOB_RC%"=="0" (
  echo The installer stopped - please read the messages above.
  pause
  exit /b
)
echo Installer finished. This window closes by itself in 60 seconds (or press any key).
timeout /t 60 >nul
exit /b
#PS1-BEGIN
# FlexControl Knob for Thetis - one-click installer (Windows PowerShell 5.1 or newer)
# This text is plain and readable on purpose: open the installer .bat in Notepad to see it.
# No warranty - use at your own risk (MIT License, see LICENSE.txt).
$ErrorActionPreference = 'Stop'
$script:Test = [bool]$env:FLEXKNOB_TEST
$script:IsWin = ($env:OS -eq 'Windows_NT')
$script:Made = @()          # shortcuts we create (for the uninstaller)
$script:PyCmd = ''
$script:ThetisRestart = $null   # Thetis.exe to start again at the end (if the installer closed it)
$script:ThetisRestartArgs = ''; $script:ThetisRestartName = 'Thetis'
$doneNames = ''

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head($t) { Write-Host ''; Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }
function Pause-Key { if (-not $script:Test) { Read-Host 'Press Enter to continue' | Out-Null } }
function AskText($q, $d = '') {
    if ($d) { $p = "$q [$d]" } else { $p = $q }
    $r = Read-Host $p
    if ($null -eq $r -or $r.Trim() -eq '') { return $d }
    return $r.Trim()
}
function AskYN($q, [bool]$d) {
    if ($d) { $s = 'Y/n' } else { $s = 'y/N' }
    for ($i = 0; $i -lt 5; $i++) {
        $r = Read-Host "$q ($s)"
        if ($null -eq $r -or $r.Trim() -eq '') { return $d }
        $r = $r.Trim().ToLower()
        if ($r -eq 'y' -or $r -eq 'yes') { return $true }
        if ($r -eq 'n' -or $r -eq 'no') { return $false }
        Say 'Please type y or n.' 'Yellow'
    }
    return $d
}

# ---- Python -------------------------------------------------------------
function Test-Py($cmd) {
    $ErrorActionPreference = 'Continue'
    try {
        $parts = @($cmd -split ' ')
        if (-not (Get-Command $parts[0] -ErrorAction SilentlyContinue)) { return $null }
        $pre = @(); if ($parts.Count -gt 1) { $pre = $parts[1..($parts.Count - 1)] }
        $out = (& $parts[0] @pre '--version' 2>&1 | Out-String)
        if ($out -match 'Python (\d+)\.(\d+)\.(\d+)') {
            if ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 8) { return $Matches[0] }
        }
    } catch { }
    return $null
}
function Find-Python {
    foreach ($c in @('py -3', 'py', 'python', 'python3')) {
        $v = Test-Py $c
        if ($v) { return @{ cmd = $c; ver = $v } }
    }
    return $null
}
function Invoke-Py([string[]]$PyArgs) {
    $ErrorActionPreference = 'Continue'
    $parts = @($script:PyCmd -split ' ')
    $pre = @(); if ($parts.Count -gt 1) { $pre = $parts[1..($parts.Count - 1)] }
    $out = (& $parts[0] @pre @PyArgs 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } } | Out-String)
    $script:PyExit = $LASTEXITCODE
    return $out
}

# ---- helpers ------------------------------------------------------------
function New-Shortcut($lnk, $target, $workdir, $desc) {
    $w = New-Object -ComObject WScript.Shell
    $s = $w.CreateShortcut($lnk)
    $s.TargetPath = $target; $s.WorkingDirectory = $workdir
    $s.Description = $desc; $s.WindowStyle = 1
    $s.Save()
}
function Find-Thetis {
    try {
        $p = Get-Process -Name Thetis -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.Path) { return $p.Path }
    } catch { }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\Program Files', 'C:\Program Files (x86)', 'C:\Thetis', 'D:\Thetis')
    foreach ($r in $roots) {
        if (-not $r) { continue }
        foreach ($rel in @('OpenHPSDR\Thetis\Thetis.exe', 'Thetis\Thetis.exe', 'Thetis.exe')) {
            $x = $r.TrimEnd('\') + '\' + $rel
            try { if (Test-Path -LiteralPath $x) { return $x } } catch { }
        }
    }
    return $null
}
function Get-Programs {
    # Thetis, Thetis HL2 and SDR-VST3 found on this computer (asked from the setup tool, one place for the rules)
    $res = @()
    if ($env:FLEXKNOB_TEST_PROGRAMS) { $o = $env:FLEXKNOB_TEST_PROGRAMS -replace ';', "`n" }
    elseif (Test-Path -LiteralPath $setupPy) { $o = Invoke-Py @($setupPy, '--list-programs') }
    else { $o = '' }
    foreach ($ln in ($o -split "`r?`n")) {
        $f = $ln.Split('|')
        if ($f.Count -ge 4 -and $f[0] -match '^(thetis|hl2|vst3)$') {
            $res += [pscustomobject]@{ Key = $f[0]; Name = $f[1]; Db = $f[2].Trim(); Exe = $f[3].Trim() }
        }
    }
    return ,$res
}
function Pick-One($items, $q) {
    if ($items.Count -eq 1) { return $items[0] }
    for ($i = 0; $i -lt $items.Count; $i++) { Say ("  " + ($i + 1) + "  " + $items[$i].Name) }
    for ($k = 0; $k -lt 5; $k++) {
        $r = AskText "$q Type its number" '1'
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { return $items[$n - 1] }
        Say ('Please type a number from 1 to ' + $items.Count + '.') 'Yellow'
    }
    return $items[0]
}
function Pick-Many($items, $q) {
    if ($items.Count -eq 1) { return ,@($items[0]) }
    for ($i = 0; $i -lt $items.Count; $i++) { Say ("  " + ($i + 1) + "  " + $items[$i].Name) }
    Say '  A  all of them'
    for ($k = 0; $k -lt 5; $k++) {
        $r = AskText "$q Type a number, several like 1,3, or A" '1'
        if ($r -match '^(a|all)$') { return ,@($items) }
        $out = @(); $ok = $true
        foreach ($x in ($r -split '[,\s]+')) {
            if (-not $x) { continue }
            $n = 0
            if ([int]::TryParse($x, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) {
                if ($out -notcontains $items[$n - 1]) { $out += $items[$n - 1] }
            } else { $ok = $false }
        }
        if ($ok -and $out.Count) { return ,$out }
        Say 'Please type the numbers shown (like 1 or 1,3), or A.' 'Yellow'
    }
    return ,@($items[0])
}
function Get-RunningThetis {
    # every running Thetis.exe with its path (Thetis, Thetis HL2 and SDR-VST3 all run as Thetis.exe)
    $r = @()
    try { $r = @(Get-Process -Name Thetis -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Path) { $_.Path } else { '?' } }) } catch { }
    return ,$r
}
# ---- a knob program that is already running --------------------------------
function Test-KnobRunning {
    $o = Invoke-Py @($newPy, '--check-running')
    return ($script:PyExit -eq 3)
}
function Find-KnobProcs {
    # the python process running flexknob_thetis.py and the window (cmd /k) that started it
    $skip = '--selftest|--check-running|--find-knob|--bridge-knob'
    $exe = '^(python[0-9.]*|pythonw|py|pyw|cmd)(\.exe)?$'
    $res = @()
    try {
        $res = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                $_.CommandLine -and $_.CommandLine -like '*flexknob_thetis.py*' -and $_.CommandLine -notmatch $skip -and $_.Name -match $exe -and $_.ProcessId -ne $PID } |
            ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; Name = $_.Name; Cmd = $_.CommandLine } })
    } catch { }
    return $res
}
function Stop-OldKnob {
    if (-not (Test-KnobRunning)) { return $false }
    Say ''
    Say 'The knob program is running right now (an older copy).' 'Yellow'
    Say 'It has to be closed so the new version can start. Closing it does not change anything in Thetis.'
    $procs = @(Find-KnobProcs)
    if (-not (AskYN 'Close the running knob program now?' $true)) {
        Say 'OK - close the knob window yourself (click it, press Q) before you start the new version.' 'Yellow'
        return $false
    }
    if ($procs.Count -eq 0) {
        Say 'Could not find its window automatically. Please close it now (click its window, press Q).' 'Yellow'
        for ($i = 0; $i -lt 60 -and (Test-KnobRunning); $i++) { Start-Sleep -Seconds 1 }
    } else {
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Say ("  closed " + $p.Name + " (process " + $p.Id + ")") }
            catch { Say ("  could not close process " + $p.Id + ": " + $_.Exception.Message) 'Yellow' }
        }
        for ($i = 0; $i -lt 10 -and (Test-KnobRunning); $i++) { Start-Sleep -Milliseconds 500 }
    }
    if (Test-KnobRunning) {
        Say 'The old knob program is still running. Close it yourself (press Q in its window) and start the new one afterwards.' 'Yellow'
        return $false
    }
    Say 'The old knob program is closed.' 'Green'
    return $true
}
function Get-Old($text, $name) {
    $m = [regex]::Match($text, '(?m)^set "' + $name + '=([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# =========================================================================
$log = Join-Path ([IO.Path]::GetTempPath()) 'flexknob_install_log.txt'
try { Start-Transcript -Path $log -Force | Out-Null } catch { }

Clear-Host
Say '==========================================================' 'Cyan'
Say '   FlexControl Knob for Thetis - one-click installer' 'Cyan'
Say '==========================================================' 'Cyan'
Say ''
Say 'This sets up the program that lets the FlexRadio FlexControl'
Say 'USB tuning knob control Thetis, Thetis HL2 or SDR-VST3.'
Say 'No amplifier is needed. It asks a few short questions.'
Say 'Press Enter to accept the answer shown in [brackets].'
Say 'Nothing is changed until you confirm the install folder.'
Say ''
Say 'NO WARRANTY - USE AT YOUR OWN RISK. This program is shared by one radio' 'Yellow'
Say 'operator, as is. There is no warranty of any kind. TUNE and MOX on the knob' 'Yellow'
Say 'really transmit; you are responsible for your station and your license.' 'Yellow'

# ---- unpack the files that travel inside this installer -------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('flexknob_pkg_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$all = [IO.File]::ReadAllText($env:FLEXKNOB_INSTALLER)
$b0 = $all.IndexOf("`n#PAYLOAD-BEGIN")
$b1 = $all.IndexOf("`n#PAYLOAD-END")
if ($b0 -lt 0 -or $b1 -lt 0) { throw 'This installer file looks damaged (no payload). Please download it again.' }
$b64 = $all.Substring($b0 + 15, $b1 - $b0 - 15) -replace '\s', ''
$zip = Join-Path $tmp 'pkg.zip'
[IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$pk = Join-Path $tmp 'files'
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $pk)
$newPy = Join-Path $pk 'flexknob_thetis.py'
$newVer = ([regex]::Match([IO.File]::ReadAllText($newPy), '(?m)^VERSION = "([\d.]+)"')).Groups[1].Value
Say ("This installer contains version $newVer.") 'Gray'

# ---- 1. Python ---------------------------------------------------------------
Head 'Step 1 of 6: Python'
$py = Find-Python
if (-not $py) {
    Say 'Python 3.8 or newer was not found on this computer. The knob program needs it.' 'Yellow'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget -and $script:IsWin -and -not $script:Test) {
        if (AskYN 'Install Python now with Windows (winget)? About 100 MB, free.' $true) {
            try {
                & winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
                $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
                $py = Find-Python
            } catch { Say "The automatic install did not finish: $($_.Exception.Message)" 'Yellow' }
        }
    }
    if (-not $py) {
        Say ''
        Say 'Please install Python yourself, then run this installer again:' 'Yellow'
        Say '  1. Go to https://www.python.org/downloads/ and download Python 3.'
        Say '  2. Run it and TICK "Add python.exe to PATH" on the first screen.'
        Say '  3. Double-click this installer again.'
        if (-not $script:Test -and $script:IsWin) { if (AskYN 'Open the download page now?' $true) { Start-Process 'https://www.python.org/downloads/' } }
        Pause-Key
        try { Stop-Transcript | Out-Null } catch { }
        exit 2
    }
}
$script:PyCmd = $py.cmd
Say ("Found $($py.ver)  (command: $($py.cmd))") 'Green'

# pyserial: the serial-port helper that reads the knob. The knob cannot work without it.
$chk = Invoke-Py @('-c', 'import serial;print(serial.__version__)')
if ($chk -match '(?m)^\s*(\d+\.\d+\S*)\s*$') { Say ("pyserial $($Matches[1]) is already installed.") 'Green' }
elseif ($script:Test -and $env:FLEXKNOB_TEST_NOPIP) { Say '(test mode: pyserial install skipped)' }
else {
    Say 'Installing pyserial (the small helper that reads the knob; needs internet)...'
    $o = Invoke-Py @('-m', 'pip', 'install', '--user', '--quiet', '--disable-pip-version-check', 'pyserial')
    $chk = Invoke-Py @('-c', 'import serial;print(serial.__version__)')
    if ($chk -notmatch '(?m)^\s*\d+\.\d+\S*\s*$') {   # some Python setups refuse --user: try the normal way
        $o = Invoke-Py @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', 'pyserial')
        $chk = Invoke-Py @('-c', 'import serial;print(serial.__version__)')
    }
    if ($chk -match '(?m)^\s*(\d+\.\d+\S*)\s*$') { Say ("pyserial $($Matches[1]) installed.") 'Green' }
    else {
        Say 'pyserial could not be installed (no internet, or pip is missing).' 'Red'
        Say 'The knob program cannot read the knob without it. Connect to the internet and later run:' 'Yellow'
        Say '    py -m pip install pyserial' 'Yellow'
        $last = @($o -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2)
        foreach ($l in $last) { Say ('  ' + $l.Trim()) }
    }
}

# ---- 2. Where to install ------------------------------------------------------
Head 'Step 2 of 6: Install folder'
$SUB = 'FlexKnob_for_Thetis'
$def = 'C:\RadioScripts'
if ($env:FLEXKNOB_TEST_DIR) { $def = $env:FLEXKNOB_TEST_DIR }
Say 'Choose the folder for your radio programs. The knob program gets its OWN subfolder in it,'
Say "named $SUB, so its files never mix with your other programs."
Say 'Do not use "Program Files" (Windows blocks the log and settings there).'
$dir = ''; $base = ''
while (-not $dir) {
    $d = AskText 'Folder' $def
    $d = $d.Trim('"').TrimEnd('\')
    if ($d -match '(?i)\\Program Files') { Say 'Please choose another folder (not Program Files).' 'Yellow'; continue }
    if ((Split-Path $d -Leaf) -ieq $SUB) { $b = Split-Path $d -Parent; $sd = $d } else { $b = $d; $sd = Join-Path $d $SUB }
    if (-not (Test-Path $b)) {
        if (-not (AskYN "The folder $b does not exist. Create it?" $true)) { continue }
        try { New-Item -ItemType Directory -Path $b -Force | Out-Null } catch { Say "Could not create it: $($_.Exception.Message)" 'Yellow'; continue }
    }
    try {
        if (-not (Test-Path $sd)) { New-Item -ItemType Directory -Path $sd -Force | Out-Null }
        $t = Join-Path $sd '.write_test'; [IO.File]::WriteAllText($t, 'x'); Remove-Item $t -Force
    } catch { Say 'That folder is not writable. Choose another.' 'Yellow'; continue }
    $dir = $sd; $base = $b
}
Say "The knob program goes into:  $dir" 'Green'
$script:WasRunning = Stop-OldKnob

$destPy = Join-Path $dir 'flexknob_thetis.py'
$launcher = Join-Path $dir 'start_flexknob.bat'
$settingsFile = Join-Path $dir 'flexknob_settings.json'
$setupPy = Join-Path $dir 'flexknob_thetis_setup.py'
$oldBat = $null; $keep = $false
if (Test-Path $destPy) {
    $oldVer = ([regex]::Match([IO.File]::ReadAllText($destPy), '(?m)^VERSION = "([\d.]+)"')).Groups[1].Value
    Say ("An earlier install (version $oldVer) is in this folder. It will be upgraded to $newVer.") 'Yellow'
    Say 'Your settings and log files are kept. The old program is saved as a .bak copy.'
    if (-not (AskYN 'Continue?' $true)) { Say 'Cancelled. Nothing was changed.'; Pause-Key; exit 0 }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item $destPy ($destPy + '.' + $stamp + '.bak') -Force
    if (Test-Path $launcher) {
        $oldBat = [IO.File]::ReadAllText($launcher)
        Copy-Item $launcher ($launcher + '.' + $stamp + '.bak') -Force
        $keep = AskYN 'Keep your current start options and Thetis choices (skips the questions in Step 4)?' $true
    }
}
Copy-Item $newPy $destPy -Force
foreach ($f in @('flexknob_thetis_setup.py', 'FlexKnob_Help.html', 'LICENSE.txt')) {
    Copy-Item (Join-Path $pk $f) (Join-Path $dir $f) -Force
}
# the double-click files
foreach ($nm in @('Setup_Thetis_Window', 'Undo_Thetis_Window', 'Find_My_Knob', 'Open_Knob_Panel')) {
    $bt = [IO.File]::ReadAllText((Join-Path $pk ($nm + '.template.bat'))).Replace('@@PYCMD@@', $script:PyCmd)
    [IO.File]::WriteAllText((Join-Path $dir ($nm + '.bat')), $bt)
}
Say "Program files copied to $dir" 'Green'

# ---- 3. Other programs that use the knob ----------------------------------------
Head 'Step 3 of 6: Only one program can use the knob'
Say 'The knob can be opened by ONE program at a time. If another program has it,'
Say 'this one will say "in use by another program" and the knob will not work here.'
Say 'Programs that can use the knob: DDUtil, and the KPA1500 Thetis Bridge (its knob feature).'
$bridgeDir = ''
foreach ($cand in @((Join-Path $base 'KPA1500_Thetis_Bridge'), $base)) {
    if (Test-Path -LiteralPath (Join-Path $cand 'kpa1500_thetis_bridge.py')) { $bridgeDir = $cand; break }
}
if ($env:FLEXKNOB_TEST_BRIDGE) { $bridgeDir = $env:FLEXKNOB_TEST_BRIDGE }
if (-not $bridgeDir) {
    if (AskYN 'Do you also have the KPA1500 Thetis Bridge installed on this computer?' $false) {
        $bd = AskText 'Its folder (the one that holds kpa1500_thetis_bridge.py), or Enter to skip' ''
        $bd = $bd.Trim('"').TrimEnd('\')
        if ($bd -and (Test-Path -LiteralPath (Join-Path $bd 'kpa1500_thetis_bridge.py'))) { $bridgeDir = $bd }
        elseif ($bd) { Say 'kpa1500_thetis_bridge.py is not in that folder - skipped.' 'Yellow' }
    }
}
if ($bridgeDir) {
    Say "KPA1500 Thetis Bridge found in: $bridgeDir" 'Green'
    $bset = Join-Path $bridgeDir 'kpa1500_settings.json'
    $bst = ((Invoke-Py @($destPy, '--bridge-knob-status', $bset)) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($bst -eq 'OFF') {
        Say 'The knob is already switched OFF in the bridge. Good - nothing to do.' 'Green'
    } else {
        Say 'The bridge has its own knob feature, and it is ON. Both cannot use the knob at once.' 'Yellow'
        $bridgeUp = $false
        $bridgePy = Join-Path $bridgeDir 'kpa1500_thetis_bridge.py'
        if ($env:FLEXKNOB_TEST_BRIDGE_RUNNING) { $bridgeUp = $true }
        else { $o = Invoke-Py @($bridgePy, '--check-running'); $bridgeUp = ($script:PyExit -eq 3) }
        if ($bridgeUp) {
            Say 'The bridge is running right now, so its settings cannot be changed from here.' 'Yellow'
            Say 'Turn its knob off yourself (about 1 minute):'
            Say '  1. Open your browser and go to  http://127.0.0.1:8080  (the bridge panel).'
            Say '  2. Click Settings, then find "FlexControl tuning knob".'
            Say '  3. Set the "Knob" drop-down to  Off (not used).  It saves by itself and works at once.'
            Say '     (No need to close the bridge.) Then start the knob program here.'
        } elseif (AskYN 'Switch the knob OFF in the bridge for you now? (everything else in the bridge stays as it is)' $true) {
            $o = Invoke-Py @($destPy, '--bridge-knob-off', $bset)
            if ($script:PyExit -eq 0) { Say ('Done: ' + ($o.Trim())) 'Green' }
            else { Say ('Not changed: ' + ($o.Trim())) 'Yellow'; Say 'Turn it off in the bridge panel instead: Settings > FlexControl tuning knob > Knob > Off (not used).' }
            Say 'To use the bridge''s knob again later: choose "Find it automatically" in that same place.'
        } else {
            Say 'OK. Before you use the knob here, turn it off in the bridge panel:' 'Yellow'
            Say '  http://127.0.0.1:8080 > Settings > FlexControl tuning knob > Knob > Off (not used)'
        }
    }
} else {
    Say 'No KPA1500 Thetis Bridge found - nothing to switch off.' 'Gray'
}
Say 'If you use DDUtil with this knob, remove the knob from DDUtil (or close DDUtil) first.'

# ---- 4. Thetis, start file, shortcuts --------------------------------------------
Head 'Step 4 of 6: Thetis, the start file and shortcuts'
$flags = ''
$startThetis = '0'; $thetisExe = 'C:\Program Files\OpenHPSDR\Thetis\Thetis.exe'; $thetisFlags = ''
if ($keep) {
    $flags = (Get-Old $oldBat 'KNOB_FLAGS')
    $startThetis = Get-Old $oldBat 'START_THETIS'
    $te = Get-Old $oldBat 'THETIS_EXE'; if ($te) { $thetisExe = $te }
    $tf = Get-Old $oldBat 'THETIS_FLAGS'; if ($tf) { $thetisFlags = $tf }
    Say 'Keeping your earlier start options.' 'Green'
} else {
    Say 'Thetis must have its TCI server switched on (the knob program talks to Thetis through it):'
    Say '  In Thetis: Setup > Serial/Network/Midi CAT > Network: tick "TCI Server Running",'
    Say '  Bind IP:Port 127.0.0.1:50001, click Apply, then OK.'
    $progs = @((Get-Programs) | Where-Object { $_.Exe })
    if ($progs.Count -eq 0) {
        $found = Find-Thetis
        if ($found) { $progs = @([pscustomobject]@{ Key = 'thetis'; Name = 'Thetis'; Db = ''; Exe = $found }) }
    }
    if ($progs.Count -gt 0) {
        Say 'Found on this computer:' 'Green'
        foreach ($p in $progs) { Say ('  ' + $p.Name + ':  ' + $p.Exe) 'Green' }
        if (AskYN 'Should the start file also launch one of them (after starting the knob program)?' $false) {
            $pick = Pick-One $progs 'Which one should the start file launch?'
            $startThetis = '1'; $thetisExe = $pick.Exe
            if ($pick.Key -eq 'hl2') { $thetisFlags = '-dbid:HL2' } else { $thetisFlags = '' }
            Say ('The start file will launch ' + $pick.Name + '.') 'Green'
        }
        else { $thetisExe = $progs[0].Exe }
    } else {
        Say 'Thetis was not found automatically. That is fine: start it the way you always do.'
    }
}
$tpl = [IO.File]::ReadAllText((Join-Path $pk 'start_flexknob.template.bat'))
$tpl = $tpl.Replace('@@KNOB_DIR@@', $dir).Replace('@@PYCMD@@', $script:PyCmd).Replace('@@KNOB_FLAGS@@', ([string]$flags).Trim())
$tpl = $tpl.Replace('@@START_THETIS@@', $startThetis).Replace('@@THETIS_EXE@@', $thetisExe).Replace('@@THETIS_FLAGS@@', $thetisFlags)
[IO.File]::WriteAllText($launcher, $tpl)
Say "Start file written: $launcher" 'Green'

if ($script:IsWin -and -not $script:Test) {
    $lnkD = Join-Path ([Environment]::GetFolderPath('Desktop')) 'FlexKnob for Thetis.lnk'
    $lnkS = Join-Path ([Environment]::GetFolderPath('Startup')) 'FlexKnob for Thetis.lnk'
    foreach ($l in @($lnkD, $lnkS)) {
        if (Test-Path -LiteralPath $l) {
            try { New-Shortcut $l $launcher $dir 'Start FlexControl Knob for Thetis'; $script:Made += $l; Say "Shortcut updated: $l" 'Green' } catch { }
        }
    }
    if ((Test-Path -LiteralPath $lnkD) -and ($script:Made -contains $lnkD)) { }
    elseif (AskYN 'Put a "FlexKnob for Thetis" shortcut on the Desktop?' $true) {
        try {
            New-Shortcut $lnkD $launcher $dir 'Start FlexControl Knob for Thetis'
            $script:Made += $lnkD; Say 'Desktop shortcut created.' 'Green'
        } catch { Say "Could not create the shortcut: $($_.Exception.Message)" 'Yellow' }
    }
    if ((Test-Path -LiteralPath $lnkS) -and ($script:Made -contains $lnkS)) { }
    elseif (AskYN 'Start the knob program automatically when you sign in to Windows?' $false) {
        try {
            New-Shortcut $lnkS $launcher $dir 'Start FlexControl Knob for Thetis at sign-in'
            $script:Made += $lnkS; Say 'Auto-start set up. (To undo: delete that shortcut from the Startup folder.)' 'Green'
        } catch { Say "Could not create the auto-start shortcut: $($_.Exception.Message)" 'Yellow' }
    }
}

# uninstaller
$un = @('@echo off', 'title Uninstall FlexControl Knob for Thetis', 'cd /d "%~dp0"', 'echo This removes the FlexKnob for Thetis shortcuts,',
    'echo and (if you agree) the FlexControl Knob window in Thetis and the program''s own files.', 'echo A running knob program is closed for you; the Thetis step offers to close Thetis.', 'echo.', 'pause',
    ('powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ''*flexknob_thetis.py*'' -and $_.Name -match ''^(python|pythonw|py|pyw|cmd)'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1'),
    'if not exist flexknob_thetis_setup.py goto nothetis',
    'set /p RMT=Also remove the FlexControl Knob window from Thetis? (y/N): ',
    ('if /i "%RMT%"=="y" ' + $script:PyCmd + ' flexknob_thetis_setup.py --remove'),
    ':nothetis')
foreach ($l in $script:Made) { $un += ('del "{0}" 2>nul' -f $l) }
$un += 'echo Shortcuts removed.'
$un += 'echo.'
$un += 'echo This folder may hold other programs too: ONLY the knob program''s own files can be deleted,'
$un += 'echo never the folder or anything else in it. Thetis backups (thetis_backups) are kept.'
$un += 'set /p DEL=Delete the knob program''s own files (program, help, settings, logs)? (y/N): '
$un += 'if /i not "%DEL%"=="y" goto keep'
foreach ($f in @('flexknob_thetis.py', 'flexknob_thetis_setup.py', 'FlexKnob_Help.html', 'start_flexknob.bat',
        'Setup_Thetis_Window.bat', 'Undo_Thetis_Window.bat', 'Find_My_Knob.bat', 'Open_Knob_Panel.bat',
        'flexknob_settings.json', 'flexknob.log', 'flexknob.log.old', 'install_log.txt', 'install_selftest.txt', 'LICENSE.txt')) { $un += ('del "%~dp0' + $f + '" 2>nul') }
$un += 'del "%~dp0flexknob_thetis.py.*.bak" 2>nul'
$un += 'del "%~dp0start_flexknob.bat.*.bak" 2>nul'
$un += 'echo The knob program files are deleted. Other files in the folder were not touched.'
$un += 'echo This uninstaller removes itself now.'
$un += 'pause'
$un += 'start "" cmd /c "timeout /t 2 >nul & del ""%~f0"" & rmdir ""%~dp0."" 2>nul"'
$un += 'exit /b'
$un += ':keep'
$un += 'echo Files kept. You can delete them yourself later.'
$un += 'pause'
[IO.File]::WriteAllText((Join-Path $dir 'Uninstall_FlexKnob_for_Thetis.bat'), ($un -join "`r`n") + "`r`n")

# ---- 5. Self-test -------------------------------------------------------------------
Head 'Step 5 of 6: Quick self-test'
if (AskYN 'Run a quick self-test of the program now (about 30 seconds, uses a pretend knob and a pretend Thetis)?' $true) {
    Say 'Testing...'
    $o = Invoke-Py @($destPy, '--selftest')
    $tail = ($o -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    [IO.File]::WriteAllText((Join-Path $dir 'install_selftest.txt'), $o)
    if ($o -match 'ALL TESTS PASSED') { Say $tail 'Green' }
    else {
        Say 'The self-test did not fully pass. The program may still work; details are in install_selftest.txt.' 'Yellow'
        $bad = @($o -split "`r?`n" | Where-Object { $_ -match 'FAIL\]|Traceback|Error' } | Select-Object -First 8)
        foreach ($l in $bad) { Say ('  ' + $l.Trim()) }
        Say 'Please send the file install_selftest.txt (in the install folder) to whoever gave you this installer.'
    }
}

# ---- 6. The window inside Thetis ------------------------------------------------------------
Head 'Step 6 of 6: the knob window inside Thetis (optional)'
Say 'The program can show a small window INSIDE Thetis, Thetis HL2 or SDR-VST3 that says what'
Say 'the knob does right now and what each button does. It is optional: the same information'
Say 'is always on the browser panel (http://127.0.0.1:8090).'
Say 'This step adds the window to the program''s settings for you. A backup of those settings'
Say 'is saved first, and Undo_Thetis_Window.bat puts it back at any time.'
$thetisDone = $false
if ($script:Test -and -not $env:FLEXKNOB_TEST_DB -and -not $env:FLEXKNOB_TEST_PROGRAMS) {
    Say '(test mode: Thetis step skipped)'
}
else {
    $sa = @($setupPy)
    $chosen = @()
    if ($env:FLEXKNOB_TEST_DB) {
        $chosen = @([pscustomobject]@{ Key = 'thetis'; Name = 'Thetis'; Db = $env:FLEXKNOB_TEST_DB; Exe = '' })
    } else {
        $have = @((Get-Programs) | Where-Object { $_.Db })
        if ($have.Count -eq 0) {
            Say ''
            Say 'No Thetis settings were found yet. Start Thetis (or Thetis HL2 / SDR-VST3) once, set up' 'Yellow'
            Say 'the radio, close it, then double-click Setup_Thetis_Window.bat in the install folder.' 'Yellow'
        } elseif ($have.Count -eq 1) {
            if (AskYN ('Add the knob window to ' + $have[0].Name + ' now?') $true) { $chosen = @($have[0]) }
        } else {
            Say ''
            Say 'These programs are on this computer:'
            if (AskYN 'Add the knob window now?' $true) {
                $chosen = @(Pick-Many $have 'Which ones?')
            }
        }
    }
    if ($chosen.Count -eq 0) {
        Say 'OK. Later: close the program and double-click Setup_Thetis_Window.bat in the install folder.'
    } else {
        $names = ($chosen | ForEach-Object { $_.Name }) -join ', '
        Say ('Setting up: ' + $names) 'Green'
        if ($env:FLEXKNOB_TEST_DB) { $sa += @('--db', $env:FLEXKNOB_TEST_DB, '--yes', '--skip-running-check') }
        else { $sa += @('--program', (($chosen | ForEach-Object { $_.Key }) -join ',')) }
        if ($env:FLEXKNOB_TEST_PROGRAMS) { $sa += @('--yes', '--skip-running-check') }
        $sa += '--no-restart'          # the program is started at the very end, after the last question
        # is one of the chosen programs open? (told apart by folder: all of them run as Thetis.exe)
        $open = $null
        foreach ($rp in (Get-RunningThetis)) {
            foreach ($c in $chosen) {
                if ($rp -eq '?' -or ($c.Exe -and ((Split-Path $rp) -ieq (Split-Path $c.Exe)))) { $open = @($rp, $c); break }
            }
            if ($open) { break }
        }
        if ($env:FLEXKNOB_TEST_THETIS) { $open = @('test', $chosen[0]) }
        if ($open) {
            if ($open[0] -ne '?' -and $open[0] -ne 'test') {
                $script:ThetisRestart = $open[0]; $script:ThetisRestartName = $open[1].Name
                if ($open[1].Key -eq 'hl2') { $script:ThetisRestartArgs = '-dbid:HL2' }
            }
            Say ''
            Say ($open[1].Name + ' is running. It must be closed for this step, because it saves its own settings') 'Yellow'
            Say 'when it closes and would overwrite the new window.' 'Yellow'
            if (AskYN ('Close ' + $open[1].Name + ' for you now? It closes the normal way and saves its settings (like File > Exit). Make sure the radio is not transmitting.') $true) {
                $sa += '--close-thetis'
                Say 'It will be closed. You can start it again at the very end of the installer.'
            } else {
                Say 'OK - the setup will wait while you close it yourself (File > Exit).' 'Yellow'
            }
        }
        Say ''
        $ErrorActionPreference = 'Continue'
        $parts = @($script:PyCmd -split ' ')
        $pre = @(); if ($parts.Count -gt 1) { $pre = $parts[1..($parts.Count - 1)] }
        & $parts[0] @pre @sa
        $rc = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($rc -eq 0) { $thetisDone = $true; $doneNames = $names; Say ('The knob window is set up in: ' + $names) 'Green' }
        else { Say 'The window was not added everywhere (see the messages above). Run Setup_Thetis_Window.bat later.' 'Yellow' }
    }
}

try { Stop-Transcript | Out-Null; Copy-Item $log (Join-Path $dir 'install_log.txt') -Force } catch { }
try { Remove-Item $tmp -Recurse -Force } catch { }

Head 'All done'
Say "Installed in:   $dir" 'Green'
Say ("Start it with: " + $launcher + $(if ($script:Made.Count) { '   (or the Desktop shortcut)' } else { '' })) 'Green'
Say 'Browser panel: http://127.0.0.1:8090   (choose what each press does; the program must be running)'
Say 'Help file:     FlexKnob_Help.html  (in the install folder)'
if ($thetisDone) {
    Say ('Window added: ' + $doneNames + ' - start it and the "FlexControl Knob" window appears.') 'Green'
    Say '               Move/resize it where you like; Thetis remembers. The knob program must be running.'
} else {
    Say 'Thetis window: optional - double-click Setup_Thetis_Window.bat (with Thetis closed) to add it.'
}
Say 'Is the knob seen? Double-click Find_My_Knob.bat.'
Say 'Undo:          Undo_Thetis_Window.bat puts back the Thetis settings saved before the setup.'
Say 'To remove:     run Uninstall_FlexKnob_for_Thetis.bat in the install folder.'
Say ''
Say 'Remember: only ONE program can use the knob. If the bridge''s knob is ON, switch it off (see Step 3).' 'Yellow'
if ($script:IsWin -and -not $script:Test) {
    # all questions first, then start the programs: once a program opens it takes the focus
    Say ''
    if ($script:WasRunning) { Say 'The old knob program was closed for the update - start the new one now.' 'Yellow' }
    $goKnob = $false; $goThetis = $false
    if (Test-KnobRunning) { Say 'A knob program is still running, so the new one cannot start yet: close it first (press Q in its window).' 'Yellow' }
    else { $goKnob = AskYN 'Start the knob program now (and open its panel in your browser)?' $true }
    $thPath = $script:ThetisRestart
    if ($goKnob -and $startThetis -eq '1') { $thPath = $null }   # the start file launches the program itself
    $thOpen = $false
    try { $thOpen = [bool](Get-Process -Name Thetis -ErrorAction SilentlyContinue) } catch { }
    if ($thPath -and -not $thOpen -and (Test-Path -LiteralPath $thPath)) { $goThetis = AskYN ('Start ' + $script:ThetisRestartName + ' now?') $true }
    $goHelp = AskYN 'Open the help file now?' $false
    Say ''
    Say 'Starting what you chose. This window closes by itself in a minute.' 'Green'
    if ($goKnob) {
        Start-Process -FilePath $launcher -WorkingDirectory $dir
        Start-Sleep -Seconds 4
        Start-Process 'http://127.0.0.1:8090'
    }
    if ($goThetis) {
        if ($script:ThetisRestartArgs) { Start-Process -FilePath $thPath -WorkingDirectory (Split-Path $thPath) -ArgumentList $script:ThetisRestartArgs }
        else { Start-Process -FilePath $thPath -WorkingDirectory (Split-Path $thPath) }
    }
    if ($goHelp) { Start-Sleep -Seconds 1; Start-Process (Join-Path $dir 'FlexKnob_Help.html') }
}
exit 0
#PS1-END
#PAYLOAD-BEGIN
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
PmO6cro7g8Ov21vW91fvzeuc9tcH56/W3D+86N291XeH7bfdp/Htw1NwMrntdYLGem/3ab15GT26
5ze1p8nTwcO2583bp28Xrzs7e487N91Lv7//eDrfc5Smuhfr/uDU60fTcKfd6V7OHk62LO9uvdm8
32uOztud0q5/s16/OH84bpYOTpzaiXfzOLqYrp85/aBx3Z6ens++HimjnfW+29bl1sncvTn/erKv
NHXQninlnPHtK71y7r9eKQ/L60HXd2on0/ER7Q76u4/F8ZO73ek2vuyt378NeyMVwK3tzna77vrW
1/X986P7idKUUuz8/vbN+/pw3W6crl93HuYnzR2373Yv255z7DbXG1fOfdd/OuucrH/2Dw4OqtU1
nslkLZ1y8L19Sh0H7FjN7mbjbpPuel8uXr9aTql327CGX7avZledQTmYHTcvZo27m9fvje3R4cPx
8PotatKdclRicJTRsOHunu42vm+9nqgc6e1QJbTp1d35XeNzwzk6P/f9c3/UPZq4h7Uj3/nsDJxa
/+Tw7ry5tTlsegN3fnT3cPi5Hnbt3Y5K5N51WYFI1e3tZrtdsu9O7p++9s/PlOf1w2C25XRKalce
9r469tnTdeT0h+s7r73u02v/ZPrWV7mESjTlp8eTo1e3ZD3S/peH6YO9643c2++NyKFbT1dXV2ef
3bfXs/HBY7l3te0dNUu2c3F1vNe7uj7sT+/XR6WvT1+cL/7j5ZfZ3Bq9tf37bZXytp7WuyN/du10
G6PNYPexHgy+d+7H1tN8p3NQ21sf0purt6+Hxeti+fphttt/ujp9LJcaX+yHrw/fv1La+XxzptKp
fdHffb0Inq4bs+brGVWauuw89NfD4c7MnVn9evjwMDyzds92PvulpgrA8o8/+/Nwsjt6cq7r7eOD
we3669u0MS1frtf7p1vRqKti80SuMHWf6r98j5RSu5eXD/2tV9c/HO7UhsqL0l53P7x0gpAW7+t7
s/pB6B7ae0/33enWemlv77T7ueiMtr4/XmzZe6flLXpPOw/0uqs0VbyYjF9PDu/odPOzPRo9Xt/N
HpzyYdNyHtyiSiL2U1g8fTr+fPekUoPrX14W7w5qu6eb35vbT3c3s9tg07t/LV0N6eP6drepNLXz
eD68exqP1l+jwenbNS0+nEyLB3vRzfrR7LQejB+m3skW3Tq3r6zGcbfcPenWx1/v2mdvd+fFxuBk
/Ll7Phl404Mvu0df3956s4Pea+0iaI92zk772xd7Kpv9fvc03go/b3a/jPu1u+3g82b/eOp3arsX
T3Z09+aedL6WHh4e1IHUD/YPrr7cWTfNbf/4uH9SKx9/Dr7sjW6nvcsv3c31wcGk19vrbl473zdV
oWzSqNHpydeLwWO5/fmNlk6eTrqPj/36bvegU7zYubRqZ71j/+r16KztP83Oik/dyXa9dni8/WV+
8P31pHHS2K9HbadZrJVrtUZw2Bi9zb/03Ltp/Smydzu36lxtDqLr/s3JYftsfXt2fDzYvKh3tjZv
yvuXu7sH10/Fyd7rYTm6vb3f33+cXNze3w1P/X40LO+MDhtf7r5eXtr04vpG5SvXb6PHr+3NoH05
Hl0oTY3c24vN4eedzmZo17+cuN9VXF02v547T9Ony73N3YcvwclZ0XZLR9bXk8/Xl8cPn/3b2dbV
SeP4+9HnDt0d79Zfm9Pdm+ZeqWTvTJ4u2nu3b+ruaz91Tp8+n47e6PYTfdsZ04b9+eJL7eFicPh9
8/sejbrN43K/63zvD6bHdmNv3tjaPC8/uftXO6XDsx3n/7X3pT+OItm+3+evaOWXvleOaRHBXtLo
CWyDFww2GLyMRinAbGY1i224mv/9yZm2k8zKzMqqtt+796qr1OXONHCIiPM7e5xwtE4ZOCqXyapP
Dzp2vE71GRViabQuD/DYFkzTuWeynRFvK4G44+eCsh3uV67R6+ho3J1pwlZoi/phZ6tG5PI4Fo/r
2Nv3p7jene+1+UwypWJ2kPxcWE5g5g5WYyEj1X9abQhfHiKJqiypdXSEqrMtrFkkdzm0OBylqJgr
BNNFo3kaC1FeId5ZzVxB6WKHsV5RU8M8DqkxHFYRb1pH3dhr4kyhKyo3j/x88c8WqZc3XvNty3k6
dA1YN6w9mviQ7u77eT9hzXqiS9083siWySWyHfJkR+GxeerYUW8OO4YiRwN7lwz7FV3odEfP2hy4
Gi8MIpdj0TLZttDUyUkwXsGVxlEQGevc2hEEnaXbsLuaSj2eGRVOoDvNqFlF/VUyzRt9NDeUWjAl
nXTlaJakblKy2aK9Vmw1KLBNXnT4prHHR6cipYOI99MUDZKU5FHedc1U3WVjTp3VsrCdd2VJrMJs
JNZqWMtLmR+qm9BxttrOd+Qtti9tMhp1mCJLhpBpy0AnsdiyXhWwI1t7rbs+wHyor5yFqDCYJHZW
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
#PAYLOAD-END
