# =====================================================================
# Synthesizes Whispers' four sounds into assets\sounds\.
#
# They replace SoundBeep, which blocks: every SoundBeep was a point where
# AutoHotkey could interrupt the thread, and the one in StopRec ran for
# 120 ms before the recorder was killed, so the beep itself ended up in
# the dictation. A WAV played asynchronously from memory blocks nothing.
#
# Synthesized here rather than taken from a sound library: no licence to
# track, and the shape of each sound is readable in this file. Short
# sines with a fast attack and an exponential decay read as a soft tick,
# not as a system alert. Deterministic, so a rerun leaves git clean.
#
#   .\tools\build-sounds.ps1
# =====================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$Out  = Join-Path $Root 'assets\sounds'
$Rate = 44100

# One voice: a sine gliding from f0 to f1 over its length, with a second
# harmonic for body, a linear attack and an exponential decay.
function Get-Voice([double] $f0, [double] $f1, [double] $ms, [double] $gain, [double] $decay) {
    $n = [int]($Rate * $ms / 1000)
    $attack = [int]($Rate * 0.004)
    $s = New-Object double[] $n
    $phase = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / $n
        $f = $f0 + ($f1 - $f0) * $t
        $phase += 2 * [math]::PI * $f / $Rate
        $amp = [math]::Exp(-$decay * $t)
        if ($i -lt $attack) { $amp *= $i / $attack }
        # The last 3 ms fade to zero, or the cut-off clicks.
        $tail = $n - $i
        if ($tail -lt [int]($Rate * 0.003)) { $amp *= $tail / ($Rate * 0.003) }
        $s[$i] = $gain * $amp * ([math]::Sin($phase) + 0.18 * [math]::Sin(2 * $phase))
    }
    return , $s
}

# Lays voices end to end, each starting $offsetMs after the previous one.
function Join-Voices([object[]] $voices, [double] $offsetMs) {
    $step = [int]($Rate * $offsetMs / 1000)
    $len = 0
    for ($v = 0; $v -lt $voices.Count; $v++) { $len = [math]::Max($len, $v * $step + $voices[$v].Length) }
    $mix = New-Object double[] $len
    for ($v = 0; $v -lt $voices.Count; $v++) {
        for ($i = 0; $i -lt $voices[$v].Length; $i++) { $mix[$v * $step + $i] += $voices[$v][$i] }
    }
    return , $mix
}

function Save-Wav([string] $name, [double[]] $samples) {
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $ms
    $data = $samples.Length * 2
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $data))
    $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16)
    $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$Rate); $w.Write([int]($Rate * 2))
    $w.Write([int16]2); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$data)
    foreach ($x in $samples) {
        $v = [math]::Max(-1.0, [math]::Min(1.0, $x))
        $w.Write([int16][math]::Round($v * 32767))
    }
    $w.Flush()
    $path = Join-Path $Out "$name.wav"
    [IO.File]::WriteAllBytes($path, $ms.ToArray())
    $length = $samples.Length * 1000 / $Rate
    Write-Host ("  {0}  {1:N0} ms" -f [IO.Path]::GetRelativePath($Root, $path), $length)
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
Write-Host 'Synthesizing sounds:'

# Key down: a short tick rising a fifth - "listening".
Save-Wav 'start' (Get-Voice 880 1320 70 0.30 5)
# Key up: the same tick falling back - "got it".
Save-Wav 'stop' (Get-Voice 1320 880 60 0.24 5)
# Pasted: two quick notes a fourth apart, the brightest of the four.
Save-Wav 'done' (Join-Voices @((Get-Voice 1175 1175 55 0.22 4), (Get-Voice 1568 1568 70 0.22 5)) 40)
# Failure: low and falling, so it cannot be mistaken for the others.
Save-Wav 'error' (Get-Voice 392 294 115 0.34 3)
