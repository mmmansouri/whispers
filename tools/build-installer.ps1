# =====================================================================
# Builds the Whispers installer.
#
# versions.json is the single source of truth for every pinned artefact.
# This script projects it into installer\pins.iss so the .iss never
# restates a URL or a hash: a pin raised in one place cannot be left
# stale in the other, because pins.iss is regenerated on every build.
#
#   .\tools\build-installer.ps1              build dist\Whispers-x.y.z-setup.exe
#   .\tools\build-installer.ps1 -PinsOnly    regenerate pins.iss and stop
# =====================================================================

[CmdletBinding()]
param(
    [switch] $PinsOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root      = Split-Path -Parent $PSScriptRoot
$Versions  = Join-Path $Root 'versions.json'
$IssFile   = Join-Path $Root 'installer\Whispers.iss'
$PinsFile  = Join-Path $Root 'installer\pins.iss'
$DistDir   = Join-Path $Root 'dist'

function Fail($message) {
    Write-Host "FAILED: $message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Versions)) { Fail "versions.json not found at $Versions" }
$v = Get-Content $Versions -Raw -Encoding UTF8 | ConvertFrom-Json

# Sizes are shown to the user in the tier list, so they are derived from
# the pinned byte counts rather than typed in a second time.
function Mb([long] $bytes) { [int][math]::Round($bytes / 1MB) }
function Gb([int] $mb)     { [math]::Round($mb / 1000.0, 1) }

# ggml-large-v3-turbo-q5_0.bin -> large-v3-turbo-q5_0
function ModelName([string] $file) {
    ($file -replace '^ggml-', '') -replace '\.bin$', ''
}

function TierLabel([string] $display, $tier) {
    $name = ModelName $tier.file
    $size = Mb $tier.size
    if ($tier.requires_gpu) {
        "$display - $name, $size MB download, needs about $(Gb $tier.vram_mb) GB of VRAM"
    } else {
        "$display - $name, $size MB download, no GPU needed"
    }
}

$engineBase = "https://github.com/$($v.engine.repo)/releases/download/$($v.engine.tag)/"
$modelBase  = "$($v.models.source)/resolve/$($v.models.revision)/"
$ahkUrl     = "https://github.com/$($v.autohotkey.repo)/releases/download/$($v.autohotkey.tag)/$($v.autohotkey.asset)"
$ffmpegUrl  = "https://github.com/$($v.ffmpeg.repo)/releases/download/$($v.ffmpeg.tag)/$($v.ffmpeg.asset)"

$t = $v.models.tiers
$e = $v.engine.variants

$lines = @(
    '; =====================================================================',
    '; GENERATED FILE - DO NOT EDIT.',
    ';',
    '; Projected from versions.json by tools\build-installer.ps1. Every',
    '; value below is a pin; change versions.json and rebuild.',
    '; =====================================================================',
    '',
    "#define AppVersion `"$($v.whispers)`"",
    '',
    "#define EngineTag `"$($v.engine.tag)`"",
    "#define EngineBase `"$engineBase`"",
    "#define EngCuda124Asset `"$($e.'cuda-12.4'.asset)`"",
    "#define EngCuda124Sha `"$($e.'cuda-12.4'.sha256)`"",
    "#define EngCuda118Asset `"$($e.'cuda-11.8'.asset)`"",
    "#define EngCuda118Sha `"$($e.'cuda-11.8'.sha256)`"",
    "#define EngCpuAsset `"$($e.cpu.asset)`"",
    "#define EngCpuSha `"$($e.cpu.sha256)`"",
    '',
    "#define AhkVersion `"$($v.autohotkey.tag)`"",
    "#define AhkUrl `"$ahkUrl`"",
    "#define AhkSha `"$($v.autohotkey.sha256)`"",
    '',
    "#define FfmpegVersion `"$($v.ffmpeg.tag)`"",
    "#define FfmpegUrl `"$ffmpegUrl`"",
    "#define FfmpegSha `"$($v.ffmpeg.sha256)`"",
    '',
    "#define ModelBase `"$modelBase`"",
    "#define TierFastFile `"$($t.fast.file)`"",
    "#define TierFastSha `"$($t.fast.sha256)`"",
    "#define TierFastLabel `"$(TierLabel 'Fast' $t.fast)`"",
    "#define TierBalancedFile `"$($t.balanced.file)`"",
    "#define TierBalancedSha `"$($t.balanced.sha256)`"",
    "#define TierBalancedLabel `"$(TierLabel 'Balanced' $t.balanced)`"",
    "#define TierMaxFile `"$($t.max.file)`"",
    "#define TierMaxSha `"$($t.max.sha256)`"",
    "#define TierMaxLabel `"$(TierLabel 'Maximum accuracy' $t.max)`"",
    "#define TierCpuFile `"$($t.cpu.file)`"",
    "#define TierCpuSha `"$($t.cpu.sha256)`"",
    "#define TierCpuLabel `"$(TierLabel 'CPU only' $t.cpu)`""
)

# .iss files follow the same rule as the rest of the Windows-only
# sources in this repository: ASCII, CRLF.
$text = ($lines -join "`r`n") + "`r`n"
if ($text -match '[^\x00-\x7F]') { Fail 'pins.iss would contain non-ASCII characters' }
[System.IO.File]::WriteAllText($PinsFile, $text, [System.Text.Encoding]::ASCII)
Write-Host "pins.iss regenerated from versions.json ($($lines.Count) lines)."

if ($PinsOnly) { exit 0 }

$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
    Fail 'Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup'
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Write-Host "Compiling with $iscc"
& $iscc /Q $IssFile
if ($LASTEXITCODE -ne 0) { Fail "ISCC exited with $LASTEXITCODE" }

$setup = Join-Path $DistDir "Whispers-$($v.whispers)-setup.exe"
if (-not (Test-Path $setup)) { Fail "ISCC reported success but $setup is missing" }

$size = (Get-Item $setup).Length
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLower()
Write-Host ''
Write-Host "Built   : $setup"
Write-Host "Size    : $([math]::Round($size / 1KB)) KB"
Write-Host "SHA-256 : $hash"
