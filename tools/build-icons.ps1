# =====================================================================
# Draws every Whispers icon and installer image into assets\.
#
# The mark is pure geometry - a violet-to-cyan rounded square with four
# white bars - so it is drawn at each size rather than scaled down from
# one master. A 256 px drawing shrunk to 16 px turns the bars into grey
# mush; drawn at 16 px on the pixel grid they stay four distinct bars.
#
# The outputs are committed: running Whispers needs no build step, and
# the installer only references files. Rerun this after changing the
# drawing; it is deterministic, so an unchanged drawing gives
# byte-identical files and a clean git status.
#
#   .\tools\build-icons.ps1                    write assets\
#   .\tools\build-icons.ps1 -Preview x.png     also write a contact sheet
# =====================================================================

[CmdletBinding()]
param(
    [string] $Preview
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$Root   = Split-Path -Parent $PSScriptRoot
$Assets = Join-Path $Root 'assets'

$Violet = [Drawing.Color]::FromArgb(255, 0x7C, 0x5C, 0xFF)
$Cyan   = [Drawing.Color]::FromArgb(255, 0x3D, 0xD6, 0xF5)
$Red    = [Drawing.Color]::FromArgb(255, 0xFF, 0x4D, 0x5E)
$Amber  = [Drawing.Color]::FromArgb(255, 0xFF, 0xB3, 0x47)
$Grey   = [Drawing.Color]::FromArgb(255, 0x6B, 0x6B, 0x78)
$Navy   = [Drawing.Color]::FromArgb(255, 0x12, 0x0F, 0x2E)

# Bar heights as a fraction of the tile, left to right. Same rhythm as
# the mark in the design mockups: short, tall, tallest, middle.
$BarHeights = 0.28, 0.56, 0.78, 0.40

# ------------------------------------------------------------- drawing

function New-Canvas([int] $w, [int] $h) {
    $bmp = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode      = 'AntiAlias'
    $g.PixelOffsetMode    = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    $g.InterpolationMode  = 'HighQualityBicubic'
    $g.Clear([Drawing.Color]::Transparent)
    return $bmp, $g
}

function New-RoundRect([double] $x, [double] $y, [double] $w, [double] $h, [double] $r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [math]::Min(2 * $r, [math]::Min($w, $h))
    if ($d -le 0) { $p.AddRectangle((New-Object Drawing.RectangleF $x, $y, $w, $h)); return $p }
    $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
    $p.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Padding around the tile. Windows draws small icons edge to edge, so
# 16-24 px get none; larger sizes breathe a little, as Fluent icons do.
function Get-Pad([int] $s) {
    if ($s -le 24) { return 0 }
    if ($s -le 48) { return 1 }
    return [int][math]::Round($s * 0.06)
}

# The four bars, snapped to whole pixels so they stay sharp at 16 px.
function Add-Bars($g, [double] $x, [double] $y, [double] $inner, [Drawing.Color] $color, [double[]] $heights) {
    $barW = [math]::Max(2, [int][math]::Round($inner * 0.11))
    $gap  = [math]::Max(1, [int][math]::Round($inner * 0.085))
    $total = 4 * $barW + 3 * $gap
    $x0 = $x + [math]::Floor(($inner - $total) / 2)
    $brush = New-Object Drawing.SolidBrush $color
    for ($i = 0; $i -lt 4; $i++) {
        $h = [int][math]::Round($heights[$i] * $inner)
        # Keep the bar centred on the pixel grid: same parity as the tile.
        if ((([int]$inner - $h) % 2) -ne 0) { $h++ }
        $by = $y + ($inner - $h) / 2
        $path = New-RoundRect ($x0 + $i * ($barW + $gap)) $by $barW $h ($barW / 2)
        $g.FillPath($brush, $path)
        $path.Dispose()
    }
    $brush.Dispose()
}

# The app mark: gradient tile plus bars, in a square of $s pixels.
function Add-Mark($g, [double] $ox, [double] $oy, [int] $s, [switch] $Paused) {
    $pad   = Get-Pad $s
    $inner = $s - 2 * $pad
    $x = $ox + $pad; $y = $oy + $pad
    $tile = New-RoundRect $x $y $inner $inner ($inner * 0.24)
    if ($Paused) {
        $fill = New-Object Drawing.SolidBrush $Grey
    } else {
        $rect = New-Object Drawing.RectangleF ([single]$x), ([single]$y), ([single]$inner), ([single]$inner)
        $fill = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, $Violet, $Cyan, 45.0
    }
    $g.FillPath($fill, $tile)
    $fill.Dispose()

    # A soft highlight on the upper half: the glass of the indicator,
    # only where there are enough pixels for it to read as light.
    if ($s -ge 48) {
        $hl = New-Object Drawing.RectangleF ([single]$x), ([single]$y), ([single]$inner), ([single]($inner / 2))
        $hb = New-Object Drawing.Drawing2D.LinearGradientBrush $hl, ([Drawing.Color]::FromArgb(56, 255, 255, 255)), ([Drawing.Color]::FromArgb(0, 255, 255, 255)), 90.0
        $g.SetClip($tile)
        $g.FillRectangle($hb, $hl)
        $g.ResetClip()
        $hb.Dispose()
    }
    $tile.Dispose()

    if ($Paused) {
        $barW = [math]::Max(2, [int][math]::Round($inner * 0.14))
        $h = [int][math]::Round($inner * 0.5)
        if ((([int]$inner - $h) % 2) -ne 0) { $h++ }
        $x0 = $x + [math]::Floor(($inner - 3 * $barW) / 2)
        $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
        foreach ($bx in $x0, ($x0 + 2 * $barW)) {
            $p = New-RoundRect $bx ($y + ($inner - $h) / 2) $barW $h ([math]::Min(1.5, $barW / 2))
            $g.FillPath($white, $p)
            $p.Dispose()
        }
        $white.Dispose()
    } else {
        Add-Bars $g $x $y $inner ([Drawing.Color]::White) $BarHeights
    }
}

# A status dot in the bottom-right corner, cut out of the mark by a
# transparent ring so it reads against any taskbar colour.
function Add-Badge($g, [int] $s, [Drawing.Color] $color) {
    $d    = [math]::Max(7, [int][math]::Round($s * 0.5))
    $ring = [math]::Max(1, [int][math]::Round($s * 0.06))
    $x = $s - $d; $y = $s - $d
    $g.CompositingMode = 'SourceCopy'
    $clear = New-Object Drawing.SolidBrush ([Drawing.Color]::Transparent)
    $g.FillEllipse($clear, [single]($x - $ring), [single]($y - $ring), [single]($d + 2 * $ring), [single]($d + 2 * $ring))
    $clear.Dispose()
    $g.CompositingMode = 'SourceOver'
    $dot = New-Object Drawing.SolidBrush $color
    $g.FillEllipse($dot, [single]$x, [single]$y, [single]$d, [single]$d)
    $dot.Dispose()
}

function New-Icon([int] $s, [string] $state) {
    $bmp, $g = New-Canvas $s $s
    Add-Mark $g 0 0 $s -Paused:($state -eq 'paused')
    if ($state -eq 'recording') { Add-Badge $g $s $Red }
    if ($state -eq 'working')   { Add-Badge $g $s $Amber }
    $g.Dispose()
    return $bmp
}

# The welcome page's side panel: the mark as a glass tile on a dark
# field with two glows. Opaque, so it reads the same in light and dark.
function New-WizardImage([int] $w, [int] $h) {
    $bmp, $g = New-Canvas $w $h
    $g.Clear($Navy)
    foreach ($glow in @(@(-0.45, -0.20, 1.6, $Violet, 210), @(0.15, 0.62, 1.5, $Cyan, 170))) {
        $gx = $glow[0] * $w; $gy = $glow[1] * $h; $gd = $glow[2] * $w
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $path.AddEllipse([single]$gx, [single]$gy, [single]$gd, [single]$gd)
        $pb = New-Object Drawing.Drawing2D.PathGradientBrush $path
        $pb.CenterColor = [Drawing.Color]::FromArgb($glow[4], $glow[3])
        $pb.SurroundColors = @([Drawing.Color]::FromArgb(0, $glow[3]))
        # Ease the falloff: a linear ramp leaves a visible rim where the
        # glow meets the navy field.
        $blend = New-Object Drawing.Drawing2D.Blend 4
        $blend.Positions = [single[]]@(0, 0.35, 0.7, 1)
        $blend.Factors   = [single[]]@(0, 0.12, 0.5, 1)
        $pb.Blend = $blend
        $g.FillPath($pb, $path)
        $pb.Dispose(); $path.Dispose()
    }
    $t = [int][math]::Round($w * 0.56)
    $tx = ($w - $t) / 2; $ty = ($h - $t) / 2
    $tile = New-RoundRect $tx $ty $t $t ($t * 0.25)
    $glass = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(36, 255, 255, 255))
    $g.FillPath($glass, $tile); $glass.Dispose()
    $hl = New-Object Drawing.RectangleF ([single]$tx), ([single]$ty), ([single]$t), ([single]($t / 2))
    $hb = New-Object Drawing.Drawing2D.LinearGradientBrush $hl, ([Drawing.Color]::FromArgb(60, 255, 255, 255)), ([Drawing.Color]::FromArgb(0, 255, 255, 255)), 90.0
    $g.SetClip($tile); $g.FillRectangle($hb, $hl); $g.ResetClip(); $hb.Dispose()
    $rim = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(84, 255, 255, 255)), ([single][math]::Max(1, $w / 164))
    $g.DrawPath($rim, $tile); $rim.Dispose(); $tile.Dispose()
    $inner = $t * 0.62
    Add-Bars $g ($tx + ($t - $inner) / 2) ($ty + ($t - $inner) / 2) $inner ([Drawing.Color]::White) $BarHeights
    $g.Dispose()
    return $bmp
}

function New-WizardSmall([int] $s) {
    $bmp, $g = New-Canvas $s $s
    $m = [int][math]::Round($s * 0.08)
    Add-Mark $g $m $m ($s - 2 * $m)
    $g.Dispose()
    return $bmp
}

# ------------------------------------------------------------- writing

function Get-PngBytes($bmp) {
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    return $ms.ToArray()
}

# One ICO entry. Sizes under 256 are classic 32-bit DIBs, which every
# loader understands (Inno's compiler and LoadImage included); 256 is a
# PNG, which is what Windows expects at that size.
function Get-IcoEntry($bmp) {
    $s = $bmp.Width
    if ($s -ge 256) { return , (Get-PngBytes $bmp) }
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter $ms
    $maskRow = [int]([math]::Floor(($s + 31) / 32) * 4)
    $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int](2 * $s))
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]0)
    $bw.Write([int]($s * $s * 4 + $maskRow * $s))
    $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    $rect = New-Object Drawing.Rectangle 0, 0, $s, $s
    $data = $bmp.LockBits($rect, 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object byte[] ($s * $s * 4)
    for ($row = 0; $row -lt $s; $row++) {
        [Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $row * $data.Stride), $px, $row * $s * 4, $s * 4)
    }
    $bmp.UnlockBits($data)
    # DIBs are stored bottom-up.
    for ($row = $s - 1; $row -ge 0; $row--) { $bw.Write($px, $row * $s * 4, $s * 4) }
    # AND mask: set where fully transparent, for loaders that ignore alpha.
    for ($row = $s - 1; $row -ge 0; $row--) {
        $bits = New-Object byte[] $maskRow
        for ($col = 0; $col -lt $s; $col++) {
            if ($px[($row * $s + $col) * 4 + 3] -eq 0) { $bits[[math]::Floor($col / 8)] = $bits[[math]::Floor($col / 8)] -bor (0x80 -shr ($col % 8)) }
        }
        $bw.Write($bits)
    }
    $bw.Flush()
    return , $ms.ToArray()
}

function Save-Ico([string] $path, [int[]] $sizes, [string] $state) {
    $entries = foreach ($s in $sizes) { $b = New-Icon $s $state; , (Get-IcoEntry $b); $b.Dispose() }
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter $ms
    $bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]
        $dim = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([int16]1); $bw.Write([int16]32)
        $bw.Write([int]$entries[$i].Length); $bw.Write([int]$offset)
        $offset += $entries[$i].Length
    }
    foreach ($e in $entries) { $bw.Write($e) }
    $bw.Flush()
    [IO.File]::WriteAllBytes($path, $ms.ToArray())
    Write-Host "  $([IO.Path]::GetRelativePath($Root, $path))"
}

function Save-Png($bmp, [string] $path) {
    [IO.File]::WriteAllBytes($path, (Get-PngBytes $bmp))
    $bmp.Dispose()
    Write-Host "  $([IO.Path]::GetRelativePath($Root, $path))"
}

# ---------------------------------------------------------------- main

foreach ($d in $Assets, (Join-Path $Assets 'tray'), (Join-Path $Assets 'installer')) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Host 'Drawing assets:'
# 40 and 64 cover 125% and 200% of the 32 px shell sizes.
Save-Ico (Join-Path $Assets 'Whispers.ico') @(16, 20, 24, 32, 40, 48, 64, 256) 'ready'
# The tray asks for SM_CXSMICON: 16 at 100% up to 32 at 200%, 40+ beyond.
foreach ($state in 'ready', 'recording', 'working', 'paused') {
    Save-Ico (Join-Path $Assets "tray\$state.ico") @(16, 20, 24, 32, 40, 48) $state
}
# Inno Setup picks the best fit among several files per scaling level.
foreach ($pct in 100, 125, 150, 175, 200) {
    $k = $pct / 100
    Save-Png (New-WizardImage ([int][math]::Round(164 * $k)) ([int][math]::Round(314 * $k))) (Join-Path $Assets "installer\wizard-$pct.png")
    Save-Png (New-WizardSmall ([int][math]::Round(55 * $k))) (Join-Path $Assets "installer\wizard-small-$pct.png")
}

if ($Preview) {
    # Contact sheet on a dark and a light strip, every size at 1:1 and
    # the 16 px ones also at 4x, which is how the eye judges them.
    $sheet, $g = New-Canvas 760 360
    $g.Clear([Drawing.Color]::FromArgb(255, 32, 32, 32))
    $light = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 243, 243, 243))
    $g.FillRectangle($light, 0, 180, 760, 180); $light.Dispose()
    foreach ($band in 0, 180) {
        $x = 16
        foreach ($s in 16, 20, 24, 32, 48, 64) { $b = New-Icon $s 'ready'; $g.DrawImageUnscaled($b, $x, $band + 16); $b.Dispose(); $x += $s + 16 }
        $big = New-Icon 256 'ready'; $g.DrawImage($big, $x, $band + 16, 96, 96); $big.Dispose()
        $x = 16
        foreach ($state in 'ready', 'recording', 'working', 'paused') {
            $b = New-Icon 16 $state
            $g.DrawImageUnscaled($b, $x, $band + 132)
            $g.InterpolationMode = 'NearestNeighbor'
            $g.DrawImage($b, $x + 28, $band + 116, 48, 48)
            $g.InterpolationMode = 'HighQualityBicubic'
            $b.Dispose(); $x += 100
        }
        $w = New-WizardImage 82 157; $g.DrawImageUnscaled($w, 560, $band + 10); $w.Dispose()
        $sm = New-WizardSmall 55; $g.DrawImageUnscaled($sm, 670, $band + 16); $sm.Dispose()
    }
    $g.Dispose()
    $sheet.Save($Preview, [Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
    Write-Host "Preview: $Preview"
}
