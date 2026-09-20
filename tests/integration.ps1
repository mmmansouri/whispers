<#
.SYNOPSIS
    End-to-end tests for Whispers: drives the real product on this machine.

.DESCRIPTION
    Launches Whispers, presses the hotkey for real through keybd_event,
    and asserts on what lands in the log. This is the only level at which
    the interesting failures show up - process lifetimes, model loading,
    thread interruption, orphaned recorders - because none of them exist
    in the pure core the unit tests cover.

    It cannot run in continuous integration: it needs a microphone, a GPU
    and a model on disk. It is a local command.

    While it runs it takes over the hotkey and synthesises key presses.
    It therefore forces AutoPaste off for the duration, so a transcription
    can never be pasted into whatever window happens to have focus. Your
    own settings are backed up and restored, including after a failure.

.EXAMPLE
    pwsh -File tests\integration.ps1
#>
[CmdletBinding()]
param(
    [string]$Ahk = "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
    [int]$HoldSeconds = 3
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $env:APPDATA 'Whispers'
$ini     = Join-Path $dataDir 'Whispers.ini'
$logFile = Join-Path $dataDir 'logs\whispers.log'
$srvLog  = Join-Path $dataDir 'logs\server.log'
$backup  = Join-Path $env:TEMP 'Whispers.ini.integration-backup'

$script:Pass = 0
$script:Fail = 0

function Ok($what)   { $script:Pass++; Write-Host "  ok   $what" -ForegroundColor DarkGray }
function Bad($what, $detail) {
    $script:Fail++
    Write-Host "  FAIL $what" -ForegroundColor Red
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkRed }
}
function Group($name) { Write-Host "`n--- $name ---" -ForegroundColor Cyan }

function AssertTrue($what, $cond, $detail) {
    if ($cond) { Ok $what } else { Bad $what $detail }
}
function AssertLog($what, $pattern) {
    $hit = Select-String -Path $logFile -Pattern $pattern -EA SilentlyContinue
    AssertTrue $what ($null -ne $hit) "pattern not found in the log: $pattern"
}
function RefuteLog($what, $pattern) {
    $hit = Select-String -Path $logFile -Pattern $pattern -EA SilentlyContinue
    AssertTrue $what ($null -eq $hit) "pattern should be absent but matched: $($hit.Line -join '; ')"
}

function StopEverything {
    Get-Process AutoHotkey64, whisper-server, ffmpeg -EA SilentlyContinue |
        Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 800
}

# Waits for a log line instead of sleeping a fixed amount: a cold model
# load takes seconds, a warm one milliseconds, and a fixed sleep would be
# either flaky or needlessly slow.
function WaitForLog($pattern, $timeoutSec = 60, $atLeast = 1) {
    # Counts matches rather than testing for presence. Waiting for
    # "Transcribed via" after a second dictation would otherwise return
    # instantly on the FIRST dictation's line, and every assertion that
    # followed would run in the middle of the recording still in progress.
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $logFile) {
            $n = @(Select-String -Path $logFile -Pattern $pattern -EA SilentlyContinue).Count
            if ($n -ge $atLeast) { return $true }
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# $configured=1 is the normal case: every group below tests a machine
# that has already been set up. The one group that does not pass it is
# the one testing what a brand-new installation does.
#
# CheckUpdates=0 throughout: these tests must not depend on the network,
# and an update notice appearing mid-run would be noise.
function WriteIni($tier, $modelsDir, $configured = 1) {
    $lines = @('[Audio]', 'Mic=', '[Engine]', "Tier=$tier", 'Language=fr',
               'VramPolicy=idle', '[UI]', 'AutoPaste=0', 'PlaySounds=0',
               'ShowIndicator=0', 'CheckUpdates=0', "Configured=$configured")
    if ($modelsDir) { $lines += @('[Paths]', "ModelsDir=$modelsDir") }
    Set-Content -Path $ini -Value $lines -Encoding Ascii
}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WhispersFind {
  delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

  public static IntPtr ByTitle(string needle) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256);
      GetWindowText(h, sb, sb.Capacity);
      if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) {
        found = h; return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static bool Close(string needle) {
    IntPtr h = ByTitle(needle);
    if (h == IntPtr.Zero) return false;
    return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);  // WM_CLOSE
  }
}
'@ -EA SilentlyContinue

function WaitForWindow($needle, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ([WhispersFind]::ByTitle($needle) -ne [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function IniValue($section, $key) {
    $in = $false
    foreach ($line in (Get-Content $ini -EA SilentlyContinue)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $in = ($Matches[1] -eq $section); continue }
        if ($in -and $line -match "^\s*$key\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

function StartWhispers {
    Remove-Item $logFile -EA SilentlyContinue
    $p = Start-Process $Ahk -ArgumentList (Join-Path $root 'Whispers.ahk') -PassThru
    return $p
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WhispersKeys {
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  // dwExtraInfo must be zero: AutoHotkey tags and then ignores the events
  // its own Send produces, so a tagged press would never reach the hotkey.
  public static void Down(byte vk){ keybd_event(vk,0,0,UIntPtr.Zero); }
  public static void Up(byte vk){ keybd_event(vk,0,2,UIntPtr.Zero); }
}
'@ -EA SilentlyContinue

function Dictate($seconds) {
    [WhispersKeys]::Down(0x78)          # F9
    Start-Sleep -Seconds $seconds
    [WhispersKeys]::Up(0x78)
}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WhispersWin {
  delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

  // AutoHotkey's own Exit menu item. WM_CLOSE only hides the script's main
  // window; this is what actually ends the process - and, unlike
  // TerminateProcess, it lets OnExit run.
  const uint WM_COMMAND = 0x0111;
  const int  ID_FILE_EXIT = 65405;

  public static bool RequestExit(uint targetPid) {
    bool sent = false;
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != targetPid) return true;
      var sb = new StringBuilder(64);
      GetClassName(h, sb, sb.Capacity);
      if (sb.ToString() == "AutoHotkey") {
        PostMessage(h, WM_COMMAND, (IntPtr)ID_FILE_EXIT, IntPtr.Zero);
        sent = true;
      }
      return true;
    }, IntPtr.Zero);
    return sent;
  }
}
'@ -EA SilentlyContinue

# A graceful exit is the only one that runs OnExit. Stop-Process -Force
# calls TerminateProcess, which by design executes no cleanup code at all -
# asserting on VRAM release after a force kill would be testing Windows,
# not Whispers.
function RequestExit($proc) {
    $sent = [WhispersWin]::RequestExit([uint32]$proc.Id)
    if (-not $sent) { return $false }
    return $proc.WaitForExit(15000)
}

# =====================================================================
Write-Host "Whispers integration tests" -ForegroundColor White
Write-Host "==========================" -ForegroundColor White

# Preserve the real configuration before anything touches it.
$hadIni = Test-Path $ini
if ($hadIni) { Copy-Item $ini $backup -Force }
$modelsDir = ''
if ($hadIni) {
    $m = Select-String -Path $backup -Pattern '^ModelsDir=(.+)$' -EA SilentlyContinue
    if ($m) { $modelsDir = $m.Matches[0].Groups[1].Value.Trim() }
}

try {
    Group 'Preconditions'
    AssertTrue 'AutoHotkey v2 is present' (Test-Path $Ahk) $Ahk
    AssertTrue 'Whispers.ahk is present' (Test-Path (Join-Path $root 'Whispers.ahk')) $root
    AssertTrue 'versions.json is present' (Test-Path (Join-Path $root 'versions.json')) $root

    $binDir = Join-Path $root 'bin'
    AssertTrue 'whisper-server.exe is installed' (Test-Path (Join-Path $binDir 'whisper-server.exe')) $binDir
    AssertTrue 'whisper-cli.exe is installed' (Test-Path (Join-Path $binDir 'whisper-cli.exe')) $binDir
    AssertTrue 'ffmpeg.exe is installed' (Test-Path (Join-Path $binDir 'ffmpeg.exe')) $binDir

    if ($script:Fail -gt 0) {
        Write-Host "`nPreconditions failed - nothing else can be trusted." -ForegroundColor Red
        exit $script:Fail
    }

    # ---------------------------------------------------------------
    Group 'Startup and microphone detection'
    StopEverything
    WriteIni 'max' $modelsDir
    $app = StartWhispers

    AssertTrue 'the script starts' (WaitForLog 'started\. Root=' 20) 'no startup line in the log'
    AssertLog 'it reports its own root directory' ([regex]::Escape($root))
    AssertLog 'the tier resolves to a model file' 'Tier=max \(ggml-.*\.bin\)'
    RefuteLog 'versions.json resolves without error' 'cannot resolve tier'

    AssertTrue 'a microphone is chosen' (WaitForLog 'default capture device|auto-selected|no usable' 60) 'detection never finished'
    AssertLog 'it uses the Windows default rather than guessing' 'Using the Windows default capture device'
    RefuteLog 'it never falls back to a level-only guess here' 'chosen by level only'
    AssertTrue 'the hotkey is armed once a microphone is known' (WaitForLog 'Hotkey armed' 30) 'never armed'
    RefuteLog 'REGRESSION: the hotkey is never live while no microphone is set' 'ERROR. No microphone configured'

    # ---------------------------------------------------------------
    Group 'First dictation, cold model'
    Dictate $HoldSeconds
    AssertTrue 'a transcription completes' (WaitForLog 'Transcribed via' 120) 'no transcription line'
    AssertLog 'recording started' 'StartRec'
    AssertLog 'the model is warmed up during the recording, not after' 'Server starting via recording warmup'
    AssertLog 'recording stopped' 'StopRec'
    RefuteLog 'no capture failure' 'Mic capture failed'
    RefuteLog 'no conversion failure' 'WAV conversion failed'
    RefuteLog 'the CPU fallback is not needed' 'falling back to whisper-cli'

    $line = (Select-String -Path $logFile -Pattern 'Transcribed via server in (\d+) ms' | Select-Object -Last 1)
    if ($line) {
        $ms = [int]$line.Matches[0].Groups[1].Value
        Write-Host "         first dictation: $ms ms" -ForegroundColor DarkGray
        AssertTrue 'the resident server answers in under two seconds' ($ms -lt 2000) "$ms ms"
    } else {
        Bad 'a latency figure is recorded' 'no "Transcribed via server in N ms" line'
    }

    # ---------------------------------------------------------------
    Group 'Second dictation, warm model'
    $before = (Get-Content $logFile).Count
    Dictate $HoldSeconds
    AssertTrue 'a second transcription completes' (WaitForLog 'Transcribed via' 60 2) 'no second transcription'
    $tail = (Get-Content $logFile) | Select-Object -Skip $before
    AssertTrue 'the server is reused instead of restarted' `
        (($tail -match 'skipped - already running').Count -ge 1) ($tail -join ' | ')
    AssertTrue 'REGRESSION: no second server is spawned' `
        (($tail -match 'Server starting via').Count -eq 0) ($tail -join ' | ')

    # ---------------------------------------------------------------
    Group 'Process hygiene'
    $servers = @(Get-Process whisper-server -EA SilentlyContinue)
    AssertTrue 'exactly one whisper-server is running' ($servers.Count -eq 1) "$($servers.Count) found"
    $ffm = @(Get-Process ffmpeg -EA SilentlyContinue)
    AssertTrue 'REGRESSION: no recorder is left behind' ($ffm.Count -eq 0) "$($ffm.Count) found"

    # ---------------------------------------------------------------
    Group 'Tier switching'
    StopEverything
    WriteIni 'cpu' $modelsDir
    $app = StartWhispers
    AssertTrue 'it restarts on the cpu tier' (WaitForLog 'Tier=cpu' 20) 'tier not applied'
    AssertLog 'the cpu tier resolves to small, as measured' 'Tier=cpu \(ggml-small\.bin\)'
    AssertTrue 'REGRESSION: the hotkey is armed only once a microphone is known' `
        (WaitForLog 'Hotkey armed' 60) 'hotkey never reported as armed'
    Dictate $HoldSeconds
    AssertTrue 'the cpu tier transcribes' (WaitForLog 'Transcribed via' 120) 'no transcription on the cpu tier'
    $loaded = Select-String -Path $srvLog -Pattern 'loading model from .*ggml-small\.bin' -EA SilentlyContinue
    AssertTrue 'REGRESSION: the model actually loaded is the tier`s model' ($null -ne $loaded) `
        'server.log does not show ggml-small.bin being loaded'

    # ---------------------------------------------------------------
    Group 'Graceful shutdown'
    AssertTrue 'the script accepts a clean exit request' (RequestExit $app) 'it never exited'
    Start-Sleep -Seconds 2
    $servers = @(Get-Process whisper-server -EA SilentlyContinue)
    AssertTrue 'exiting releases the server and its VRAM' ($servers.Count -eq 0) "$($servers.Count) still running"

    # ---------------------------------------------------------------
    Group 'A brand-new installation'
    # No Configured marker and no microphone: exactly what an installer
    # leaves behind. This is the only state that opens the setup window,
    # and getting it wrong in either direction is visible - an upgrade
    # greeted by a wizard, or a new user left with no guidance at all.
    StopEverything
    WriteIni 'cpu' $modelsDir 0
    $app = StartWhispers
    AssertTrue 'it starts' (WaitForLog 'Hotkey armed' 60) 'never armed'
    AssertTrue 'a first run opens the setup window' (WaitForWindow 'setup' 30) `
        'no window with "setup" in its title appeared'
    # The hotkey has to keep working while it is open: the window's last
    # step asks the user to dictate into it.
    Dictate $HoldSeconds
    AssertTrue 'dictation works while setup is open' (WaitForLog 'Transcribed via' 120) `
        'no transcription with the setup window open'
    AssertTrue 'closing the window ends setup' ([WhispersFind]::Close('setup')) 'no window to close'
    Start-Sleep -Seconds 2
    AssertLog 'finishing setup is recorded in the log' 'Setup finished'
    AssertTrue 'setup is recorded in the INI, not just in the log' `
        ((IniValue 'UI' 'Configured') -eq '1') `
        "Configured is '$(IniValue 'UI' 'Configured')', so setup would run again on every start"
    AssertTrue 'the microphone it detected was kept' ((IniValue 'Audio' 'Mic') -ne '') `
        'setup finished with no microphone recorded'

    RequestExit $app | Out-Null
    Start-Sleep -Seconds 2
    $app = StartWhispers
    AssertTrue 'it starts again' (WaitForLog 'Hotkey armed' 60) 'never armed'
    # Long enough for the deferred update check to have fired: asserting
    # on its absence after three seconds would only prove the timer had
    # not run yet.
    AssertTrue 'the update check runs, deferred' (WaitForLog 'Update check' 40) `
        'no update check line within 40 s'
    AssertLog 'and it is skipped when turned off' 'Update check skipped: turned off'
    RefuteLog 'so nothing was sent to GitHub' 'api.github.com'
    AssertTrue 'a configured machine is never shown the setup window again' `
        ([WhispersFind]::ByTitle('setup') -eq [IntPtr]::Zero) `
        'the setup window came back on an already-configured machine'

    # ---------------------------------------------------------------
    Group 'Recovery after a hard kill'
    # Whispers can be killed from Task Manager, or by a logoff, and then
    # OnExit never runs. The server it started survives and keeps holding
    # VRAM, so the next start has to clean up after the previous one.
    StopEverything
    WriteIni 'cpu' $modelsDir
    $app = StartWhispers
    AssertTrue 'it starts again' (WaitForLog 'Hotkey armed' 60) 'never armed'
    Dictate $HoldSeconds
    AssertTrue 'a server is running' (WaitForLog 'Transcribed via' 120) 'no transcription'
    Get-Process AutoHotkey64 -EA SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $orphans = @(Get-Process whisper-server -EA SilentlyContinue)
    AssertTrue 'a hard kill does leave the server behind, as expected' ($orphans.Count -ge 1) `
        'nothing survived, so the next assertion would prove nothing'

    $app = StartWhispers
    AssertTrue 'it starts despite the orphan' (WaitForLog 'Hotkey armed' 60) 'never armed'
    Start-Sleep -Seconds 1
    $servers = @(Get-Process whisper-server -EA SilentlyContinue)
    AssertTrue 'REGRESSION: the orphaned server is reaped at startup' ($servers.Count -le 1) `
        "$($servers.Count) whisper-server processes after restart"
    AssertTrue 'and the new instance still exits cleanly' (RequestExit $app) 'it never exited'
}
finally {
    StopEverything
    if ($hadIni) {
        Copy-Item $backup $ini -Force
        Remove-Item $backup -EA SilentlyContinue
    } else {
        Remove-Item $ini -EA SilentlyContinue
    }
    Write-Host "`nYour settings have been restored." -ForegroundColor DarkGray
}

Write-Host ""
$colour = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "$($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $colour
exit $script:Fail
