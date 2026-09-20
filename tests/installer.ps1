<#
.SYNOPSIS
    Tests for the Whispers installer.

.DESCRIPTION
    Two groups, split by what each one costs.

    The static group reads the sources only: it proves that pins.iss is
    a faithful projection of versions.json, that the tier thresholds
    duplicated into the installer still agree with lib\Tiers.ahk, and
    that every file the .iss claims to ship exists. It needs no network
    and no install, so it can run anywhere.

    The end-to-end group builds the installer, installs it silently into
    a temporary directory, and inspects the result: the exact file set,
    the model's SHA-256, the absence of the 25 executables the archives
    carry and Whispers never runs, and whether the installed engine can
    load its own DLLs. Then it uninstalls and checks the machine is
    clean. It downloads about 600 MB.

    It writes the Tier key into %APPDATA%\Whispers\Whispers.ini exactly
    as a real install does, so your own settings are backed up first and
    restored afterwards, including after a failure.

.EXAMPLE
    pwsh -File tests\installer.ps1 -StaticOnly
    pwsh -File tests\installer.ps1
#>
[CmdletBinding()]
param(
    [switch]$StaticOnly,
    [ValidateSet('fast', 'balanced', 'max', 'cpu')]
    [string]$Tier = 'cpu',
    # 'cpu' keeps the run cheap: 21 MB of engine instead of 643 MB.
    # 'auto' exercises the CUDA path this machine would really install,
    # which is the only way to prove those DLLs resolve.
    [ValidateSet('cpu', 'auto')]
    [string]$Engine = 'cpu'
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $PSScriptRoot
$issFile  = Join-Path $root 'installer\Whispers.iss'
$pinsFile = Join-Path $root 'installer\pins.iss'
$tiersAhk = Join-Path $root 'lib\Tiers.ahk'
$verFile  = Join-Path $root 'versions.json'
$dataDir  = Join-Path $env:APPDATA 'Whispers'
$ini      = Join-Path $dataDir 'Whispers.ini'
$backup   = Join-Path $env:TEMP 'Whispers.ini.installer-backup'
$appId    = '{7A1D5F2E-3C48-4B91-9E6D-0F2A8C4B7E13}_is1'
$regKey   = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId"

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
function AssertEq($what, $expected, $actual) {
    AssertTrue $what ($expected -eq $actual) "expected '$expected', got '$actual'"
}

$version  = (Get-Content $verFile -Raw -Encoding UTF8 | ConvertFrom-Json)
$setupExe = Join-Path $root "dist\Whispers-$($version.whispers)-setup.exe"

# =====================================================================
Group 'Static consistency'
# =====================================================================

# pins.iss is generated, never committed, and the .iss refuses to
# compile without it - so it cannot go stale. What can go wrong is the
# generator projecting the wrong field of versions.json, and every
# assertion below compares the two, key by key.
& pwsh -NoProfile -File (Join-Path $root 'tools\build-installer.ps1') -PinsOnly | Out-Null
AssertTrue 'the generator produces pins.iss from versions.json' `
    (($LASTEXITCODE -eq 0) -and (Test-Path $pinsFile)) "build-installer.ps1 -PinsOnly exited with $LASTEXITCODE"

$pins = Get-Content $pinsFile
function Pin($name) {
    $line = $pins | Where-Object { $_ -match "^#define\s+$name\s+`"(.*)`"$" }
    if ($line -match "^#define\s+$name\s+`"(.*)`"$") { $Matches[1] } else { $null }
}

AssertEq 'the installer version is the product version' $version.whispers (Pin 'AppVersion')

foreach ($t in 'fast', 'balanced', 'max', 'cpu') {
    $key = $t.Substring(0,1).ToUpper() + $t.Substring(1)
    AssertEq "the $t tier pins the file versions.json names" `
        $version.models.tiers.$t.file (Pin "Tier${key}File")
    AssertEq "the $t tier pins the hash versions.json names" `
        $version.models.tiers.$t.sha256 (Pin "Tier${key}Sha")
}
AssertEq 'the CUDA 12.4 engine asset matches versions.json' `
    $version.engine.variants.'cuda-12.4'.asset (Pin 'EngCuda124Asset')
AssertEq 'the CUDA 11.8 engine asset matches versions.json' `
    $version.engine.variants.'cuda-11.8'.asset (Pin 'EngCuda118Asset')
AssertEq 'the CPU engine asset matches versions.json' `
    $version.engine.variants.cpu.asset (Pin 'EngCpuAsset')

# Every hash is a real SHA-256, not a placeholder somebody meant to fill
# in later. An empty third argument to DownloadPage.Add disables
# verification silently, so a blank pin would download anything.
$hashPins = $pins | Where-Object { $_ -match '^#define\s+\w*Sha\s+"(.*)"$' } |
            ForEach-Object { if ($_ -match '"(.*)"$') { $Matches[1] } }
AssertEq 'every artefact carries a hash pin' 9 $hashPins.Count
AssertTrue 'every hash pin is 64 hex characters' `
    (@($hashPins | Where-Object { $_ -notmatch '^[0-9a-f]{64}$' }).Count -eq 0) `
    'at least one pin is not a SHA-256'

$urlPins = $pins | Where-Object { $_ -match '^#define\s+\w*(Url|Base)\s+"(.*)"$' } |
           ForEach-Object { if ($_ -match '"(.*)"$') { $Matches[1] } }
AssertTrue 'every download goes to github.com or huggingface.co over https' `
    (@($urlPins | Where-Object { $_ -notmatch '^https://(github\.com|huggingface\.co)/' }).Count -eq 0) `
    ($urlPins -join '; ')

# The installer runs before the application exists on disk, so it cannot
# call RecommendTier and has its own copy of the thresholds. This is the
# assertion that stops the two copies drifting apart.
$iss  = Get-Content $issFile -Raw
$ahk  = Get-Content $tiersAhk -Raw
$issThresholds = ([regex]::Matches($iss, 'GpuVramMb >= (\d+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
$ahkThresholds = ([regex]::Matches($ahk, 'vramTotalMb >= (\d+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
AssertTrue 'the VRAM thresholds are non-empty in both files' ($issThresholds -ne '') $issThresholds
AssertEq 'the installer thresholds match lib\Tiers.ahk' $ahkThresholds $issThresholds

# Same story for the tier names: the installer hard-codes the order.
$issTiers = ([regex]::Matches($iss, "TierKey\[\d\] := '(\w+)'") | ForEach-Object { $_.Groups[1].Value })
AssertEq 'the installer knows exactly the tiers versions.json defines' `
    (($version.models.tiers.PSObject.Properties.Name | Sort-Object) -join ',') `
    (($issTiers | Sort-Object) -join ',')

# Anything the .iss says it ships has to exist, or the build fails at a
# much less obvious moment.
$sources = [regex]::Matches($iss, 'Source:\s*"\.\.\\([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
AssertTrue 'the .iss ships at least the script, the core and the pins' ($sources.Count -ge 5) "$($sources.Count) entries"
$missing = @($sources | Where-Object { -not (Get-Item (Join-Path $root $_) -EA SilentlyContinue) })
AssertTrue 'every file the .iss ships exists' ($missing.Count -eq 0) ($missing -join '; ')

# Encoding discipline, same rule as every other Windows-only source.
foreach ($f in @($issFile, $pinsFile, (Join-Path $root 'tools\build-installer.ps1'), $PSCommandPath)) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    $name  = Split-Path $f -Leaf
    AssertTrue "$name is ASCII" (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'non-ASCII bytes present'
    $lf   = @($bytes | Where-Object { $_ -eq 10 }).Count
    $crlf = ([regex]::Matches([System.Text.Encoding]::ASCII.GetString($bytes), "`r`n")).Count
    AssertEq "$name is CRLF throughout" $lf $crlf
}

if ($StaticOnly) {
    Write-Host ''
    Write-Host "static: $script:Pass passed, $script:Fail failed" -ForegroundColor (@('Green','Red')[[int]($script:Fail -gt 0)])
    exit $script:Fail
}

# =====================================================================
Group 'Preconditions'
# =====================================================================

$elevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
AssertTrue 'running unelevated, which is how the installer is meant to be used' (-not $elevated) `
    'run this without administrator rights'

# A real install sharing the AppId would have its registration removed
# by this test's uninstall. Refuse rather than damage it.
AssertTrue 'no existing Whispers installation would be clobbered' (-not (Test-Path $regKey)) `
    "uninstall the existing Whispers first: $regKey"
if (Test-Path $regKey) { exit 1 }

# A running instance owns the same INI this test seeds and restores. It
# saves its configuration on exit, which would land on top of the
# restore and leave the user with the test's tier.
$running = @(Get-Process AutoHotkey64 -EA SilentlyContinue)
AssertTrue 'no Whispers instance is running' ($running.Count -eq 0) `
    'close Whispers first - it would overwrite the settings this test restores'
if ($running.Count -gt 0) { exit 1 }

if (Test-Path $ini) { Copy-Item $ini $backup -Force } elseif (Test-Path $backup) { Remove-Item $backup -Force }

$target = Join-Path $env:TEMP ('WhispersInstallTest-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$setupLog = Join-Path $env:TEMP 'whispers-setup-test.log'

try {
    # =================================================================
    Group 'Build'
    # =================================================================
    & pwsh -NoProfile -File (Join-Path $root 'tools\build-installer.ps1') | Out-Null
    AssertTrue 'the installer builds' ($LASTEXITCODE -eq 0) "build-installer.ps1 exited with $LASTEXITCODE"
    AssertTrue 'the built installer exists' (Test-Path $setupExe) $setupExe
    if (-not (Test-Path $setupExe)) { throw 'nothing to install' }

    # =================================================================
    Group 'Silent install'
    # =================================================================
    $args = @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        "/LOG=$setupLog", "/DIR=$target",
        '/MERGETASKS=!desktopicon,!startup',
        "/TIER=$Tier"
    )
    if ($Engine -eq 'cpu') { $args += '/ENGINE=cpu' }
    Write-Host "  .... tier=$Tier engine=$Engine into $target" -ForegroundColor DarkGray
    $p = Start-Process -FilePath $setupExe -ArgumentList $args -Wait -PassThru
    AssertEq 'setup exits successfully' 0 $p.ExitCode
    if ($p.ExitCode -ne 0) {
        Write-Host (Get-Content $setupLog -Tail 40 -EA SilentlyContinue | Out-String) -ForegroundColor DarkRed
        throw "setup failed with $($p.ExitCode)"
    }

    Group 'What landed on disk'
    foreach ($f in 'Whispers.ahk', 'versions.json', 'LICENSE', 'README.md', 'AutoHotkey64.exe') {
        AssertTrue "$f is installed" (Test-Path (Join-Path $target $f)) "missing from $target"
    }
    # Counted from the repository rather than written down, so adding a
    # module to the core cannot leave this assertion quietly passing on
    # an installer that no longer ships all of it.
    $libExpected = @(Get-ChildItem (Join-Path $root 'lib') -Filter '*.ahk').Count
    $libCount = @(Get-ChildItem (Join-Path $target 'lib') -Filter '*.ahk' -EA SilentlyContinue).Count
    AssertEq 'the whole pure core is installed' $libExpected $libCount

    foreach ($f in 'whisper-server.exe', 'whisper-cli.exe', 'ffmpeg.exe') {
        AssertTrue "bin\$f is installed" (Test-Path (Join-Path $target "bin\$f")) "missing from $target\bin"
    }
    $dlls = @(Get-ChildItem (Join-Path $target 'bin') -Filter '*.dll' -EA SilentlyContinue).Count
    AssertTrue 'the engine DLLs came with it' ($dlls -ge 5) "$dlls DLLs"
    if ($Engine -eq 'auto') {
        AssertTrue 'the CUDA build was selected from the driver, not guessed' `
            (Test-Path (Join-Path $target 'bin\ggml-cuda.dll')) `
            'ggml-cuda.dll is missing, so a CPU build was installed on a CUDA machine'
    }

    # The archives carry 23 extra executables and ffmpeg carries two more
    # at 105 MB each. Shipping them would triple the install for nothing.
    $unwanted = @('whisper-bench.exe', 'whisper-stream.exe', 'whisper-talk-llama.exe',
                  'wchess.exe', 'main.exe', 'ffplay.exe', 'ffprobe.exe') |
                Where-Object { Test-Path (Join-Path $target "bin\$_") }
    AssertTrue 'none of the unused executables are installed' ($unwanted.Count -eq 0) `
        ($unwanted -join ', ')
    $tests = @(Get-ChildItem (Join-Path $target 'bin') -Filter 'test-*.exe' -EA SilentlyContinue).Count
    AssertEq 'no upstream test binaries are installed' 0 $tests

    Group 'The model'
    $expected = $version.models.tiers.$Tier
    $modelPath = Join-Path $target "models\$($expected.file)"
    AssertTrue "the $Tier tier model is installed" (Test-Path $modelPath) $modelPath
    if (Test-Path $modelPath) {
        AssertEq 'the model has exactly the pinned size' $expected.size (Get-Item $modelPath).Length
        AssertEq 'the model has exactly the pinned SHA-256' `
            $expected.sha256 (Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLower()
    }
    $models = @(Get-ChildItem (Join-Path $target 'models') -Filter '*.bin' -EA SilentlyContinue).Count
    AssertEq 'only the selected tier is downloaded' 1 $models

    Group 'The installed tree actually runs'
    # The one failure a file listing cannot catch: a missing DLL. The
    # loader reports STATUS_DLL_NOT_FOUND as 0xC0000135 before a single
    # line of the program runs.
    $DLL_NOT_FOUND = -1073741515
    foreach ($exe in 'whisper-cli.exe', 'whisper-server.exe', 'ffmpeg.exe') {
        $r = Start-Process -FilePath (Join-Path $target "bin\$exe") -ArgumentList '-h' `
             -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput ([IO.Path]::GetTempFileName()) `
             -RedirectStandardError ([IO.Path]::GetTempFileName())
        AssertTrue "bin\$exe resolves all of its DLLs" ($r.ExitCode -ne $DLL_NOT_FOUND) `
            "the loader returned 0xC0000135"
    }

    # The interpreter that was downloaded has to be able to load the core
    # that was shipped, against the versions.json that was installed.
    $probe = Join-Path $env:TEMP 'whispers-install-probe.ahk'
    $probeOut = Join-Path $env:TEMP 'whispers-install-probe.txt'
    Remove-Item $probeOut -EA SilentlyContinue
    @(
        '#Requires AutoHotkey v2.0',
        "#Include $target\lib\Tiers.ahk",
        "json := FileRead(`"$target\versions.json`", `"UTF-8`")",
        "FileAppend(TierFileFrom(json, `"$Tier`"), `"$probeOut`")",
        'ExitApp(0)'
    ) -join "`r`n" | Set-Content $probe -Encoding Ascii
    $r = Start-Process -FilePath (Join-Path $target 'AutoHotkey64.exe') -ArgumentList "`"$probe`"" -Wait -PassThru
    AssertEq 'the installed interpreter runs the installed core' 0 $r.ExitCode
    AssertTrue 'it resolves the tier against the installed versions.json' `
        ((Test-Path $probeOut) -and ((Get-Content $probeOut -Raw).Trim() -eq $expected.file)) `
        "probe wrote '$(if (Test-Path $probeOut) { (Get-Content $probeOut -Raw).Trim() })'"
    Remove-Item $probe, $probeOut -EA SilentlyContinue

    Group 'Configuration'
    AssertTrue 'the INI was seeded outside the install root' (Test-Path $ini) $ini
    $seeded = (Select-String -Path $ini -Pattern '^\s*Tier\s*=\s*(\w+)' -EA SilentlyContinue |
               Select-Object -First 1)
    AssertTrue "the chosen tier was written to the INI" `
        ($null -ne $seeded -and $seeded.Matches[0].Groups[1].Value -eq $Tier) `
        "INI says '$($seeded.Line)'"
    AssertTrue 'no settings file is written inside the install root' `
        (-not (Test-Path (Join-Path $target 'Whispers.ini'))) `
        'an install-root INI would be lost on every upgrade'

    Group 'Shortcuts'
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Whispers\Whispers.lnk'
    AssertTrue 'a Start Menu shortcut was created' (Test-Path $startMenu) $startMenu
    AssertTrue 'no startup entry when the task was deselected' `
        (-not (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Whispers.lnk'))) `
        'the installer added itself to startup against /MERGETASKS'

    Group 'Uninstall'
    $uninst = Join-Path $target 'unins000.exe'
    AssertTrue 'an uninstaller was written' (Test-Path $uninst) $uninst
    if (Test-Path $uninst) {
        Start-Process -FilePath $uninst -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
        $deadline = (Get-Date).AddSeconds(90)
        while ((Test-Path $target) -and ((Get-Date) -lt $deadline)) { Start-Sleep -Milliseconds 500 }
        AssertTrue 'the install root is gone, including the downloaded files' (-not (Test-Path $target)) `
            "still present: $(@(Get-ChildItem $target -Recurse -EA SilentlyContinue).Count) items"
        AssertTrue 'the registration is gone' (-not (Test-Path $regKey)) $regKey
        AssertTrue 'the Start Menu shortcut is gone' (-not (Test-Path $startMenu)) $startMenu
        # Settings are the user's, not the installer's: a silent uninstall
        # answers "no" to the question and must leave them alone.
        AssertTrue 'a silent uninstall keeps your settings and history' (Test-Path $dataDir) `
            "a silent uninstall deleted $dataDir"
    }
}
finally {
    Remove-Item $target -Recurse -Force -EA SilentlyContinue
    if (Test-Path $backup) {
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        Move-Item $backup $ini -Force
        Write-Host "`nyour Whispers.ini was restored" -ForegroundColor DarkGray
    } elseif (Test-Path $ini) {
        # There was none before this test ran; do not leave one behind.
        Remove-Item $ini -Force -EA SilentlyContinue
    }
}

Write-Host ''
Write-Host "$script:Pass passed, $script:Fail failed" -ForegroundColor (@('Green','Red')[[int]($script:Fail -gt 0)])
exit $script:Fail
