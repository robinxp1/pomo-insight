$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'assets\pomo-insight.ico'
$sizes = @(16, 24, 32, 48, 64, 128, 256)

function New-IconPng {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $accent = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(255, 99, 230, 190))
    $ink = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(255, 12, 20, 23))
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $inset = [Math]::Max(1.0, $Size * 0.04)
        $diameter = $Size - ($inset * 2)
        $g.FillEllipse($accent, $inset, $inset, $diameter, $diameter)
        $points = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF -ArgumentList ($Size * 0.375), ($Size * 0.26)),
            (New-Object System.Drawing.PointF -ArgumentList ($Size * 0.375), ($Size * 0.74)),
            (New-Object System.Drawing.PointF -ArgumentList ($Size * 0.76), ($Size * 0.5))
        )
        $g.FillPolygon($ink, $points)
    } finally {
        $accent.Dispose()
        $ink.Dispose()
        $g.Dispose()
    }
    $stream = New-Object System.IO.MemoryStream
    try {
        $bmp.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return , $stream.ToArray()
    } finally {
        $bmp.Dispose()
        $stream.Dispose()
    }
}

$frames = New-Object 'System.Collections.Generic.List[byte[]]'
foreach ($size in $sizes) { $frames.Add((New-IconPng -Size $size)) }

$dir = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$file = [System.IO.File]::Create($target)
$writer = New-Object System.IO.BinaryWriter($file)
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$frames.Count)
    $offset = 6 + (16 * $frames.Count)
    for ($i = 0; $i -lt $frames.Count; $i++) {
        $size = $sizes[$i]
        $dim = if ($size -ge 256) { 0 } else { $size }
        $writer.Write([byte]$dim)
        $writer.Write([byte]$dim)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$i].Length)
        $writer.Write([uint32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame) }
} finally {
    $writer.Dispose()
    $file.Dispose()
}
Write-Output ('ICON_OK ' + $target + ' sizes=' + ($sizes -join ','))
