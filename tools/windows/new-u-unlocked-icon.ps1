# Generates a small original U Unlocked application icon in the isolated build source.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$resourceDirectory = Join-Path $sourceRoot 'runtime\res'
if (-not (Test-Path -LiteralPath $resourceDirectory -PathType Container)) {
    throw "Runtime resource directory is missing: $resourceDirectory"
}

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UUnlockedIconNativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@

$bitmap = New-Object System.Drawing.Bitmap(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 190, 196), 4.5)
$letterBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(242, 246, 250))
$font = New-Object System.Drawing.Font('Segoe UI', 39, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$format = New-Object System.Drawing.StringFormat
$iconHandle = [IntPtr]::Zero
$icon = $null
$stream = $null

try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.Clear([System.Drawing.Color]::FromArgb(15, 19, 27))
    $graphics.DrawEllipse($ringPen, 5, 5, 54, 54)

    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $bounds = New-Object System.Drawing.RectangleF(5, 3, 54, 58)
    $graphics.DrawString('U', $font, $letterBrush, $bounds, $format)

    $iconHandle = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($iconHandle).Clone()
    $outputPath = Join-Path $resourceDirectory 'u-unlocked.ico'
    $stream = [System.IO.File]::Create($outputPath)
    $icon.Save($stream)
    $stream.Flush()
    Write-Host "Generated original U Unlocked icon: $outputPath" -ForegroundColor Green
}
finally {
    if ($stream) { $stream.Dispose() }
    if ($icon) { $icon.Dispose() }
    if ($iconHandle -ne [IntPtr]::Zero) {
        [UUnlockedIconNativeMethods]::DestroyIcon($iconHandle) | Out-Null
    }
    $format.Dispose()
    $font.Dispose()
    $letterBrush.Dispose()
    $ringPen.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}
