# =====================================================================
# Fetches the pinned third-party files the application includes into
# vendor\ - today the WebView2 binding (versions.json, "webview2").
#
# vendor\ is never committed. The installer build calls this script and
# ships what it fetched; a development checkout runs it once. Each file
# is downloaded from the repository at the pinned commit, written only
# if its SHA-256 matches, and the loader DLL must also carry a valid
# Microsoft Authenticode signature - the hash says it is the file we
# validated, the signature says Microsoft built it.
#
#   .\tools\fetch-vendor.ps1           fetch what is missing or wrong
#   .\tools\fetch-vendor.ps1 -Force    fetch everything again
# =====================================================================

[CmdletBinding()]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root      = Split-Path -Parent $PSScriptRoot
$Versions  = Join-Path $Root 'versions.json'
$VendorDir = Join-Path $Root 'vendor'

function Fail($message) {
    Write-Host "FAILED: $message" -ForegroundColor Red
    exit 1
}

function Sha256([string] $path) {
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}

if (-not (Test-Path $Versions)) { Fail "versions.json not found at $Versions" }
$w = (Get-Content $Versions -Raw -Encoding UTF8 | ConvertFrom-Json).webview2
if (-not $w) { Fail 'versions.json has no "webview2" block' }
if ($w.commit -notmatch '^[0-9a-f]{40}$') { Fail "webview2.commit is not a full commit hash: $($w.commit)" }

# The binding's own relative includes (..\ComVar.ahk) need the
# repository's layout, so it is kept under vendor\<repo name>\.
$dest = Join-Path $VendorDir ($w.repo -replace '^.*/', '')
$base = "https://raw.githubusercontent.com/$($w.repo)/$($w.commit)/"

$fetched = 0
foreach ($p in $w.files.PSObject.Properties) {
    $rel  = $p.Name
    $sha  = $p.Value.ToLower()
    $file = Join-Path $dest ($rel -replace '/', '\')

    if (-not $Force -and (Test-Path $file) -and (Sha256 $file) -eq $sha) { continue }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    $part = "$file.part"
    Write-Host "Fetching $rel"
    try {
        Invoke-WebRequest -Uri ($base + $rel) -OutFile $part -UseBasicParsing
    } catch {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Fail "download of $rel failed: $($_.Exception.Message)"
    }

    $got = Sha256 $part
    if ($got -ne $sha) {
        Remove-Item -LiteralPath $part -Force
        Fail "SHA-256 mismatch for ${rel}: expected $sha, got $got"
    }
    if ($rel -like '*.dll') {
        $sig = Get-AuthenticodeSignature -LiteralPath $part
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
            Remove-Item -LiteralPath $part -Force
            Fail "$rel is not signed by Microsoft (status $($sig.Status))"
        }
    }
    Move-Item -LiteralPath $part -Destination $file -Force
    $fetched++
}

Write-Host "vendor\ is up to date ($fetched file(s) fetched, commit $($w.commit.Substring(0, 7)))."
