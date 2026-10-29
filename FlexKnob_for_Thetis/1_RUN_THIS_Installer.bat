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
Say 'NO WARRANTY - USE AT YOUR OWN RISK. This program is shared free by one radio' 'Yellow'
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
#PAYLOAD-END
